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

type Stmt = {
  Sid: string; Effect: string; Action: string | string[]; Resource: unknown; Condition?: unknown;
};
const policyResources = () => [
  ...Object.values(template.findResources('AWS::IAM::Policy')),
  ...Object.values(template.findResources('AWS::IAM::ManagedPolicy')),
] as { Properties: { PolicyDocument: { Statement: Stmt[] } } }[];
const stmts = (): Stmt[] => policyResources().flatMap((p) => p.Properties.PolicyDocument.Statement);

test('trust admits a spira-concierge assumed-role session, without an MFA condition', () => {
  const roles = template.findResources('AWS::IAM::Role');
  expect(Object.keys(roles)).toHaveLength(1);
  const doc = (Object.values(roles)[0] as { Properties: { AssumeRolePolicyDocument: unknown } })
    .Properties.AssumeRolePolicyDocument;
  const json = JSON.stringify(doc);
  expect(json).toContain(':iam::189923011121:role/spira-concierge');
  expect(json.match(/role\//g)).toHaveLength(2);
  expect(json).not.toContain('MultiFactorAuthPresent');
  template.hasResourceProperties('AWS::IAM::Role', {
    RoleName: 'terraform-deploy',
    AssumeRolePolicyDocument: {
      Statement: [
        {
          Action: 'sts:AssumeRole',
          Effect: 'Allow',
          Principal: { AWS: Match.anyValue() },
          Condition: { ArnEquals: { 'aws:PrincipalArn': Match.anyValue() } },
        },
      ],
    },
  });
});

test('every Allow that writes IAM users/roles carries the boundary condition', () => {
  // The Spot service-linked role is AWS-owned and cannot carry a boundary.
  const writers = stmts().filter(
    (st) => st.Effect === 'Allow' && st.Sid !== 'SpotServiceLinkedRole' && ([] as string[]).concat(st.Action).some(
      (a) => /^iam:(Create|Put|Attach|Detach|Update|Delete|Tag|Untag)(User|Role|AccessKey|AssumeRole)/.test(a),
    ),
  );
  expect(writers.length).toBeGreaterThan(0);
  for (const st of writers) {
    expect(JSON.stringify(st.Condition ?? st)).toMatch(/iam:PermissionsBoundary.*DeployBoundary/);
  }
});

test('explicit Deny on IAM writes to spira-concierge, terraform-deploy and the boundary', () => {
  const deny = stmts().find((st) => st.Sid === 'DenyIamWritesOnGuards')!;
  expect(deny.Effect).toBe('Deny');
  const res = JSON.stringify(deny.Resource);
  expect(res).toContain('role/spira-concierge');
  expect(res).toContain('role/terraform-deploy');
  expect(res).toContain('DeployBoundary');
  const actions = ([] as string[]).concat(deny.Action);
  for (const v of ['iam:Attach*', 'iam:Put*', 'iam:Create*', 'iam:Update*', 'iam:Delete*']) {
    expect(actions).toContain(v);
  }
  const rm = stmts().find((st) => st.Sid === 'DenyBoundaryRemoval')!;
  expect(rm.Effect).toBe('Deny');
});

test('boundary policy denies IAM writes and assuming the deploy role', () => {
  template.hasResourceProperties('AWS::IAM::ManagedPolicy', {
    ManagedPolicyName: 'terraform-deploy-boundary',
    PolicyDocument: {
      Statement: Match.arrayWith([
        Match.objectLike({ Sid: 'NoIamWrites', Effect: 'Deny', Action: Match.arrayWith(['iam:Put*', 'iam:Attach*']) }),
        Match.objectLike({ Sid: 'NoAssumingDeployRole', Effect: 'Deny', Action: 'sts:AssumeRole' }),
      ]),
    },
  });
});

test('role policy is least privilege: no admin, no unscoped iam or secrets', () => {
  const statements = stmts().filter((st) => st.Sid !== 'Everything' && st.Effect === 'Allow');
  for (const st of statements) {
    const actions = ([] as string[]).concat(st.Action);
    expect(actions).not.toContain('*');
    const resources = JSON.stringify(st.Resource);
    if (actions.some((a) => a.startsWith('iam:') || a.startsWith('secretsmanager:'))) {
      expect(resources).not.toBe('"*"');
    }
  }
  expect(JSON.stringify(statements)).not.toContain('AdministratorAccess');
  template.resourceCountIs('AWS::IAM::ManagedPolicy', 3);
});

test('name patterns cover exactly spira and cubby, nothing broader', () => {
  const res = (sid: string): string[] => {
    const st = stmts().find((x) => x.Sid === sid)!;
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
  for (const sid of ['PrefixedIamRead', 'PrefixedIamPrincipalWrite', 'PrefixedIamPolicyWrite']) {
    const r = flat(sid);
    expect(r.every((x) => x === 'spira-*' || x === 'cubby-*')).toBe(true);
    expect(r.filter((x) => x === 'spira-*')).toHaveLength(r.length / 2);
  }
  expect(flat('PrefixedIamPrincipalWrite')).toHaveLength(4);
});

test('outputs: bucket name, region, role arn', () => {
  template.hasOutput('StateBucketName', {});
  template.hasOutput('Region', { Value: 'us-west-2' });
  template.hasOutput('DeployRoleArn', {});
});

test('adopted resources are named patterns, never a bare wildcard, and never the admin role', () => {
  const json = JSON.stringify(policyResources());
  expect(json).toContain('ephemeral-ci-*');
  expect(json).toContain('oidc-provider/token.actions.githubusercontent.com');
  expect(json).not.toContain('cdk-bootstrap');
});
