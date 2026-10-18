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
    (st) => st.Effect === 'Allow' && st.Sid !== 'SpotServiceLinkedRole' && !/IamBoundaryTagWrite$/.test(st.Sid ?? '') && ([] as string[]).concat(st.Action).some(
      (a) => /^iam:(Create|Put|Attach|Detach|Update|Delete|Tag|Untag)(User|Role|AssumeRole)/.test(a),
    ),
  );
  expect(writers.length).toBeGreaterThan(0);
  for (const st of writers) {
    expect(JSON.stringify(st.Condition ?? st)).toMatch(/iam:PermissionsBoundary.*DeployBoundary/);
  }
});

test('access keys are allowed only on tagged users, with a condition key CreateAccessKey supports', () => {
  const keyStmts = stmts().filter(
    (st) => st.Effect === 'Allow' && ([] as string[]).concat(st.Action).some((a) => /AccessKey$/.test(a) && a !== 'iam:ListAccessKeys'),
  );
  expect(keyStmts.length).toBeGreaterThan(0);
  for (const st of keyStmts) {
    expect(([] as string[]).concat(st.Action)).toEqual(
      expect.arrayContaining(['iam:CreateAccessKey', 'iam:DeleteAccessKey', 'iam:UpdateAccessKey']),
    );
    expect(st.Condition).toEqual({ StringEquals: { 'aws:ResourceTag/terraform-deploy-boundary': 'true' } });
    expect(JSON.stringify(st.Condition)).not.toMatch(/PermissionsBoundary/);
    for (const r of ([] as any[]).concat(st.Resource)) expect(JSON.stringify(r)).toMatch(/:user\/(spira|cubby|pkdump|dumpstar|ephemeral-ci|EphemeralCiSpill|EphemeralCiBackup)-\*/);
  }
});

test('existing principals can be tagged, but only with the boundary tag key, never on the guards', () => {
  const tag = stmts().filter((st) => /IamBoundaryTagWrite$/.test(st.Sid ?? ''));
  expect(tag.length).toBeGreaterThan(0);
  for (const st of tag) {
    expect(st.Effect).toBe('Allow');
    expect(([] as string[]).concat(st.Action).sort()).toEqual(['iam:TagRole', 'iam:TagUser', 'iam:UntagRole', 'iam:UntagUser']);
    expect(st.Condition).toEqual({ 'ForAllValues:StringEquals': { 'aws:TagKeys': ['terraform-deploy-boundary'] } });
    const res = JSON.stringify(st.Resource);
    expect(res).not.toContain('role/spira-concierge');
    expect(res).not.toContain('role/terraform-deploy"');
  }
  const deny = stmts().find((st) => st.Sid === 'DenyIamWritesOnGuards')!;
  expect(([] as string[]).concat(deny.Action)).toEqual(expect.arrayContaining(['iam:Tag*']));
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

test('name patterns cover exactly spira, cubby, pkdump and dumpstar, nothing broader', () => {
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
    const m = r.match(/(?:s3:::|\/|secret:)((?:spira|cubby|pkdump|dumpstar)[-/]\*(?:\/\*)?)"?\]?\]?\}?$/);
    return m ? m[1] : `UNMATCHED ${strip(r)}`;
  });
  expect(flat('PrefixedBuckets').sort()).toEqual(
    ['cubby-*', 'cubby-*/*', 'dumpstar-*', 'dumpstar-*/*', 'pkdump-*', 'pkdump-*/*', 'spira-*', 'spira-*/*'].sort(),
  );
  expect(flat('PrefixedSecrets').sort()).toEqual(['cubby/*', 'dumpstar/*', 'pkdump/*', 'spira/*']);
  for (const sid of ['PrefixedIamRead', 'PrefixedIamPrincipalWrite', 'PrefixedIamPolicyWrite']) {
    const r = flat(sid);
    expect(r.every((x) => ['spira-*', 'cubby-*', 'pkdump-*', 'dumpstar-*'].includes(x))).toBe(true);
    for (const p of ['spira-*', 'cubby-*', 'pkdump-*', 'dumpstar-*']) expect(r.filter((x) => x === p)).toHaveLength(r.length / 4);
  }
  expect(flat('PrefixedIamPrincipalWrite')).toHaveLength(8);
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
