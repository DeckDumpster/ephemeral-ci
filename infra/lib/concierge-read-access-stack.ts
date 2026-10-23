import * as cdk from 'aws-cdk-lib';
import { Construct } from 'constructs';
import * as cr from 'aws-cdk-lib/custom-resources';

/**
 * Read access for the Concierge: list and describe across every service, and
 * Cost Explorer / billing. Neither policy reads data-plane contents (objects,
 * secret values) or writes anything.
 */
export const CONCIERGE_READ_POLICIES: readonly string[] = [
  'job-function/ViewOnlyAccess',
  'AWSBillingReadOnlyAccess',
];

export interface ConciergeReadAccessStackProps extends cdk.StackProps {
  /** Existing role the Concierge runs as; it lives outside CDK. */
  readonly conciergeRoleName?: string;
}

/**
 * Attaches AWS managed policies to the existing spira-concierge role.
 * CloudFormation cannot attach a managed policy to a role it does not own, so
 * this is an idempotent AttachRolePolicy call: it adopts attachments made by
 * hand and never detaches (no onDelete, so removing this stack leaves the
 * role's access as it is).
 */
export class ConciergeReadAccessStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: ConciergeReadAccessStackProps) {
    super(scope, id, props);

    const roleName = props?.conciergeRoleName ?? 'spira-concierge';
    const roleArn = `arn:${this.partition}:iam::${this.account}:role/${roleName}`;

    for (const policy of CONCIERGE_READ_POLICIES) {
      const policyArn = `arn:${this.partition}:iam::aws:policy/${policy}`;
      const attach = {
        service: 'IAM',
        action: 'attachRolePolicy',
        parameters: { RoleName: roleName, PolicyArn: policyArn },
        physicalResourceId: cr.PhysicalResourceId.of(`${roleName}:${policyArn}`),
      };
      new cr.AwsCustomResource(this, `Attach${policy.split('/').pop()}`, {
        onCreate: attach,
        onUpdate: attach,
        policy: cr.AwsCustomResourcePolicy.fromStatements([
          new cdk.aws_iam.PolicyStatement({
            actions: ['iam:AttachRolePolicy'],
            resources: [roleArn],
            conditions: { ArnEquals: { 'iam:PolicyARN': policyArn } },
          }),
        ]),
      });
    }
  }
}
