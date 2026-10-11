import * as cdk from 'aws-cdk-lib';
import { Match, Template } from 'aws-cdk-lib/assertions';
import { BackupStack } from '../lib/backup-stack';

let template: Template;

beforeAll(() => {
  const app = new cdk.App();
  const stack = new BackupStack(app, 'TestBackup', {
    env: { account: '189923011121', region: 'us-west-2' },
  });
  template = Template.fromStack(stack);
});

test('bucket is private, versioned and encrypted', () => {
  template.hasResourceProperties('AWS::S3::Bucket', {
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
    LifecycleConfiguration: {
      Rules: [
        Match.objectLike({
          Status: 'Enabled',
          NoncurrentVersionExpiration: { NoncurrentDays: 30 },
        }),
      ],
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

test('writer policy grants exactly s3:PutObject on the spira/ prefix', () => {
  const users = template.findResources('AWS::IAM::User');
  expect(Object.keys(users)).toHaveLength(1);
  const policies = template.findResources('AWS::IAM::Policy');
  const writerPolicies = Object.values(policies).filter((p) =>
    JSON.stringify((p as { Properties: unknown }).Properties).includes('"Users"'),
  );
  expect(writerPolicies).toHaveLength(1);
  const statements = (
    writerPolicies[0] as { Properties: { PolicyDocument: { Statement: unknown[] } } }
  ).Properties.PolicyDocument.Statement;
  expect(statements).toHaveLength(1);
  const st = statements[0] as { Effect: string; Action: string; Resource: unknown };
  expect(st.Effect).toBe('Allow');
  expect(st.Action).toBe('s3:PutObject');
  expect(JSON.stringify(st.Resource)).toContain('/spira/*');
});

test('writer key lands in a secret readable by the concierge role only', () => {
  template.resourceCountIs('AWS::SecretsManager::Secret', 1);
  template.resourceCountIs('AWS::IAM::AccessKey', 1);
  template.hasResourceProperties('AWS::IAM::Policy', {
    Roles: ['spira-concierge'],
    PolicyDocument: {
      Statement: [
        Match.objectLike({
          Action: ['secretsmanager:GetSecretValue', 'secretsmanager:DescribeSecret'],
          Resource: { Ref: Match.stringLikeRegexp('WriterKeySecret') },
        }),
      ],
    },
  });
});
