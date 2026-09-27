import * as cdk from 'aws-cdk-lib';
import { Match, Template } from 'aws-cdk-lib/assertions';
import { SpillStack } from '../lib/spill-stack';

let template: Template;

beforeAll(() => {
  const app = new cdk.App({ context: { alertEmail: 'test@example.com' } });
  const stack = new SpillStack(app, 'TestStack', {
    env: { account: '189923011121', region: 'us-west-2' },
  });
  template = Template.fromStack(stack);
});

test('security group has zero ingress rules', () => {
  const sgs = template.findResources('AWS::EC2::SecurityGroup');
  expect(Object.keys(sgs)).toHaveLength(1);
  const sg = Object.values(sgs)[0] as { Properties: Record<string, unknown> };
  const ingress = (sg.Properties?.SecurityGroupIngress as unknown[]) ?? [];
  expect(ingress).toHaveLength(0);
});

test('launch template sets HttpTokens=required', () => {
  template.hasResourceProperties('AWS::EC2::LaunchTemplate', {
    LaunchTemplateData: {
      MetadataOptions: {
        HttpTokens: 'required',
      },
    },
  });
});

test('instance role carries no inline policy', () => {
  // Token delivery uses a custom SSM document with {{ssm-secure:}} references.
  // The SSM service expands the reference using the spill role's credentials;
  // the instance sees the decrypted value injected by SSM and never calls the
  // SSM API directly.  No inline policy on the instance role is needed.
  const instanceRoles = template.findResources('AWS::IAM::Role', {
    Properties: {
      AssumeRolePolicyDocument: {
        Statement: Match.arrayWith([
          Match.objectLike({ Principal: { Service: 'ec2.amazonaws.com' } }),
        ]),
      },
    },
  });
  const instanceRoleId = Object.keys(instanceRoles)[0];

  const allPolicies = template.findResources('AWS::IAM::Policy');
  const attached = Object.values(allPolicies).filter((pRaw) => {
    const p = pRaw as { Properties: { Roles: unknown[] } };
    return (([] as unknown[]).concat(p.Properties.Roles ?? [])).some((r) => {
      if (typeof r === 'string') return r === instanceRoleId;
      return r != null && typeof r === 'object' && 'Ref' in r &&
        (r as { Ref: string }).Ref === instanceRoleId;
    });
  });

  expect(attached).toHaveLength(0);
});

test('spill role grants ssm:PutParameter, ssm:DeleteParameter, ssm:GetParameter, ssm:GetParameters scoped to runner-token prefix', () => {
  // Token delivery: the spill role writes the token to Parameter Store before
  // send-command, passes it as {{ssm-secure:/path}} in --parameters, and
  // deletes the entry after the command completes.  GetParameter and
  // GetParameters are distinct IAM actions; both are granted because AWS
  // example policies for SecureString retrieval show GetParameters (plural)
  // and neither action implies the other.  All four actions must be scoped to
  // /ephemeral-ci/runner-token/* only.
  const spillRoleId = Object.keys(
    template.findResources('AWS::IAM::Role', { Properties: { RoleName: 'ephemeral-ci-spill' } }),
  )[0];

  const allPolicies = template.findResources('AWS::IAM::Policy');

  type RawPolicy = {
    Properties: {
      Roles: unknown[];
      PolicyDocument: { Statement: Array<{ Action: string | string[]; Resource: string | string[] }> };
    };
  };

  const spillStatements = Object.values(allPolicies).flatMap((pRaw) => {
    const p = pRaw as RawPolicy;
    const isSpill = (([] as unknown[]).concat(p.Properties.Roles ?? [])).some((r) => {
      if (typeof r === 'string') return r === spillRoleId;
      return r != null && typeof r === 'object' && 'Ref' in r &&
        (r as { Ref: string }).Ref === spillRoleId;
    });
    return isSpill ? p.Properties.PolicyDocument.Statement : [];
  });

  const putStmts = spillStatements.filter((s) =>
    ([] as string[]).concat(s.Action).includes('ssm:PutParameter'),
  );
  const deleteStmts = spillStatements.filter((s) =>
    ([] as string[]).concat(s.Action).includes('ssm:DeleteParameter'),
  );
  const getStmts = spillStatements.filter((s) =>
    ([] as string[]).concat(s.Action).includes('ssm:GetParameter'),
  );
  const getParametersStmts = spillStatements.filter((s) =>
    ([] as string[]).concat(s.Action).includes('ssm:GetParameters'),
  );

  expect(putStmts).toHaveLength(1);
  expect(deleteStmts).toHaveLength(1);
  expect(getStmts).toHaveLength(1);
  expect(getParametersStmts).toHaveLength(1);

  const putResources = ([] as string[]).concat(putStmts[0].Resource);
  const deleteResources = ([] as string[]).concat(deleteStmts[0].Resource);
  const getResources = ([] as string[]).concat(getStmts[0].Resource);
  const getParametersResources = ([] as string[]).concat(getParametersStmts[0].Resource);
  expect(putResources.every((r) => r.includes('/ephemeral-ci/runner-token/'))).toBe(true);
  expect(deleteResources.every((r) => r.includes('/ephemeral-ci/runner-token/'))).toBe(true);
  expect(getResources.every((r) => r.includes('/ephemeral-ci/runner-token/'))).toBe(true);
  expect(getParametersResources.every((r) => r.includes('/ephemeral-ci/runner-token/'))).toBe(true);
});

test('spill role does not grant ssm:ListCommandInvocations', () => {
  // provision.sh polls command status via ssm:GetCommandInvocation only;
  // ssm:ListCommandInvocations is not used and should not be granted.
  const spillRoleId = Object.keys(
    template.findResources('AWS::IAM::Role', { Properties: { RoleName: 'ephemeral-ci-spill' } }),
  )[0];

  const allPolicies = template.findResources('AWS::IAM::Policy');
  type RawPolicy = {
    Properties: {
      Roles: unknown[];
      PolicyDocument: { Statement: Array<Record<string, unknown>> };
    };
  };
  const found = Object.values(allPolicies).flatMap((pRaw) => {
    const p = pRaw as RawPolicy;
    const isSpill = (([] as unknown[]).concat(p.Properties.Roles ?? [])).some((r) => {
      if (typeof r === 'string') return r === spillRoleId;
      return r != null && typeof r === 'object' && 'Ref' in r &&
        (r as { Ref: string }).Ref === spillRoleId;
    });
    if (!isSpill) return [];
    return p.Properties.PolicyDocument.Statement.filter((s) =>
      ([] as string[])
        .concat(s['Action'] as string | string[])
        .includes('ssm:ListCommandInvocations'),
    );
  });
  expect(found).toHaveLength(0);
});

test('instance role managed policy is only AmazonSSMManagedInstanceCore', () => {
  const roles = template.findResources('AWS::IAM::Role', {
    Properties: {
      AssumeRolePolicyDocument: {
        Statement: Match.arrayWith([
          Match.objectLike({
            Principal: { Service: 'ec2.amazonaws.com' },
          }),
        ]),
      },
    },
  });
  const matches = Object.values(roles);
  expect(matches).toHaveLength(1);
  const managed = (matches[0] as { Properties: Record<string, unknown> }).Properties
    .ManagedPolicyArns as unknown[];
  expect(managed).toHaveLength(1);
  expect(JSON.stringify(managed[0])).toContain('AmazonSSMManagedInstanceCore');
});

test('custom SSM document for runner token delivery is defined', () => {
  // ec2_deliver_token uses a custom SSM document instead of AWS-RunShellScript
  // so it can accept {{ssm-secure:}} parameter references that SSM expands
  // server-side without recording the resolved value in command history.
  const docs = template.findResources('AWS::SSM::Document');
  const deliverDoc = Object.values(docs).find((d) => {
    const name = (d as { Properties: Record<string, unknown> }).Properties.Name;
    return name === 'ephemeral-ci-deliver-runner-token';
  });
  expect(deliverDoc).toBeDefined();
  const content = (deliverDoc as { Properties: { Content: Record<string, unknown> } })
    .Properties.Content as Record<string, unknown>;
  expect(content['schemaVersion']).toBe('2.2');
  const params = content['parameters'] as Record<string, unknown>;
  expect(params).toHaveProperty('RunnerToken');
  expect(params).toHaveProperty('RunnerLabel');
  expect(params).toHaveProperty('RunnerUrl');
  expect(params).toHaveProperty('RunnerGroup');
});

// Immutable OIDC sub prefix, sourced from:
//   gh api repos/DeckDumpster/ephemeral-ci/actions/oidc/customization/sub
const IMMUTABLE_SUB_PREFIX = 'repo:DeckDumpster@262905033/ephemeral-ci@1371818598:*';
const NAME_BASED_SUB = 'repo:DeckDumpster/ephemeral-ci:*';

function getOidcSub(roleName: string): string {
  const roles = template.findResources('AWS::IAM::Role', {
    Properties: { RoleName: roleName },
  });
  expect(Object.keys(roles)).toHaveLength(1);
  const role = Object.values(roles)[0] as {
    Properties: {
      AssumeRolePolicyDocument: {
        Statement: Array<{
          Action: string;
          Condition?: Record<string, Record<string, string>>;
        }>;
      };
    };
  };
  const oidcStatement = role.Properties.AssumeRolePolicyDocument.Statement.find(
    (s) => s.Action === 'sts:AssumeRoleWithWebIdentity',
  );
  expect(oidcStatement).toBeDefined();
  return oidcStatement!.Condition!['StringLike']['token.actions.githubusercontent.com:sub'];
}

test('spill role trust policy carries immutable OIDC sub prefix', () => {
  expect(getOidcSub('ephemeral-ci-spill')).toBe(IMMUTABLE_SUB_PREFIX);
});

test('spill role trust policy does not carry name-based OIDC sub', () => {
  expect(getOidcSub('ephemeral-ci-spill')).not.toBe(NAME_BASED_SUB);
});

test('ci-test role trust policy carries immutable OIDC sub prefix', () => {
  expect(getOidcSub('ephemeral-ci-ci-test')).toBe(IMMUTABLE_SUB_PREFIX);
});

test('ci-test role trust policy does not carry name-based OIDC sub', () => {
  expect(getOidcSub('ephemeral-ci-ci-test')).not.toBe(NAME_BASED_SUB);
});

test('budget does not declare a BudgetName', () => {
  // BudgetName must stay absent. AWS::Budgets::Budget forces a replacement whenever
  // notificationsWithSubscribers changes (threshold tuned, subscriber added, etc.).
  // CloudFormation creates the new resource before deleting the old; a fixed name collides
  // with the one still standing and the deploy fails with "same name but different
  // internalId". A generated name cannot collide, making every future notification edit
  // safe. See db-sbvl for the incident that established this rule.
  const budgetResources = template.findResources('AWS::Budgets::Budget');
  const budget = Object.values(budgetResources)[0] as {
    Properties: { Budget: Record<string, unknown> };
  };
  expect(budget.Properties.Budget['BudgetName']).toBeUndefined();
});

test('budget is 100 USD MONTHLY account-wide', () => {
  template.hasResourceProperties('AWS::Budgets::Budget', {
    Budget: {
      BudgetType: 'COST',
      TimeUnit: 'MONTHLY',
      BudgetLimit: {
        Amount: 100,
        Unit: 'USD',
      },
    },
  });
  const budgets = template.findResources('AWS::Budgets::Budget');
  const budget = Object.values(budgets)[0] as {
    Properties: { Budget: Record<string, unknown> };
  };
  expect(budget.Properties.Budget['CostFilters']).toBeUndefined();
});

type NotificationEntry = {
  Notification: {
    NotificationType: string;
    ComparisonOperator: string;
    Threshold: number;
  };
  Subscribers: Array<{ SubscriptionType: string }>;
};

function getBudgetNotifications(): NotificationEntry[] {
  const budgetResources = template.findResources('AWS::Budgets::Budget');
  const budget = Object.values(budgetResources)[0] as {
    Properties: { NotificationsWithSubscribers: NotificationEntry[] };
  };
  return budget.Properties.NotificationsWithSubscribers;
}

test('budget has exactly two notifications', () => {
  expect(getBudgetNotifications()).toHaveLength(2);
});

test('budget has ACTUAL notification at 80% GREATER_THAN with one EMAIL subscriber', () => {
  const actual = getBudgetNotifications().find(
    (n) => n.Notification.NotificationType === 'ACTUAL',
  );
  expect(actual).toBeDefined();
  expect(actual!.Notification.ComparisonOperator).toBe('GREATER_THAN');
  expect(actual!.Notification.Threshold).toBe(80);
  expect(actual!.Subscribers).toHaveLength(1);
  expect(actual!.Subscribers[0].SubscriptionType).toBe('EMAIL');
});

test('budget has FORECASTED notification at 100% with one EMAIL subscriber', () => {
  const forecasted = getBudgetNotifications().find(
    (n) => n.Notification.NotificationType === 'FORECASTED',
  );
  expect(forecasted).toBeDefined();
  expect(forecasted!.Notification.Threshold).toBe(100);
  expect(forecasted!.Subscribers).toHaveLength(1);
  expect(forecasted!.Subscribers[0].SubscriptionType).toBe('EMAIL');
});

test('ci-test role does not carry ReadOnlyAccess', () => {
  // ReadOnlyAccess includes ssm:List* which allowed any branch of this
  // repository to read SSM command history.  The role is now minimal:
  // iam:SimulatePrincipalPolicy plus IAM read access only.
  const ciTestRoles = template.findResources('AWS::IAM::Role', {
    Properties: { RoleName: 'ephemeral-ci-ci-test' },
  });
  expect(Object.keys(ciTestRoles)).toHaveLength(1);
  const managed = (Object.values(ciTestRoles)[0] as { Properties: Record<string, unknown> })
    .Properties.ManagedPolicyArns as unknown[] | undefined;
  const hasReadOnly = (managed ?? []).some(
    (p) => typeof p === 'string' && p.includes('ReadOnlyAccess'),
  );
  expect(hasReadOnly).toBe(false);
});

test('synth fails when alertEmail is absent', () => {
  const appNoEmail = new cdk.App();
  expect(() => {
    new SpillStack(appNoEmail, 'NoEmailStack', {
      env: { account: '189923011121', region: 'us-west-2' },
    });
  }).toThrow(/alertEmail/);
});
