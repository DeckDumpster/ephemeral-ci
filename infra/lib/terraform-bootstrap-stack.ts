import * as cdk from 'aws-cdk-lib';
import { Construct } from 'constructs';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as s3 from 'aws-cdk-lib/aws-s3';

/**
 * Repositories whose Terraform roots run as terraform-deploy. Each owns the
 * resources named `<prefix>-*` (S3 buckets, IAM users/roles/policies/instance
 * profiles) and `<prefix>/*` (Secrets Manager). Moving a repository to
 * Terraform is one edit to this list, then a redeploy of this stack.
 */
export const TERRAFORM_NAME_PREFIXES: readonly string[] = ['spira', 'cubby'];

const DEPLOY_ROLE_NAME = 'terraform-deploy';
const BOUNDARY_NAME = 'terraform-deploy-boundary';
/** Terraform tags every boundaried user with this, so access-key actions can be scoped to them. */
export const BOUNDARY_TAG_KEY = 'terraform-deploy-boundary';
export const BOUNDARY_TAG_VALUE = 'true';
const IAM_WRITE_VERBS = [
  'Create', 'Put', 'Attach', 'Detach', 'Update', 'Delete', 'Add', 'Remove', 'Set', 'Tag', 'Untag',
] as const;

export interface TerraformBootstrapStackProps extends cdk.StackProps {
  /** Existing role the Concierge runs as; the only principal that may assume terraform-deploy. */
  readonly conciergeRoleName?: string;
  /** Overrides TERRAFORM_NAME_PREFIXES (tests). */
  readonly namePrefixes?: readonly string[];
}

/**
 * The last thing CDK deploys (law-infrastructure-is-terraform): the Terraform
 * state bucket and the MFA-gated role Terraform runs as. State locking is
 * S3-native (Terraform >= 1.10 `use_lockfile`), so there is no DynamoDB table.
 */
export class TerraformBootstrapStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: TerraformBootstrapStackProps) {
    super(scope, id, props);

    const conciergeRoleName = props?.conciergeRoleName ?? 'spira-concierge';
    const prefixes = props?.namePrefixes ?? TERRAFORM_NAME_PREFIXES;
    const conciergeRoleArn = `arn:${this.partition}:iam::${this.account}:role/${conciergeRoleName}`;
    const deployRoleArn = `arn:${this.partition}:iam::${this.account}:role/${DEPLOY_ROLE_NAME}`;

    const bucket = new s3.Bucket(this, 'StateBucket', {
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      versioned: true,
      encryption: s3.BucketEncryption.S3_MANAGED,
      enforceSSL: true,
      removalPolicy: cdk.RemovalPolicy.RETAIN,
      lifecycleRules: [
        { noncurrentVersionExpiration: cdk.Duration.days(90) },
      ],
    });

    const role = new iam.Role(this, 'DeployRole', {
      roleName: DEPLOY_ROLE_NAME,
      description: 'Assumed by the Concierge (MFA enforced at spira-concierge) to run terraform apply',
      maxSessionDuration: cdk.Duration.hours(4),
      // The Concierge reaches this role from a spira-concierge assumed-role
      // session. MFA context is not carried across role chaining, so a
      // aws:MultiFactorAuthPresent condition here could never hold. MFA is
      // enforced where the chain starts: spira-concierge's own trust requires it.
      // The role ARN as principal admits any session of that role.
      assumedBy: new iam.ArnPrincipal(conciergeRoleArn).withConditions({
        ArnEquals: { 'aws:PrincipalArn': conciergeRoleArn },
      }),
    });

    // Every user/role this role creates or modifies must carry this boundary,
    // which caps them below IAM administration and below terraform-deploy.
    const boundary = new iam.ManagedPolicy(this, 'DeployBoundary', {
      managedPolicyName: BOUNDARY_NAME,
      description: 'Permissions boundary for every principal terraform-deploy creates',
      statements: [
        new iam.PolicyStatement({ sid: 'Everything', actions: ['*'], resources: ['*'] }),
        new iam.PolicyStatement({
          sid: 'NoIamWrites',
          effect: iam.Effect.DENY,
          actions: IAM_WRITE_VERBS.map((v) => `iam:${v}*`),
          resources: ['*'],
        }),
        new iam.PolicyStatement({
          sid: 'NoAssumingDeployRole',
          effect: iam.Effect.DENY,
          actions: ['sts:AssumeRole'],
          resources: [deployRoleArn],
        }),
      ],
    });
    const boundaryCondition = { StringEquals: { 'iam:PermissionsBoundary': boundary.managedPolicyArn } };

    const iamArn = (kind: string) =>
      prefixes.map((p) => `arn:${this.partition}:iam::${this.account}:${kind}/${p}-*`);

    // State backend: this bucket only, objects and the native lock file.
    role.addToPolicy(new iam.PolicyStatement({
      sid: 'StateBucketList',
      actions: ['s3:ListBucket', 's3:GetBucketVersioning', 's3:GetBucketLocation'],
      resources: [bucket.bucketArn],
    }));
    role.addToPolicy(new iam.PolicyStatement({
      sid: 'StateObjects',
      actions: ['s3:GetObject', 's3:PutObject', 's3:DeleteObject'],
      resources: [bucket.arnForObjects('*')],
    }));

    // S3 buckets Terraform manages, scoped by name prefix.
    role.addToPolicy(new iam.PolicyStatement({
      sid: 'PrefixedBuckets',
      actions: ['s3:*'],
      resources: prefixes.flatMap((p) => [
        `arn:${this.partition}:s3:::${p}-*`,
        `arn:${this.partition}:s3:::${p}-*/*`,
      ]),
    }));
    role.addToPolicy(new iam.PolicyStatement({
      sid: 'BucketDiscovery',
      actions: ['s3:ListAllMyBuckets', 's3:GetBucketLocation'],
      resources: ['*'],
    }));

    // IAM statements live in managed policies: a role's inline policies share a
    // 10240-character cap and CDK splits them silently.
    const prefixedIam = new iam.ManagedPolicy(this, 'PrefixedIamPolicy', { roles: [role] });
    const adoptedIamPolicy = new iam.ManagedPolicy(this, 'AdoptedIamPolicy', { roles: [role] });

    // IAM, name-prefixed. Writes to users and roles are allowed only with the
    // boundary; policies and instance profiles grant nothing by themselves and
    // can only reach boundary-carrying principals through those writes.
    this.addIam(prefixedIam, 'Prefixed', boundaryCondition, ['user', 'role', 'policy', 'instance-profile'].flatMap(iamArn));

    // What the retired CDK stacks (EphemeralCiSpill, EphemeralCiBackup) created,
    // adopted into Terraform by import. Their physical names are the explicit
    // ephemeral-ci-* ones or CloudFormation's <stack>-<logical id>-<random>, so
    // they cannot carry the spira- prefix. Each pattern names one stack's
    // resources; nothing here reaches cdk-bootstrap-admin (the admin role is
    // managed by its own root, under its own credentials).
    const adoptedIam = ['ephemeral-ci-*', 'EphemeralCiSpill-*', 'EphemeralCiBackup-*'];
    const adoptedIamArns = adoptedIam.flatMap((p) =>
      ['user', 'role', 'policy', 'instance-profile'].map(
        (kind) => `arn:${this.partition}:iam::${this.account}:${kind}/${p}`,
      ),
    );
    this.addIam(adoptedIamPolicy, 'Adopted', boundaryCondition, adoptedIamArns);
    // The existing role the backup stack attached its secret-read policy to.
    // Read-only: writes to spira-concierge are denied below.
    prefixedIam.addStatements(new iam.PolicyStatement({
      sid: 'ConciergeRoleInlinePoliciesRead',
      actions: ['iam:GetRolePolicy', 'iam:ListRolePolicies'],
      resources: [conciergeRoleArn],
    }));

    // No IAM write on the roles that gate this one, nor on the boundary, and
    // the boundary can never be removed from a principal.
    prefixedIam.addStatements(new iam.PolicyStatement({
      sid: 'DenyIamWritesOnGuards',
      effect: iam.Effect.DENY,
      actions: IAM_WRITE_VERBS.map((v) => `iam:${v}*`),
      resources: [conciergeRoleArn, deployRoleArn, boundary.managedPolicyArn],
    }));
    prefixedIam.addStatements(new iam.PolicyStatement({
      sid: 'DenyBoundaryRemoval',
      effect: iam.Effect.DENY,
      actions: ['iam:DeleteRolePermissionsBoundary', 'iam:DeleteUserPermissionsBoundary'],
      resources: ['*'],
    }));
    role.addToPolicy(new iam.PolicyStatement({
      sid: 'GithubOidcProvider',
      actions: [
        'iam:GetOpenIDConnectProvider', 'iam:CreateOpenIDConnectProvider', 'iam:DeleteOpenIDConnectProvider',
        'iam:UpdateOpenIDConnectProviderThumbprint', 'iam:AddClientIDToOpenIDConnectProvider',
        'iam:RemoveClientIDFromOpenIDConnectProvider', 'iam:TagOpenIDConnectProvider',
        'iam:UntagOpenIDConnectProvider', 'iam:ListOpenIDConnectProviderTags',
      ],
      resources: [
        `arn:${this.partition}:iam::${this.account}:oidc-provider/token.actions.githubusercontent.com`,
      ],
    }));
    role.addToPolicy(new iam.PolicyStatement({
      sid: 'SpotServiceLinkedRole',
      actions: [
        'iam:GetRole', 'iam:ListRolePolicies', 'iam:ListAttachedRolePolicies', 'iam:ListInstanceProfilesForRole',
        'iam:ListRoleTags', 'iam:CreateServiceLinkedRole', 'iam:UpdateRoleDescription',
      ],
      resources: [
        `arn:${this.partition}:iam::${this.account}:role/aws-service-role/spot.amazonaws.com/AWSServiceRoleForEC2Spot`,
      ],
    }));
    role.addToPolicy(new iam.PolicyStatement({
      sid: 'AdoptedBuckets',
      actions: ['s3:*'],
      resources: ['ephemeralcispill-*', 'ephemeralcibackup-*'].flatMap((p) => [
        `arn:${this.partition}:s3:::${p}`,
        `arn:${this.partition}:s3:::${p}/*`,
      ]),
    }));
    role.addToPolicy(new iam.PolicyStatement({
      sid: 'AdoptedSecrets',
      actions: ['secretsmanager:*'],
      resources: [`arn:${this.partition}:secretsmanager:${this.region}:${this.account}:secret:WriterKeySecret*`],
    }));
    role.addToPolicy(new iam.PolicyStatement({
      sid: 'MonthlyBudget',
      actions: ['budgets:*'],
      resources: [`arn:${this.partition}:budgets::${this.account}:budget/*`],
    }));

    role.addToPolicy(new iam.PolicyStatement({
      sid: 'PrefixedSecrets',
      actions: ['secretsmanager:*'],
      resources: prefixes.map(
        (p) => `arn:${this.partition}:secretsmanager:${this.region}:${this.account}:secret:${p}/*`,
      ),
    }));

    // What ephemeral-ci's own stacks use. EC2 has no useful resource scoping
    // for Describe*/Run*, so these are region-pinned instead.
    role.addToPolicy(new iam.PolicyStatement({
      sid: 'Ec2InThisRegion',
      actions: ['ec2:*'],
      resources: ['*'],
      conditions: { StringEquals: { 'aws:RequestedRegion': this.region } },
    }));
    role.addToPolicy(new iam.PolicyStatement({
      sid: 'Ssm',
      actions: ['ssm:*'],
      resources: ['*'],
      conditions: { StringEquals: { 'aws:RequestedRegion': this.region } },
    }));
    role.addToPolicy(new iam.PolicyStatement({
      sid: 'CloudFormationRead',
      actions: [
        'cloudformation:Describe*', 'cloudformation:Get*',
        'cloudformation:List*', 'cloudformation:DetectStackDrift',
      ],
      resources: ['*'],
    }));

    new cdk.CfnOutput(this, 'StateBucketName', { value: bucket.bucketName });
    new cdk.CfnOutput(this, 'Region', { value: this.region });
    new cdk.CfnOutput(this, 'DeployRoleArn', { value: role.roleArn });
  }

  private addIam(
    role: iam.ManagedPolicy,
    sidPrefix: string,
    boundaryCondition: Record<string, Record<string, string>>,
    arns: string[],
  ): void {
    const ofKind = (kind: string) => arns.filter((a) => a.includes(`:${kind}/`));
    const principals = [...ofKind('user'), ...ofKind('role')];
    const others = [...ofKind('policy'), ...ofKind('instance-profile')];
    role.addStatements(new iam.PolicyStatement({
      sid: `${sidPrefix}IamRead`,
      actions: [
        'iam:GetUser', 'iam:ListUserTags', 'iam:ListGroupsForUser', 'iam:ListAccessKeys',
        'iam:GetUserPolicy', 'iam:ListUserPolicies', 'iam:ListAttachedUserPolicies',
        'iam:GetRole', 'iam:ListRoleTags', 'iam:PassRole', 'iam:ListRolePolicies',
        'iam:GetRolePolicy', 'iam:ListAttachedRolePolicies', 'iam:ListInstanceProfilesForRole',
        'iam:GetPolicy', 'iam:GetPolicyVersion', 'iam:ListPolicyVersions', 'iam:ListPolicyTags',
        'iam:ListEntitiesForPolicy', 'iam:GetInstanceProfile', 'iam:ListInstanceProfileTags',
      ],
      resources: arns,
    }));
    role.addStatements(new iam.PolicyStatement({
      sid: `${sidPrefix}IamPrincipalWrite`,
      actions: [
        'iam:CreateUser', 'iam:DeleteUser', 'iam:UpdateUser', 'iam:TagUser', 'iam:UntagUser',
        'iam:CreateRole', 'iam:DeleteRole', 'iam:UpdateRole', 'iam:UpdateAssumeRolePolicy',
        'iam:TagRole', 'iam:UntagRole',
        'iam:PutUserPolicy', 'iam:DeleteUserPolicy', 'iam:PutRolePolicy', 'iam:DeleteRolePolicy',
        'iam:AttachUserPolicy', 'iam:DetachUserPolicy', 'iam:AttachRolePolicy', 'iam:DetachRolePolicy',
        'iam:PutUserPermissionsBoundary', 'iam:PutRolePermissionsBoundary',
      ],
      resources: principals,
      conditions: boundaryCondition,
    }));
    // iam:CreateAccessKey (and Delete/Update) carry no iam:PermissionsBoundary
    // key, so a boundary condition could never match them. The user resource
    // type supports aws:ResourceTag/${TagKey} (AWS Service Authorization
    // Reference, "Actions, resources, and condition keys for AWS Identity and
    // Access Management"), so keys are limited to users tagged at creation,
    // which this role can only do alongside the boundary.
    role.addStatements(new iam.PolicyStatement({
      sid: `${sidPrefix}IamAccessKeyWrite`,
      actions: ['iam:CreateAccessKey', 'iam:DeleteAccessKey', 'iam:UpdateAccessKey'],
      resources: ofKind('user'),
      conditions: { StringEquals: { [`aws:ResourceTag/${BOUNDARY_TAG_KEY}`]: BOUNDARY_TAG_VALUE } },
    }));
    // TagUser/TagRole support aws:TagKeys / aws:RequestTag/${TagKey} but not
    // iam:PermissionsBoundary (AWS Service Authorization Reference, "Actions,
    // resources, and condition keys for AWS Identity and Access Management"),
    // so the boundary-conditioned write above can never match a tag change on
    // an existing principal. This statement lets the role (re)apply only the
    // boundary tag key on principals under the managed prefixes; the guards
    // stay covered by DenyIamWritesOnGuards.
    role.addStatements(new iam.PolicyStatement({
      sid: `${sidPrefix}IamBoundaryTagWrite`,
      actions: ['iam:TagUser', 'iam:UntagUser', 'iam:TagRole', 'iam:UntagRole'],
      resources: principals,
      conditions: { 'ForAllValues:StringEquals': { 'aws:TagKeys': [BOUNDARY_TAG_KEY] } },
    }));
    role.addStatements(new iam.PolicyStatement({
      sid: `${sidPrefix}IamPolicyWrite`,
      actions: [
        'iam:CreatePolicy', 'iam:DeletePolicy', 'iam:CreatePolicyVersion', 'iam:DeletePolicyVersion',
        'iam:TagPolicy', 'iam:UntagPolicy',
        'iam:CreateInstanceProfile', 'iam:DeleteInstanceProfile',
        'iam:AddRoleToInstanceProfile', 'iam:RemoveRoleFromInstanceProfile',
        'iam:TagInstanceProfile', 'iam:UntagInstanceProfile',
      ],
      resources: others,
    }));
  }
}
