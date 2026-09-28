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

    // ── Instance role: SSM managed core only ─────────────────────────────────
    // Token delivery uses a custom SSM document with a {{ssm-secure:}} reference:
    // the spill role writes the token to Parameter Store, then sends the command
    // passing the parameter as {{ssm-secure:/path}}.  The SSM service resolves
    // that reference using the spill role's credentials and injects the decrypted
    // value without recording it in command history.  The instance never calls
    // the SSM API directly; AmazonSSMManagedInstanceCore is all it needs.
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
    // This repository uses immutable OIDC subjects (use_immutable_subject=true).
    // GitHub issues subs of the form repo:<owner>@<owner_id>/<repo>@<repo_id>:<context>.
    // The prefix below was read from:
    //   gh api repos/DeckDumpster/ephemeral-ci/actions/oidc/customization/sub
    // It must be re-read if this stack is ever pointed at a different repository.
    // The numeric ids survive a repository or organisation rename and are immutable
    // by definition — hardcoding them is correct, not a maintenance risk.
    const OIDC_SUB_PREFIX = 'repo:DeckDumpster@262905033/ephemeral-ci@1371818598:*';

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
    // Subject uses OIDC_SUB_PREFIX (all refs, not just main) because CI spills
    // from queue branches and pull request branches too.
    // Cost is bounded instead: launch template required + instance type locked
    // to c7i/c8i families (16 vCPU shapes validated in docs/spikes/).
    const spillRole = new iam.Role(this, 'SpillRole', {
      roleName: 'ephemeral-ci-spill',
      assumedBy: oidcPrincipal(OIDC_SUB_PREFIX),
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

    // RunInstances: instance resource — spill:owner tag required (bounds the
    // instance type), plus ephemeral-ci:vmtoken tag required (binds the IAM
    // condition on the instance role so each instance only reaches its own token)
    spillRole.addToPolicy(new iam.PolicyStatement({
      actions: ['ec2:RunInstances'],
      resources: ['arn:aws:ec2:us-west-2:189923011121:instance/*'],
      conditions: {
        StringEquals: {
          'aws:RequestTag/spill:owner': 'ephemeral-ci',
        },
        Null: {
          'aws:RequestTag/ephemeral-ci:vmtoken': 'false',
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

    // ssm:PutParameter / ssm:DeleteParameter: write and clean up the runner
    // token in Parameter Store.  Scoped to the runner-token prefix only.
    // ssm:GetParameter and ssm:GetParameters are both granted: they are
    // distinct IAM actions (singular ≠ plural, neither implies the other), and
    // AWS documentation for SecureString retrieval with decryption shows
    // GetParameters (plural) in example policies.  Granting both is correct
    // rather than guessing which action the service uses when expanding
    // {{ssm-secure:/path}} references.  The resource scope is unchanged.
    // Unverified: which action SSM actually calls during {{ssm-secure:}}
    // expansion cannot be confirmed by synth alone; a real spill that delivers
    // a token is required to observe the behaviour.
    spillRole.addToPolicy(new iam.PolicyStatement({
      actions: ['ssm:PutParameter', 'ssm:DeleteParameter', 'ssm:GetParameter', 'ssm:GetParameters'],
      resources: ['arn:aws:ssm:us-west-2:189923011121:parameter/ephemeral-ci/runner-token/*'],
    }));

    // ssm:GetCommandInvocation: poll command status after send-command.
    // ssm:DescribeInstanceInformation: wait for SSM agent to go Online.
    // Both require resource: * — SSM does not support resource-level
    // restrictions for these read actions.  ssm:ListCommandInvocations is
    // not used by provision.sh and is intentionally absent.
    spillRole.addToPolicy(new iam.PolicyStatement({
      actions: [
        'ssm:GetCommandInvocation',
        'ssm:DescribeInstanceInformation',
      ],
      resources: ['*'],
    }));

    // DescribeImages: find the newest spill AMI by tag
    spillRole.addToPolicy(new iam.PolicyStatement({
      actions: ['ec2:DescribeImages'],
      resources: ['*'],
    }));

    // DescribeStacks: load SpillStack outputs (subnet, SG, launch template)
    spillRole.addToPolicy(new iam.PolicyStatement({
      actions: ['cloudformation:DescribeStacks'],
      resources: [`arn:aws:cloudformation:us-west-2:189923011121:stack/EphemeralCiSpill/*`],
    }));


    // ── CI test role: minimal grants for policy assertions ───────────────────
    // ReadOnlyAccess was the prior grant; it includes ssm:List* which let any
    // branch of this repository read SSM command history (including, until this
    // bead, embedded runner tokens).  The stated purpose of this role is
    // iam:SimulatePrincipalPolicy; ReadOnlyAccess was larger than required.
    const ciTestRole = new iam.Role(this, 'CiTestRole', {
      roleName: 'ephemeral-ci-ci-test',
      assumedBy: oidcPrincipal(OIDC_SUB_PREFIX),
    });

    ciTestRole.addToPolicy(new iam.PolicyStatement({
      actions: ['iam:SimulatePrincipalPolicy'],
      resources: ['*'],
    }));

    // IAM read access for inspecting roles and policies alongside simulations.
    ciTestRole.addToPolicy(new iam.PolicyStatement({
      actions: ['iam:Get*', 'iam:List*'],
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
          instanceMetadataTags: 'enabled',
        },
        blockDeviceMappings: [
          {
            // Must match the AMI's root device (/dev/sda1 set in scripts/ami-build.sh).
            // Using any other name declares an ADDITIONAL blank volume rather than
            // overriding the root, which is what caused the MissingParameter error.
            // volumeSize must match ROOT_DISK_GIB=32 in scripts/ami-build.sh; a
            // mismatch silently produces the wrong root size.
            deviceName: '/dev/sda1',
            ebs: {
              volumeSize: 32,
              volumeType: 'gp3',
              deleteOnTermination: true,
              encrypted: true,
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

    // ── SSM document: token delivery via {{ssm-secure:}} reference ───────────
    // RunnerToken is passed as {{ssm-secure:/ephemeral-ci/runner-token/<vmtoken>}}
    // from send-command.  SSM expands the reference using the spill role's
    // ssm:GetParameter permission and injects the decrypted value into the
    // document's RunnerToken field.  The resolved value is NOT stored in
    // command history (SSM redacts ssm-secure references).  The instance never
    // calls the SSM API; it sees the already-decrypted value from the document.
    new cdk.CfnResource(this, 'DeliverRunnerTokenDocument', {
      type: 'AWS::SSM::Document',
      properties: {
        Name: 'ephemeral-ci-deliver-runner-token',
        DocumentType: 'Command',
        DocumentFormat: 'JSON',
        Content: {
          schemaVersion: '2.2',
          description: 'Write runner init file; RunnerToken is resolved from {{ssm-secure:}} and not logged.',
          parameters: {
            RunnerToken: { type: 'String', description: 'Registration token (pass as {{ssm-secure:/path}})' },
            RunnerLabel: { type: 'String', description: 'Runner label' },
            RunnerUrl: { type: 'String', description: 'Registration URL' },
            RunnerGroup: { type: 'String', description: 'Runner group', default: 'ephemeral-ci' },
          },
          mainSteps: [
            {
              action: 'aws:runShellScript',
              name: 'DeliverToken',
              inputs: {
                runCommand: [
                  'set -e',
                  "printf 'RUNNER_LABEL={{ RunnerLabel }}\\nRUNNER_TOKEN={{ RunnerToken }}\\nRUNNER_URL={{ RunnerUrl }}\\nRUNNER_GROUP={{ RunnerGroup }}\\n' > /run/gh-runner-init.partial",
                  'mv /run/gh-runner-init.partial /run/gh-runner-init',
                ],
              },
            },
          ],
        },
      },
    });

    // ── Outputs: consumed by later spill scripts via describe-stacks ─────────
    new cdk.CfnOutput(this, 'SubnetId', { value: subnet.ref });
    new cdk.CfnOutput(this, 'SecurityGroupId', { value: sg.ref });
    new cdk.CfnOutput(this, 'LaunchTemplateId', { value: launchTemplate.ref });
    new cdk.CfnOutput(this, 'LaunchTemplateName', { value: 'ephemeral-ci-spill' });
    new cdk.CfnOutput(this, 'InstanceProfileName', { value: instanceProfile.ref });
  }
}
