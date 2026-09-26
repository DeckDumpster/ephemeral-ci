import * as cdk from 'aws-cdk-lib';
import { Template } from 'aws-cdk-lib/assertions';
import { BootstrapIdentityStack } from '../lib/bootstrap-identity-stack';

let template: Template;

beforeAll(() => {
  const app = new cdk.App();
  const stack = new BootstrapIdentityStack(app, 'TestStack', {
    env: { account: '189923011121', region: 'us-west-2' },
    // This stack deploys before cdk bootstrap has run. Without this flag the
    // default synthesiser emits a BootstrapVersion parameter and a
    // CheckBootstrapVersion rule that read /cdk-bootstrap/hnb659fds/version,
    // which does not exist yet, so the CloudFormation console refuses the deploy.
    synthesizer: new cdk.DefaultStackSynthesizer({ generateBootstrapVersionRule: false }),
  });
  template = Template.fromStack(stack);
});

test('template declares no Parameters', () => {
  const json = template.toJSON();
  expect(json['Parameters']).toBeUndefined();
});

test('template declares no Rules', () => {
  const json = template.toJSON();
  expect(json['Rules']).toBeUndefined();
});

test('user policy has exactly one statement: sts:AssumeRole on the role ARN', () => {
  const policies = template.findResources('AWS::IAM::Policy');
  expect(Object.keys(policies)).toHaveLength(1);
  const policy = Object.values(policies)[0] as {
    Properties: {
      PolicyDocument: {
        Statement: Array<{ Action: string; Effect: string; Resource: unknown }>;
      };
    };
  };
  const stmts = policy.Properties.PolicyDocument.Statement;
  expect(stmts).toHaveLength(1);
  expect(stmts[0].Action).toBe('sts:AssumeRole');
  expect(stmts[0].Effect).toBe('Allow');
  expect(JSON.stringify(stmts[0].Resource)).toContain('BootstrapAdminRole');
});

test('role trust policy carries MFA condition', () => {
  const roles = template.findResources('AWS::IAM::Role', {
    Properties: { RoleName: 'cdk-bootstrap-admin' },
  });
  expect(Object.keys(roles)).toHaveLength(1);
  const role = Object.values(roles)[0] as {
    Properties: {
      AssumeRolePolicyDocument: {
        Statement: Array<{
          Condition?: Record<string, Record<string, string>>;
        }>;
      };
    };
  };
  const stmt = role.Properties.AssumeRolePolicyDocument.Statement[0];
  expect(stmt.Condition?.['Bool']?.['aws:MultiFactorAuthPresent']).toBe('true');
});

test('role MaxSessionDuration is 3600', () => {
  template.hasResourceProperties('AWS::IAM::Role', {
    RoleName: 'cdk-bootstrap-admin',
    MaxSessionDuration: 3600,
  });
});

test('role managed policy is only AdministratorAccess', () => {
  const roles = template.findResources('AWS::IAM::Role', {
    Properties: { RoleName: 'cdk-bootstrap-admin' },
  });
  const role = Object.values(roles)[0] as {
    Properties: { ManagedPolicyArns: unknown[] };
  };
  expect(role.Properties.ManagedPolicyArns).toHaveLength(1);
  expect(JSON.stringify(role.Properties.ManagedPolicyArns[0])).toContain('AdministratorAccess');
});
