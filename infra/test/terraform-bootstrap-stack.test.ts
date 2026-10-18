import * as cdk from 'aws-cdk-lib';
import { Match, Template } from 'aws-cdk-lib/assertions';
import { TerraformBootstrapStack } from '../lib/terraform-bootstrap-stack';

let template: Template;

beforeAll(() => {
  const app = new cdk.App();
  const stack = new TerraformBootstrapStack(app, 'TestTfBootstrap', {
    env: { account: '189923011121', region: 'us-west-2' },
  });
  template = Template.fromStack(stack);
});

test('state bucket is private, versioned, encrypted and retained', () => {
  template.resourceCountIs('AWS::S3::Bucket', 1);
  template.hasResource('AWS::S3::Bucket', {
    DeletionPolicy: 'Retain',
    UpdateReplacePolicy: 'Retain',
    Properties: {
      PublicAccessBlockConfiguration: {
        BlockPublicAcls: true,
        BlockPublicPolicy: true,
        IgnorePublicAcls: true,
        RestrictPublicBuckets: true,
      },
      VersioningConfiguration: { Status: 'Enabled' },
      BucketEncryption: {
        ServerSideEncryptionConfiguration: [
          Match.objectLike({ ServerSideEncryptionByDefault: { SSEAlgorithm: 'AES256' } }),
        ],
      },
    },
  });
});

test('bucket policy denies non-TLS', () => {
  template.hasResourceProperties('AWS::S3::BucketPolicy', {
    PolicyDocument: {
      Statement: Match.arrayWith([
        Match.objectLike({
          Effect: 'Deny',
          Condition: { Bool: { 'aws:SecureTransport': 'false' } },
        }),
      ]),
    },
  });
});

test('no DynamoDB lock table', () => {
  template.resourceCountIs('AWS::DynamoDB::Table', 0);
});

test('role trust names only spira-concierge and requires MFA', () => {
  const roles = template.findResources('AWS::IAM::Role');
  expect(Object.keys(roles)).toHaveLength(1);
  const doc = (Object.values(roles)[0] as { Properties: { AssumeRolePolicyDocument: unknown } })
    .Properties.AssumeRolePolicyDocument;
  const json = JSON.stringify(doc);
  expect(json).toContain(':iam::189923011121:role/spira-concierge');
  expect(json.match(/role\//g)).toHaveLength(1);
  template.hasResourceProperties('AWS::IAM::Role', {
    RoleName: 'terraform-deploy',
    AssumeRolePolicyDocument: {
      Statement: [
        {
          Action: 'sts:AssumeRole',
          Effect: 'Allow',
          Principal: { AWS: Match.anyValue() },
          Condition: { Bool: { 'aws:MultiFactorAuthPresent': 'true' } },
        },
      ],
    },
  });
});

test('role policy is least privilege: no admin, no unscoped iam or secrets', () => {
  const policies = Object.values(template.findResources('AWS::IAM::Policy'));
  expect(policies).toHaveLength(1);
  const statements = (
    policies[0] as { Properties: { PolicyDocument: { Statement: { Action: string | string[]; Resource: unknown }[] } } }
  ).Properties.PolicyDocument.Statement;
  for (const st of statements) {
    const actions = ([] as string[]).concat(st.Action);
    expect(actions).not.toContain('*');
    const resources = JSON.stringify(st.Resource);
    if (actions.some((a) => a.startsWith('iam:') || a.startsWith('secretsmanager:'))) {
      expect(resources).not.toBe('"*"');
    }
  }
  expect(JSON.stringify(statements)).not.toContain('AdministratorAccess');
  template.resourceCountIs('AWS::IAM::ManagedPolicy', 0);
});

test('name patterns cover exactly spira and cubby, nothing broader', () => {
  const policy = Object.values(template.findResources('AWS::IAM::Policy'))[0] as {
    Properties: { PolicyDocument: { Statement: { Sid: string; Resource: unknown }[] } };
  };
  const res = (sid: string): string[] => {
    const st = policy.Properties.PolicyDocument.Statement.find((x) => x.Sid === sid)!;
    return ([] as unknown[]).concat(st.Resource).map((r) => JSON.stringify(r));
  };
  const strip = (r: string) =>
    r.replace(/\{"Ref":"AWS::Partition"\}/g, 'aws')
      .replace(/\{"Ref":"AWS::Region"\}/g, 'us-west-2')
      .replace(/\{"Ref":"AWS::AccountId"\}/g, '189923011121')
      .replace(/[\\{}\[\]"]|Fn::Join|:?,?(?=arn)/g, '');
  const flat = (sid: string) => res(sid).map((r) => {
    const m = r.match(/(?:s3:::|\/|secret:)((?:spira|cubby)[-/]\*(?:\/\*)?)"?\]?\]?\}?$/);
    return m ? m[1] : `UNMATCHED ${strip(r)}`;
  });
  expect(flat('PrefixedBuckets').sort()).toEqual(
    ['cubby-*', 'cubby-*/*', 'spira-*', 'spira-*/*'].sort(),
  );
  expect(flat('PrefixedSecrets').sort()).toEqual(['cubby/*', 'spira/*']);
  const iamRes = flat('PrefixedIam');
  expect(iamRes.filter((x) => x === 'spira-*')).toHaveLength(4);
  expect(iamRes.filter((x) => x === 'cubby-*')).toHaveLength(4);
  expect(iamRes).toHaveLength(8);
});

test('outputs: bucket name, region, role arn', () => {
  template.hasOutput('StateBucketName', {});
  template.hasOutput('Region', { Value: 'us-west-2' });
  template.hasOutput('DeployRoleArn', {});
});

test('adopted resources are named patterns, never a bare wildcard, and never the admin role', () => {
  const policies = Object.values(template.findResources('AWS::IAM::Policy'));
  const json = JSON.stringify(policies);
  expect(json).toContain('ephemeral-ci-*');
  expect(json).toContain('oidc-provider/token.actions.githubusercontent.com');
  expect(json).not.toContain('cdk-bootstrap');
});
