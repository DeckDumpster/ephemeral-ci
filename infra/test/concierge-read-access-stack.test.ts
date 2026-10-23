import * as cdk from 'aws-cdk-lib';
import { Template } from 'aws-cdk-lib/assertions';
import { ConciergeReadAccessStack } from '../lib/concierge-read-access-stack';

const template = Template.fromStack(
  new ConciergeReadAccessStack(new cdk.App(), 'TestConciergeRead', {
    env: { account: '189923011121', region: 'us-west-2' },
  }),
);

const resources = () => Object.values(template.findResources('Custom::AWS')) as { Properties: Record<string, unknown> }[];
// Create/Update/Delete are JSON strings, or Fn::Join tokens when they hold a pseudo parameter.
const raw = (key: 'Create' | 'Update' | 'Delete') => resources().map((r) => JSON.stringify(r.Properties[key] ?? null));

test('attaches exactly ViewOnlyAccess and AWSBillingReadOnlyAccess to spira-concierge', () => {
  const calls = raw('Create');
  expect(calls).toHaveLength(2);
  for (const c of calls) {
    expect(c).toContain('\\"service\\":\\"IAM\\"');
    expect(c).toContain('\\"action\\":\\"attachRolePolicy\\"');
    expect(c).toContain('\\"RoleName\\":\\"spira-concierge\\"');
  }
  expect(calls.filter((c) => c.includes('policy/job-function/ViewOnlyAccess\\"'))).toHaveLength(1);
  expect(calls.filter((c) => c.includes('policy/AWSBillingReadOnlyAccess\\"'))).toHaveLength(1);
});

test('never detaches: no delete call on any attachment', () => {
  expect(raw('Delete').every((d) => d === 'null')).toBe(true);
});

test('the only IAM permission granted is AttachRolePolicy on spira-concierge', () => {
  const stmts = Object.values(template.findResources('AWS::IAM::Policy'))
    .flatMap((p: any) => p.Properties.PolicyDocument.Statement)
    .filter((s: any) => ([] as string[]).concat(s.Action).some((a) => a.startsWith('iam:')));
  expect(stmts).toHaveLength(2);
  for (const s of stmts) {
    expect(s.Action).toBe('iam:AttachRolePolicy');
    expect(JSON.stringify(s.Resource)).toContain('role/spira-concierge');
  }
});
