import * as cdk from 'aws-cdk-lib';
import * as iam from 'aws-cdk-lib/aws-iam';
import { Construct } from 'constructs';

/**
 * The one identity that has to exist before CDK can deploy anything.
 *
 * A brand-new standalone AWS account holds only the root user, and `cdk
 * bootstrap` needs CLI credentials — so some principal must come into being
 * outside the normal `cdk deploy` path. This stack is that principal, authored
 * in CDK and synthesised to a template you upload to the CloudFormation
 * console as root. The console needs no CLI credentials, so nothing in the
 * account is ever created outside a stack.
 *
 * The shape matters more than the contents. The long-lived access key belongs
 * to a user that can do exactly one thing: assume the admin role. The key on
 * disk is therefore worth nothing on its own, admin only exists inside a
 * one-hour session, and that session requires MFA. This is the same shape
 * already in use on the .93 box for the mtgc-backup profile.
 *
 * No AWS::IAM::AccessKey resource here on purpose: CloudFormation returns the
 * secret as a stack attribute, which would write it into the stack's outputs
 * where anyone with read access to the account can retrieve it. Create the key
 * in the IAM console instead, once, and store it in pass.
 */
export class BootstrapIdentityStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    // Holds the long-lived access key. Deliberately has no permissions of its
    // own beyond the assume-role grant added below.
    const user = new iam.User(this, 'BootstrapUser', {
      userName: 'cdk-bootstrap',
    });

    const role = new iam.Role(this, 'BootstrapAdminRole', {
      roleName: 'cdk-bootstrap-admin',
      description:
        'Admin for cdk bootstrap and cdk deploy. One-hour sessions, MFA required, ' +
        'assumable only by the cdk-bootstrap user.',
      // AdministratorAccess is correct here rather than a narrower policy:
      // `cdk bootstrap` creates IAM roles, an S3 bucket, an ECR repository and
      // an SSM parameter, and the spill stack adds VPC, EC2, IAM and Budgets.
      // Enumerating that surface precisely would be guesswork that fails at
      // deploy time; the containment is the one-hour MFA session, not the
      // policy.
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName('AdministratorAccess'),
      ],
      maxSessionDuration: cdk.Duration.hours(1),
      assumedBy: new iam.PrincipalWithConditions(
        new iam.ArnPrincipal(user.userArn),
        { Bool: { 'aws:MultiFactorAuthPresent': 'true' } },
      ),
    });

    // The user's entire permission set.
    user.addToPolicy(
      new iam.PolicyStatement({
        actions: ['sts:AssumeRole'],
        resources: [role.roleArn],
      }),
    );

    new cdk.CfnOutput(this, 'BootstrapUserName', {
      value: user.userName,
      description: 'Create this user an access key in the IAM console, then store it in pass.',
    });

    new cdk.CfnOutput(this, 'BootstrapRoleArn', {
      value: role.roleArn,
      description: 'role_arn for the ~/.aws/config profile.',
    });
  }
}
