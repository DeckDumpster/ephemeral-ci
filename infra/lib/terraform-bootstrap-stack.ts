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
      roleName: 'terraform-deploy',
      description: 'Assumed by the Concierge, with MFA, to run terraform apply',
      maxSessionDuration: cdk.Duration.hours(4),
      assumedBy: new iam.ArnPrincipal(
        `arn:${this.partition}:iam::${this.account}:role/${conciergeRoleName}`,
      ).withConditions({
        Bool: { 'aws:MultiFactorAuthPresent': 'true' },
      }),
    });

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

    // IAM principals and policies, name-prefixed. No iam:* on '*', and the
    // role cannot edit itself (terraform-deploy does not match the prefix).
    role.addToPolicy(new iam.PolicyStatement({
      sid: 'PrefixedIam',
      actions: [
        'iam:CreateUser', 'iam:DeleteUser', 'iam:GetUser', 'iam:UpdateUser', 'iam:TagUser', 'iam:UntagUser',
        'iam:CreateAccessKey', 'iam:DeleteAccessKey', 'iam:ListAccessKeys', 'iam:UpdateAccessKey',
        'iam:CreateRole', 'iam:DeleteRole', 'iam:GetRole', 'iam:UpdateRole', 'iam:UpdateAssumeRolePolicy',
        'iam:TagRole', 'iam:UntagRole', 'iam:PassRole', 'iam:ListRolePolicies', 'iam:ListAttachedRolePolicies',
        'iam:ListInstanceProfilesForRole', 'iam:ListUserTags', 'iam:ListRoleTags', 'iam:ListPolicyTags',
        'iam:ListInstanceProfileTags', 'iam:ListGroupsForUser', 'iam:ListEntitiesForPolicy',
        'iam:CreatePolicy', 'iam:DeletePolicy', 'iam:GetPolicy', 'iam:GetPolicyVersion',
        'iam:CreatePolicyVersion', 'iam:DeletePolicyVersion', 'iam:ListPolicyVersions',
        'iam:PutUserPolicy', 'iam:GetUserPolicy', 'iam:DeleteUserPolicy', 'iam:ListUserPolicies',
        'iam:PutRolePolicy', 'iam:GetRolePolicy', 'iam:DeleteRolePolicy',
        'iam:AttachUserPolicy', 'iam:DetachUserPolicy', 'iam:ListAttachedUserPolicies',
        'iam:AttachRolePolicy', 'iam:DetachRolePolicy',
        'iam:CreateInstanceProfile', 'iam:DeleteInstanceProfile', 'iam:GetInstanceProfile',
        'iam:AddRoleToInstanceProfile', 'iam:RemoveRoleFromInstanceProfile',
      ],
      resources: ['user', 'role', 'policy', 'instance-profile'].flatMap(iamArn),
    }));

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
    role.addToPolicy(new iam.PolicyStatement({
      sid: 'AdoptedIam',
      actions: [
        'iam:CreateUser', 'iam:DeleteUser', 'iam:GetUser', 'iam:UpdateUser', 'iam:TagUser', 'iam:UntagUser', 'iam:ListUserTags',
        'iam:ListGroupsForUser',
        'iam:CreateRole', 'iam:DeleteRole', 'iam:GetRole', 'iam:UpdateRole', 'iam:UpdateAssumeRolePolicy',
        'iam:TagRole', 'iam:UntagRole', 'iam:ListRoleTags', 'iam:PassRole', 'iam:ListRolePolicies',
        'iam:ListAttachedRolePolicies', 'iam:ListInstanceProfilesForRole',
        'iam:CreatePolicy', 'iam:DeletePolicy', 'iam:GetPolicy', 'iam:GetPolicyVersion',
        'iam:CreatePolicyVersion', 'iam:DeletePolicyVersion', 'iam:ListPolicyVersions', 'iam:ListPolicyTags',
        'iam:ListEntitiesForPolicy',
        'iam:PutUserPolicy', 'iam:GetUserPolicy', 'iam:DeleteUserPolicy', 'iam:ListUserPolicies',
        'iam:PutRolePolicy', 'iam:GetRolePolicy', 'iam:DeleteRolePolicy',
        'iam:AttachUserPolicy', 'iam:DetachUserPolicy', 'iam:ListAttachedUserPolicies',
        'iam:AttachRolePolicy', 'iam:DetachRolePolicy',
        'iam:CreateInstanceProfile', 'iam:DeleteInstanceProfile', 'iam:GetInstanceProfile', 'iam:ListInstanceProfileTags',
        'iam:AddRoleToInstanceProfile', 'iam:RemoveRoleFromInstanceProfile',
      ],
      resources: adoptedIamArns,
    }));
    // The existing role the backup stack attached its secret-read policy to.
    role.addToPolicy(new iam.PolicyStatement({
      sid: 'ConciergeRoleInlinePolicies',
      actions: ['iam:PutRolePolicy', 'iam:GetRolePolicy', 'iam:DeleteRolePolicy', 'iam:ListRolePolicies'],
      resources: [`arn:${this.partition}:iam::${this.account}:role/${conciergeRoleName}`],
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
}
