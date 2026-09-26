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
  // Token delivery is via ssm:SendCommand from the spill role; the instance
  // reads nothing from SSM and holds no inline grants.  Any inline policy
  // added to the instance role — regardless of the conditions it carries —
  // should fail this assertion.  A well-formed condition on a key that IAM
  // never populates for EC2 instance profiles (aws:PrincipalTag) is still
  // a broken policy; checking condition spelling cannot catch that failure,
  // which is why the previous shape-of-condition test was replaced here.
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

test('spill role does not grant ssm:PutParameter', () => {
  // Token delivery is via ssm:SendCommand — nothing is written to Parameter
  // Store.  Re-adding ssm:PutParameter to the spill role should fail here.
  const spillRoleId = Object.keys(
    template.findResources('AWS::IAM::Role', { Properties: { RoleName: 'ephemeral-ci-spill' } }),
  )[0];

  const allPolicies = template.findResources('AWS::IAM::Policy');
  const putParams = Object.entries(allPolicies).flatMap(([id, pRaw]) => {
    const p = pRaw as {
      Properties: {
        Roles: unknown[];
        PolicyDocument: { Statement: Array<Record<string, unknown>> };
      };
    };
    const isSpill = (([] as unknown[]).concat(p.Properties.Roles ?? [])).some((r) => {
      if (typeof r === 'string') return r === spillRoleId;
      return r != null && typeof r === 'object' && 'Ref' in r &&
        (r as { Ref: string }).Ref === spillRoleId;
    });
    if (!isSpill) return [];
    return p.Properties.PolicyDocument.Statement.filter((stmt) =>
      ([] as string[])
        .concat(stmt['Action'] as string | string[])
        .some((a) => a === 'ssm:PutParameter'),
    ).map(() => `${id}: ssm:PutParameter found on spill role`);
  });

  expect(putParams).toHaveLength(0);
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

test('spill role trust policy carries OIDC condition with expected sub', () => {
  const roles = template.findResources('AWS::IAM::Role', {
    Properties: {
      RoleName: 'ephemeral-ci-spill',
    },
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
  const statements = role.Properties.AssumeRolePolicyDocument.Statement;
  const oidcStatement = statements.find(
    (s) => s.Action === 'sts:AssumeRoleWithWebIdentity',
  );
  expect(oidcStatement).toBeDefined();
  expect(
    oidcStatement!.Condition!['StringLike'][
      'token.actions.githubusercontent.com:sub'
    ],
  ).toBe('repo:DeckDumpster/ephemeral-ci:*');
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

test('synth fails when alertEmail is absent', () => {
  const appNoEmail = new cdk.App();
  expect(() => {
    new SpillStack(appNoEmail, 'NoEmailStack', {
      env: { account: '189923011121', region: 'us-west-2' },
    });
  }).toThrow(/alertEmail/);
});
