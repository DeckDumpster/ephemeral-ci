import * as cdk from 'aws-cdk-lib';
import { Construct } from 'constructs';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as budgets from 'aws-cdk-lib/aws-budgets';

export class SpillStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    // ── VPC: 10.0.0.0/16, one public subnet in us-west-2a, no NAT gateway ───
    const vpc = new ec2.CfnVPC(this, 'Vpc', {
      cidrBlock: '10.0.0.0/16',
      enableDnsSupport: true,
      enableDnsHostnames: true,
      tags: [{ key: 'Name', value: 'ephemeral-ci-spill' }],
    });

    const subnet = new ec2.CfnSubnet(this, 'PublicSubnet', {
      vpcId: vpc.ref,
      cidrBlock: '10.0.0.0/24',
      availabilityZone: 'us-west-2a',
      mapPublicIpOnLaunch: true,
      tags: [{ key: 'Name', value: 'ephemeral-ci-spill-public' }],
    });

    const igw = new ec2.CfnInternetGateway(this, 'Igw', {
      tags: [{ key: 'Name', value: 'ephemeral-ci-spill-igw' }],
    });

    new ec2.CfnVPCGatewayAttachment(this, 'IgwAttachment', {
      vpcId: vpc.ref,
      internetGatewayId: igw.ref,
    });

    const routeTable = new ec2.CfnRouteTable(this, 'RouteTable', {
      vpcId: vpc.ref,
      tags: [{ key: 'Name', value: 'ephemeral-ci-spill-rt' }],
    });

    new ec2.CfnRoute(this, 'DefaultRoute', {
      routeTableId: routeTable.ref,
      destinationCidrBlock: '0.0.0.0/0',
      gatewayId: igw.ref,
    });

    new ec2.CfnSubnetRouteTableAssociation(this, 'SubnetRtAssoc', {
      subnetId: subnet.ref,
      routeTableId: routeTable.ref,
    });

    // ── Security group: zero ingress, all egress (SSM needs no inbound port) ─
    const sg = new ec2.CfnSecurityGroup(this, 'SecurityGroup', {
      vpcId: vpc.ref,
      groupDescription: 'ephemeral-ci-spill runner: no inbound, all outbound',
      securityGroupEgress: [
        {
          ipProtocol: '-1',
          cidrIp: '0.0.0.0/0',
          description: 'All outbound',
        },
      ],
      tags: [{ key: 'Name', value: 'ephemeral-ci-spill' }],
    });

    // ── Instance role: ONLY AmazonSSMManagedInstanceCore, no inline policy ───
    const instanceRole = new iam.Role(this, 'InstanceRole', {
      assumedBy: new iam.ServicePrincipal('ec2.amazonaws.com'),
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName('AmazonSSMManagedInstanceCore'),
      ],
    });

    const instanceProfile = new iam.CfnInstanceProfile(this, 'InstanceProfile', {
      roles: [instanceRole.roleName],
      instanceProfileName: 'ephemeral-ci-spill-instance',
    });

    // ── GitHub Actions OIDC provider ─────────────────────────────────────────
    // An account may hold exactly one provider for this issuer; create it here.
    // If deploy fails EntityAlreadyExists, import it instead of deleting.
    const oidcProvider = new iam.CfnOIDCProvider(this, 'GithubOidcProvider', {
      url: 'https://token.actions.githubusercontent.com',
      clientIdList: ['sts.amazonaws.com'],
      // AWS validates GitHub via its own trust roots; thumbprints are formally
      // required by CloudFormation but not used for token verification.
      thumbprintList: [
        '6938fd4d98bab03faadb97b34396831e3780aea1',
        '1c58a3a8518e8759bf075b76b750d4f2df264fcd',
      ],
    });

    const oidcPrincipal = (sub: string): iam.WebIdentityPrincipal =>
      new iam.WebIdentityPrincipal(oidcProvider.attrArn, {
        StringEquals: {
          'token.actions.githubusercontent.com:aud': 'sts.amazonaws.com',
        },
        StringLike: {
          'token.actions.githubusercontent.com:sub': sub,
        },
      });

    // ── Spill role ────────────────────────────────────────────────────────────
    // Subject is repo:DeckDumpster/ephemeral-ci:* (all refs, not just main)
    // because CI spills from queue branches and pull request branches too.
    // Cost is bounded instead: launch template required + instance type locked
    // to c7i/c8i families (16 vCPU shapes validated in docs/spikes/).
    const spillRole = new iam.Role(this, 'SpillRole', {
      roleName: 'ephemeral-ci-spill',
      assumedBy: oidcPrincipal('repo:DeckDumpster/ephemeral-ci:*'),
    });

    // RunInstances: require the launch template created by this stack
    spillRole.addToPolicy(new iam.PolicyStatement({
      actions: ['ec2:RunInstances'],
      resources: ['arn:aws:ec2:us-west-2:189923011121:launch-template/*'],
      conditions: {
        StringEquals: {
          'ec2:ResourceTag/aws:cloudformation:stack-name': 'EphemeralCiSpill',
        },
      },
    }));

    // RunInstances: instance resource — tag required + instance type locked
    spillRole.addToPolicy(new iam.PolicyStatement({
      actions: ['ec2:RunInstances'],
      resources: ['arn:aws:ec2:us-west-2:189923011121:instance/*'],
      conditions: {
        StringEquals: {
          'aws:RequestTag/spill:owner': 'ephemeral-ci',
        },
        StringLike: {
          'ec2:InstanceType': ['c7i.*', 'c8i.*'],
        },
      },
    }));

    // RunInstances: other resource types (volumes, NICs, SGs, subnets, AMIs)
    spillRole.addToPolicy(new iam.PolicyStatement({
      actions: ['ec2:RunInstances'],
      resources: [
        'arn:aws:ec2:us-west-2:189923011121:volume/*',
        'arn:aws:ec2:us-west-2:189923011121:network-interface/*',
        'arn:aws:ec2:us-west-2:189923011121:security-group/*',
        'arn:aws:ec2:us-west-2:189923011121:subnet/*',
        'arn:aws:ec2:us-west-2::image/*',
      ],
    }));

    // TerminateInstances: only instances tagged spill:owner=ephemeral-ci
    spillRole.addToPolicy(new iam.PolicyStatement({
      actions: ['ec2:TerminateInstances'],
      resources: ['arn:aws:ec2:us-west-2:189923011121:instance/*'],
      conditions: {
        StringEquals: {
          'ec2:ResourceTag/spill:owner': 'ephemeral-ci',
        },
      },
    }));

    // DescribeInstances: no resource-level restrictions (Describe APIs do not
    // support them in IAM)
    spillRole.addToPolicy(new iam.PolicyStatement({
      actions: ['ec2:DescribeInstances'],
      resources: ['*'],
    }));

    // SSM send-command: allow any SSM document but only on tagged instances
    spillRole.addToPolicy(new iam.PolicyStatement({
      actions: ['ssm:SendCommand'],
      resources: ['arn:aws:ssm:us-west-2::document/*'],
    }));

    spillRole.addToPolicy(new iam.PolicyStatement({
      actions: ['ssm:SendCommand'],
      resources: ['arn:aws:ec2:us-west-2:189923011121:instance/*'],
      conditions: {
        StringEquals: {
          'ec2:ResourceTag/spill:owner': 'ephemeral-ci',
        },
      },
    }));

    spillRole.addToPolicy(new iam.PolicyStatement({
      actions: [
        'ssm:GetCommandInvocation',
        'ssm:ListCommandInvocations',
        'ssm:DescribeInstanceInformation',
      ],
      resources: ['*'],
    }));

    // ── CI test role: read-only + SimulatePrincipalPolicy for policy testing ─
    const ciTestRole = new iam.Role(this, 'CiTestRole', {
      roleName: 'ephemeral-ci-ci-test',
      assumedBy: oidcPrincipal('repo:DeckDumpster/ephemeral-ci:*'),
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName('ReadOnlyAccess'),
      ],
    });

    ciTestRole.addToPolicy(new iam.PolicyStatement({
      actions: ['iam:SimulatePrincipalPolicy'],
      resources: ['*'],
    }));

    // ── Launch template: IMDSv2, gp3 root, tags propagated ──────────────────
    const launchTemplate = new ec2.CfnLaunchTemplate(this, 'LaunchTemplate', {
      launchTemplateName: 'ephemeral-ci-spill',
      launchTemplateData: {
        iamInstanceProfile: { name: instanceProfile.ref },
        metadataOptions: {
          httpTokens: 'required',
          httpPutResponseHopLimit: 2,
          httpEndpoint: 'enabled',
        },
        blockDeviceMappings: [
          {
            deviceName: '/dev/xvda',
            ebs: {
              volumeType: 'gp3',
              deleteOnTermination: true,
            },
          },
        ],
        tagSpecifications: [
          {
            resourceType: 'instance',
            tags: [
              { key: 'spill:owner', value: 'ephemeral-ci' },
              { key: 'Name', value: 'ephemeral-ci-spill' },
            ],
          },
          {
            resourceType: 'volume',
            tags: [
              { key: 'spill:owner', value: 'ephemeral-ci' },
              { key: 'Name', value: 'ephemeral-ci-spill' },
            ],
          },
        ],
      },
    });

    // ── Budget: $100/month, account-wide (no tag filter) ────────────────────
    // Tag-based budget filters require cost allocation tag activation in the
    // management account (up to 24h propagation, no CloudFormation support).
    // The account is dedicated to this purpose so account-wide is both simpler
    // and correct on day one.
    const alertEmail = this.node.tryGetContext('alertEmail') as string | undefined;
    if (!alertEmail) {
      throw new Error(
        'CDK context key "alertEmail" is required. Pass it with -c alertEmail=<address>.',
      );
    }

    new budgets.CfnBudget(this, 'MonthlyBudget', {
      budget: {
        budgetType: 'COST',
        timeUnit: 'MONTHLY',
        budgetLimit: {
          amount: 100,
          unit: 'USD',
        },
      },
      notificationsWithSubscribers: [
        {
          notification: {
            notificationType: 'ACTUAL',
            comparisonOperator: 'GREATER_THAN',
            threshold: 80,
            thresholdType: 'PERCENTAGE',
          },
          subscribers: [{ subscriptionType: 'EMAIL', address: alertEmail }],
        },
        {
          notification: {
            notificationType: 'FORECASTED',
            comparisonOperator: 'GREATER_THAN',
            threshold: 100,
            thresholdType: 'PERCENTAGE',
          },
          subscribers: [{ subscriptionType: 'EMAIL', address: alertEmail }],
        },
      ],
    });

    // ── Outputs: consumed by later spill scripts via describe-stacks ─────────
    new cdk.CfnOutput(this, 'SubnetId', { value: subnet.ref });
    new cdk.CfnOutput(this, 'SecurityGroupId', { value: sg.ref });
    new cdk.CfnOutput(this, 'LaunchTemplateId', { value: launchTemplate.ref });
    new cdk.CfnOutput(this, 'LaunchTemplateName', { value: 'ephemeral-ci-spill' });
    new cdk.CfnOutput(this, 'InstanceProfileName', { value: instanceProfile.ref });
  }
}
