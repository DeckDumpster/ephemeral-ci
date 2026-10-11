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

test('synth creates subnets in us-west-2a, us-west-2b, and us-west-2c', () => {
  // db-5ne2: single-AZ spill is fragile; all three subnets must be present so
  // InsufficientInstanceCapacity in one AZ does not break the spill entirely.
  const subnets = template.findResources('AWS::EC2::Subnet');
  const azs = Object.values(subnets).map(
    (s) => (s as { Properties: { AvailabilityZone: string } }).Properties.AvailabilityZone,
  );
  expect(azs).toContain('us-west-2a');
  expect(azs).toContain('us-west-2b');
  expect(azs).toContain('us-west-2c');
  expect(azs).toHaveLength(3);
});

test('SubnetIds output lists all three subnets (no stale SubnetId)', () => {
  // db-5ne2: output was renamed from SubnetId (one AZ) to SubnetIds (all AZs).
  // A stale SubnetId output naming one AZ must not be present.
  const outputs = template.findOutputs('SubnetIds');
  expect(Object.keys(outputs)).toHaveLength(1);

  const stale = template.findOutputs('SubnetId');
  expect(Object.keys(stale)).toHaveLength(0);
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

test('launch template root device name is /dev/sda1', () => {
  // AMI root device is /dev/sda1 (set in scripts/ami-build.sh).  Any other
  // name declares an additional blank volume instead of overriding the root,
  // producing the MissingParameter error from RunInstances.
  const lts = template.findResources('AWS::EC2::LaunchTemplate');
  const lt = Object.values(lts)[0] as {
    Properties: {
      LaunchTemplateData: {
        BlockDeviceMappings: Array<{ DeviceName: string }>;
      };
    };
  };
  const mappings = lt.Properties.LaunchTemplateData.BlockDeviceMappings;
  expect(mappings).toHaveLength(1);
  expect(mappings[0].DeviceName).toBe('/dev/sda1');
});

test('launch template root device has VolumeSize 32', () => {
  // 32 GiB matches ROOT_DISK_GIB in scripts/ami-build.sh.  VolumeSize is
  // required by EC2 when no SnapshotId is present; absence causes RunInstances
  // to fail with MissingParameter.
  const lts = template.findResources('AWS::EC2::LaunchTemplate');
  const lt = Object.values(lts)[0] as {
    Properties: {
      LaunchTemplateData: {
        BlockDeviceMappings: Array<{ Ebs: { VolumeSize: number } }>;
      };
    };
  };
  const ebs = lt.Properties.LaunchTemplateData.BlockDeviceMappings[0].Ebs;
  expect(ebs.VolumeSize).toBe(32);
});

test('launch template root device is encrypted', () => {
  // ami-build.sh creates the image with Encrypted:true; the launch template
  // must carry the same flag so spill runners match the builder's security posture.
  const lts = template.findResources('AWS::EC2::LaunchTemplate');
  const lt = Object.values(lts)[0] as {
    Properties: {
      LaunchTemplateData: {
        BlockDeviceMappings: Array<{ Ebs: { Encrypted: boolean } }>;
      };
    };
  };
  const ebs = lt.Properties.LaunchTemplateData.BlockDeviceMappings[0].Ebs;
  expect(ebs.Encrypted).toBe(true);
});

test('instance role carries no inline policy', () => {
  // Token delivery passes the runner token via SSM send-command plain String
  // parameters; the instance receives the already-delivered value from the
  // document and never calls the SSM API directly.  No inline policy needed.
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

test('spill role has no Parameter Store statements (PutParameter, DeleteParameter, GetParameter, GetParameters)', () => {
  // db-99yv: token is delivered as a plain String parameter directly via
  // send-command; the spill role must not hold any Parameter Store grants.
  // Asserting absence here prevents quiet reinstatement.
  const spillRoleId = Object.keys(
    template.findResources('AWS::IAM::Role', { Properties: { RoleName: 'ephemeral-ci-spill' } }),
  )[0];

  const allPolicies = template.findResources('AWS::IAM::Policy');

  type RawPolicy = {
    Properties: {
      Roles: unknown[];
      PolicyDocument: { Statement: Array<{ Action: string | string[] }> };
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

  const paramStoreActions = [
    'ssm:PutParameter', 'ssm:DeleteParameter', 'ssm:GetParameter', 'ssm:GetParameters',
  ];
  const paramStoreStmts = spillStatements.filter((s) =>
    ([] as string[]).concat(s.Action as string | string[])
      .some((a) => paramStoreActions.includes(a)),
  );
  expect(paramStoreStmts).toHaveLength(0);
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

test('SSM document for runner token delivery declares no Name property', () => {
  // Content changes to AWS::SSM::Document force REPLACEMENT. A pinned Name
  // means CloudFormation must create the replacement before deleting the old
  // one — it cannot, because the name is already taken. Leaving Name absent
  // lets CloudFormation generate one so every future Content edit deploys
  // cleanly. See db-0v6i for the incident that established this rule.
  const docs = template.findResources('AWS::SSM::Document');
  expect(Object.keys(docs)).toHaveLength(1);
  const doc = Object.values(docs)[0] as { Properties: Record<string, unknown> };
  expect(doc.Properties['Name']).toBeUndefined();
});

test('DeliverDocumentName output exists', () => {
  // provision.sh reads the generated document name from this output via
  // ec2_load_stack so send-command carries the real name without hardcoding it.
  const outputs = template.findOutputs('DeliverDocumentName');
  expect(Object.keys(outputs)).toHaveLength(1);
});

test('custom SSM document for runner token delivery has correct schema', () => {
  // ec2_deliver_token uses a custom SSM document to write the runner init file.
  // RunnerToken is passed as a plain String parameter via send-command --parameters.
  const docs = template.findResources('AWS::SSM::Document');
  expect(Object.keys(docs)).toHaveLength(1);
  const deliverDoc = Object.values(docs)[0] as { Properties: { Content: Record<string, unknown> } };
  const content = deliverDoc.Properties.Content as Record<string, unknown>;
  expect(content['schemaVersion']).toBe('2.2');
  const params = content['parameters'] as Record<string, unknown>;
  expect(params).toHaveProperty('RunnerToken');
  expect(params).toHaveProperty('RunnerLabel');
  expect(params).toHaveProperty('RunnerUrl');
  expect(params).toHaveProperty('RunnerGroup');
});

test('no spill role SendCommand statement names the literal document name', () => {
  // A literal document name in the IAM resource ARN re-introduces the pinned-name
  // trap: the ARN stops matching on replacement and the grant silently breaks.
  // The resource must be a CloudFormation intrinsic referencing the document.
  const spillRoleId = Object.keys(
    template.findResources('AWS::IAM::Role', { Properties: { RoleName: 'ephemeral-ci-spill' } }),
  )[0];

  const allPolicies = template.findResources('AWS::IAM::Policy');
  type RawPolicy = {
    Properties: {
      Roles: unknown[];
      PolicyDocument: {
        Statement: Array<{ Action: string | string[]; Resource: unknown }>;
      };
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

  const sendCommandDocStmts = spillStatements.filter((s) => {
    const actions = ([] as string[]).concat(s.Action as string | string[]);
    if (!actions.includes('ssm:SendCommand')) return false;
    const resources = ([] as unknown[]).concat(s.Resource);
    return resources.some((r) => JSON.stringify(r).includes(':document/'));
  });

  expect(sendCommandDocStmts).toHaveLength(1);
  const resources = ([] as unknown[]).concat(sendCommandDocStmts[0].Resource);
  // Resource must be a CloudFormation intrinsic, not a plain string with a literal name
  const hasLiteralName = resources.some(
    (r): r is string => typeof r === 'string' && r.includes(':document/ephemeral-ci-deliver-runner-token'),
  );
  expect(hasLiteralName).toBe(false);
  const hasIntrinsic = resources.some((r) => typeof r === 'object' && r !== null);
  expect(hasIntrinsic).toBe(true);
});

// Immutable OIDC sub prefix for ephemeral-ci, sourced from:
//   gh api repos/DeckDumpster/ephemeral-ci/actions/oidc/customization/sub
const EPHEMERAL_CI_SUB_PREFIX = 'repo:DeckDumpster@262905033/ephemeral-ci@1371818598:*';
const NAME_BASED_SUB = 'repo:DeckDumpster/ephemeral-ci:*';

// All expected spill role sub prefixes, one per consuming repository.
// Sourced from: gh api repos/DeckDumpster/<repo>/actions/oidc/customization/sub
const SPILL_SUB_PREFIXES = [
  'repo:DeckDumpster@262905033/ephemeral-ci@1371818598:*',
  'repo:DeckDumpster@262905033/pokedumpster@1247247276:*',
  'repo:DeckDumpster@262905033/household@1202178120:*',
  'repo:DeckDumpster@262905033/spira@1358347130:*',
  'repo:DeckDumpster/deckdumpster:*',
];

function getOidcSubs(roleName: string): string | string[] {
  const roles = template.findResources('AWS::IAM::Role', {
    Properties: { RoleName: roleName },
  });
  expect(Object.keys(roles)).toHaveLength(1);
  const role = Object.values(roles)[0] as {
    Properties: {
      AssumeRolePolicyDocument: {
        Statement: Array<{
          Action: string;
          Condition?: Record<string, Record<string, string | string[]>>;
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

test('spill role trust policy lists one sub per consuming repository', () => {
  const subs = getOidcSubs('ephemeral-ci-spill');
  expect(Array.isArray(subs)).toBe(true);
  expect(subs as string[]).toHaveLength(SPILL_SUB_PREFIXES.length);
  for (const expected of SPILL_SUB_PREFIXES) {
    expect(subs as string[]).toContain(expected);
  }
});

test('spill role trust policy sub values have no wildcard before the final colon', () => {
  // A wildcard in owner or repository position (e.g. repo:DeckDumpster*/*:*)
  // is the impersonation-by-rename hole immutable subjects exist to close.
  const subs = getOidcSubs('ephemeral-ci-spill') as string[];
  for (const sub of subs) {
    const beforeLastColon = sub.slice(0, sub.lastIndexOf(':'));
    expect(beforeLastColon).not.toContain('*');
  }
});

test('ci-test role trust policy carries immutable OIDC sub prefix', () => {
  expect(getOidcSubs('ephemeral-ci-ci-test')).toBe(EPHEMERAL_CI_SUB_PREFIX);
});

test('ci-test role trust policy does not carry name-based OIDC sub', () => {
  expect(getOidcSubs('ephemeral-ci-ci-test')).not.toBe(NAME_BASED_SUB);
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

test('spill role PassRole is scoped to instance role ARN with iam:PassedToService condition', () => {
  // iam:PassRole without iam:PassedToService would allow passing this instance
  // role to any service that accepts a role — not just EC2.  The condition is
  // load-bearing.  The resource must reference instanceRole.roleArn via
  // CloudFormation intrinsic (never a hardcoded ARN) because the physical name
  // is generated and changes on replacement.
  const spillRoleId = Object.keys(
    template.findResources('AWS::IAM::Role', { Properties: { RoleName: 'ephemeral-ci-spill' } }),
  )[0];
  const instanceRoleId = Object.keys(
    template.findResources('AWS::IAM::Role', {
      Properties: {
        AssumeRolePolicyDocument: {
          Statement: Match.arrayWith([
            Match.objectLike({ Principal: { Service: 'ec2.amazonaws.com' } }),
          ]),
        },
      },
    }),
  )[0];

  const allPolicies = template.findResources('AWS::IAM::Policy');
  type RawPolicy = {
    Properties: {
      Roles: unknown[];
      PolicyDocument: {
        Statement: Array<{
          Action: string | string[];
          Resource: unknown;
          Condition?: Record<string, Record<string, string>>;
        }>;
      };
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

  const passRoleStmts = spillStatements.filter((s) =>
    ([] as string[]).concat(s.Action as string | string[]).includes('iam:PassRole'),
  );
  expect(passRoleStmts).toHaveLength(1);
  const stmt = passRoleStmts[0];

  // Resource must be a GetAtt reference to the instance role, not a hardcoded ARN
  const resources = ([] as unknown[]).concat(stmt.Resource);
  expect(resources).toHaveLength(1);
  const resource = resources[0] as Record<string, unknown>;
  expect(resource).toHaveProperty('Fn::GetAtt');
  const getAtt = resource['Fn::GetAtt'] as [string, string];
  expect(getAtt[0]).toBe(instanceRoleId);
  expect(getAtt[1]).toBe('Arn');

  // Condition must carry iam:PassedToService scoped to EC2
  expect(stmt.Condition).toBeDefined();
  expect(stmt.Condition!['StringEquals']['iam:PassedToService']).toBe('ec2.amazonaws.com');
});

test('spill role SendCommand on instance uses aws:ResourceTag/spill:owner (not ec2:ResourceTag)', () => {
  // ec2:ResourceTag is an EC2-service key; SSM does not populate it for
  // ssm:SendCommand — using it makes the condition permanently unsatisfiable.
  // aws:ResourceTag is the global key and applies to both services.
  const spillRoleId = Object.keys(
    template.findResources('AWS::IAM::Role', { Properties: { RoleName: 'ephemeral-ci-spill' } }),
  )[0];

  const allPolicies = template.findResources('AWS::IAM::Policy');
  type RawStatement = {
    Action: string | string[];
    Resource: string | string[];
    Condition?: Record<string, Record<string, string>>;
  };
  type RawPolicy = {
    Properties: {
      Roles: unknown[];
      PolicyDocument: { Statement: RawStatement[] };
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

  // Find the SendCommand statement scoped to EC2 instance ARNs (not SSM documents).
  // Resources may be objects (CloudFormation intrinsics) when formatArn produces a
  // Fn::Sub — filter to strings only before calling .includes().
  const sendCommandInstanceStmt = spillStatements.find((s) => {
    const actions = ([] as string[]).concat(s.Action as string | string[]);
    const resources = ([] as unknown[])
      .concat(s.Resource)
      .filter((r): r is string => typeof r === 'string');
    return actions.includes('ssm:SendCommand') &&
      resources.some((r) => r.includes(':instance/'));
  });

  expect(sendCommandInstanceStmt).toBeDefined();
  expect(sendCommandInstanceStmt!.Condition).toBeDefined();

  const cond = sendCommandInstanceStmt!.Condition!['StringEquals'];
  expect(cond['aws:ResourceTag/spill:owner']).toBe('ephemeral-ci');
  // ec2:ResourceTag is NOT populated by SSM — it must not appear here
  expect(cond['ec2:ResourceTag/spill:owner']).toBeUndefined();
});

test('no spill role SendCommand statement has an empty-account resource ARN', () => {
  // The empty-account ARN form (arn:aws:ssm:region::document/*) addresses AWS-owned
  // documents only; it does not cover account-owned documents. Asserting absence of
  // that form is the machine-readable guard against reintroducing the bug this bead fixes.
  const spillRoleId = Object.keys(
    template.findResources('AWS::IAM::Role', { Properties: { RoleName: 'ephemeral-ci-spill' } }),
  )[0];

  const allPolicies = template.findResources('AWS::IAM::Policy');
  type RawPolicy = {
    Properties: {
      Roles: unknown[];
      PolicyDocument: {
        Statement: Array<{ Action: string | string[]; Resource: unknown }>;
      };
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

  const sendCommandStmts = spillStatements.filter((s) =>
    ([] as string[]).concat(s.Action as string | string[]).includes('ssm:SendCommand'),
  );

  // An empty account field appears as a literal "::" between region and resource
  // in the ARN, e.g. "arn:aws:ssm:us-west-2::document/...".
  const emptyAccountArns = sendCommandStmts.flatMap((s) =>
    ([] as unknown[])
      .concat(s.Resource)
      .filter((r): r is string => typeof r === 'string')
      .filter((r) => /^arn:[^:]+:[^:]+:[^:]+::[^:]+/.test(r)),
  );

  expect(emptyAccountArns).toHaveLength(0);
});

test('spill role RunInstances on launch template is scoped to specific template ID with no Condition', () => {
  // db-p5cj: the prior statement used launch-template/* conditioned on a
  // CloudFormation stack-name tag that CloudFormation never applies to launch
  // templates.  The condition was permanently unsatisfiable and the grant
  // silently covered every launch template in the account.  The fix scopes the
  // resource to the specific template ID via launchTemplate.ref — no condition
  // needed, and no wildcard that could silently widen if a tag were dropped.
  const spillRoleId = Object.keys(
    template.findResources('AWS::IAM::Role', { Properties: { RoleName: 'ephemeral-ci-spill' } }),
  )[0];

  const allPolicies = template.findResources('AWS::IAM::Policy');
  type RawStatement = {
    Action: string | string[];
    Resource: unknown;
    Condition?: Record<string, unknown>;
  };
  type RawPolicy = {
    Properties: {
      Roles: unknown[];
      PolicyDocument: { Statement: RawStatement[] };
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

  // Find the RunInstances statement whose resource targets a launch-template
  const ltStatement = spillStatements.find((s) => {
    const actions = ([] as string[]).concat(s.Action as string | string[]);
    if (!actions.includes('ec2:RunInstances')) return false;
    const resources = ([] as unknown[]).concat(s.Resource);
    return resources.some((r) => JSON.stringify(r).includes('launch-template/'));
  });

  expect(ltStatement).toBeDefined();

  // Resource must NOT be the wildcard — reintroducing launch-template/* must fail this test
  const resources = ([] as unknown[]).concat(ltStatement!.Resource);
  const hasWildcard = resources.some(
    (r) => typeof r === 'string' && r.endsWith('launch-template/*'),
  );
  expect(hasWildcard).toBe(false);

  // Resource must be a CloudFormation intrinsic (i.e. references the template ID token)
  const hasIntrinsic = resources.some((r) => typeof r === 'object' && r !== null);
  expect(hasIntrinsic).toBe(true);

  // Statement must carry no Condition
  expect(ltStatement!.Condition).toBeUndefined();
});

test('spill role CreateTags carries ec2:CreateAction=RunInstances condition', () => {
  // ec2:CreateAction=RunInstances limits tagging to the RunInstances call only.
  // Without it, the role could retag existing resources and bring them inside
  // the tag-scoped TerminateInstances and SendCommand permissions.
  const spillRoleId = Object.keys(
    template.findResources('AWS::IAM::Role', { Properties: { RoleName: 'ephemeral-ci-spill' } }),
  )[0];

  const allPolicies = template.findResources('AWS::IAM::Policy');
  type RawPolicy = {
    Properties: {
      Roles: unknown[];
      PolicyDocument: {
        Statement: Array<{
          Action: string | string[];
          Resource: string | string[];
          Condition?: Record<string, Record<string, string>>;
        }>;
      };
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

  const createTagsStmts = spillStatements.filter((s) =>
    ([] as string[]).concat(s.Action as string | string[]).includes('ec2:CreateTags'),
  );
  expect(createTagsStmts).toHaveLength(1);
  const stmt = createTagsStmts[0];

  // Resources must cover instance, volume, and network-interface
  const resources = ([] as string[]).concat(stmt.Resource);
  expect(resources.some((r) => r.includes(':instance/'))).toBe(true);
  expect(resources.some((r) => r.includes(':volume/'))).toBe(true);
  expect(resources.some((r) => r.includes(':network-interface/'))).toBe(true);

  // Condition must carry ec2:CreateAction=RunInstances
  expect(stmt.Condition).toBeDefined();
  expect(stmt.Condition!['StringEquals']['ec2:CreateAction']).toBe('RunInstances');
});

test('token-delivery document waits for the tailnet only when asked (sp-7330sk)', () => {
  const docs = template.findResources('AWS::SSM::Document');
  const content = (Object.values(docs) as { Properties: { Content: any } }[])
    .map((d) => d.Properties.Content)
    .find((c) => c.parameters?.TailnetWaitSeconds)!;
  // Default 0: callers that do not ask for the tailnet neither wait nor print.
  expect(content.parameters.TailnetWaitSeconds.default).toBe('0');
  expect(content.parameters.TailnetWaitSeconds.allowedPattern).toBe('^[0-9]{1,4}$');
  const lines: string[] = content.mainSteps[0].inputs.runCommand;
  const wait = lines.findIndex((l) => l.includes('{{ TailnetWaitSeconds }}'));
  const write = lines.findIndex((l) => l.includes('/run/gh-runner-init.partial'));
  // The wait must come before the init file is written: writing it is what
  // triggers runner registration.
  expect(wait).toBeGreaterThanOrEqual(0);
  expect(wait).toBeLessThan(write);
  expect(lines.join('\n')).toContain('/run/ephemeral-ci-tailnet');
});

test('security group still has no ingress: tailnet traffic needs none (sp-7330sk)', () => {
  const sg = Object.values(template.findResources('AWS::EC2::SecurityGroup'))[0] as {
    Properties: Record<string, unknown>;
  };
  expect(sg.Properties.SecurityGroupIngress ?? []).toHaveLength(0);
});

test('stack creates the EC2 Spot service-linked role', () => {
  // sp-k9fhgr: without it every spot launch fails with
  // ServiceLinkedRoleCreationNotPermitted and falls through to on-demand.
  template.hasResourceProperties('AWS::IAM::ServiceLinkedRole', {
    AWSServiceName: 'spot.amazonaws.com',
  });
});

test('spill role holds exactly what reap.sh needs, tag-conditioned (sp-3grl9x)', () => {
  // reap.yml assumes this role over OIDC. Terminate and delete must stay
  // bound to spill:owner=ephemeral-ci so the reaper cannot touch anything else.
  const spillRoleId = Object.keys(
    template.findResources('AWS::IAM::Role', { Properties: { RoleName: 'ephemeral-ci-spill' } }),
  )[0];
  type Stmt = {
    Action: string | string[];
    Resource: unknown;
    Condition?: Record<string, Record<string, string>>;
  };
  const stmts = Object.values(template.findResources('AWS::IAM::Policy')).flatMap((pRaw) => {
    const p = pRaw as {
      Properties: { Roles: Array<{ Ref?: string }>; PolicyDocument: { Statement: Stmt[] } };
    };
    const mine = (p.Properties.Roles ?? []).some((r) => r.Ref === spillRoleId);
    return mine ? p.Properties.PolicyDocument.Statement : [];
  });
  const having = (action: string) =>
    stmts.filter((s) => ([] as string[]).concat(s.Action).includes(action));

  for (const action of ['ec2:DescribeInstances', 'ec2:DescribeVolumes']) {
    expect(having(action)).toHaveLength(1);
  }
  for (const action of ['ec2:TerminateInstances', 'ec2:DeleteVolume']) {
    const found = having(action);
    expect(found).toHaveLength(1);
    expect(found[0].Condition?.StringEquals?.['ec2:ResourceTag/spill:owner']).toBe('ephemeral-ci');
  }
});

// ── AMI build role ─────────────────────────────────────────────────────────

function amiBuildStatements(): Array<{ Action: string | string[]; Condition?: unknown }> {
  const policies = template.findResources('AWS::IAM::Policy');
  const roles = template.findResources('AWS::IAM::Role', { Properties: { RoleName: 'ephemeral-ci-ami-build' } });
  const roleId = Object.keys(roles)[0];
  const pol = Object.values(policies).find((p) =>
    JSON.stringify((p as { Properties: { Roles: unknown } }).Properties.Roles).includes(roleId),
  ) as { Properties: { PolicyDocument: { Statement: Array<{ Action: string | string[]; Condition?: unknown }> } } };
  return pol.Properties.PolicyDocument.Statement;
}

test('ami build role trusts only ephemeral-ci on refs/heads/main', () => {
  const subs = getOidcSubs('ephemeral-ci-ami-build');
  expect(subs).toBe('repo:DeckDumpster@262905033/ephemeral-ci@1371818598:ref:refs/heads/main');
});

test('ami build role scopes its build-time grants to spill:owner=ephemeral-ci', () => {
  const sts = amiBuildStatements();
  for (const action of ['ec2:StopInstances', 'ec2:DeregisterImage', 'ec2:DeleteSnapshot', 'ec2:CreateImage']) {
    const hit = sts.filter((s) => ([] as string[]).concat(s.Action).includes(action));
    expect(hit.length).toBeGreaterThan(0);
    for (const s of hit) {
      expect(JSON.stringify(s.Condition)).toContain('ephemeral-ci');
    }
  }
  const describe = sts.filter((s) => ([] as string[]).concat(s.Action).includes('ec2:DescribeSnapshots'));
  expect(describe.length).toBeGreaterThan(0);
});

test('ami build role holds the launch-and-deliver grants ami-build.sh uses', () => {
  const sts = amiBuildStatements();
  const having = (action: string) =>
    sts.filter((s) => ([] as string[]).concat(s.Action).includes(action));
  // RunInstances on the instance resource without a vmtoken requirement.
  const launch = having('ec2:RunInstances').filter((s) =>
    JSON.stringify(s).includes('instance/*') && !JSON.stringify(s.Condition).includes('vmtoken'));
  expect(launch).toHaveLength(1);
  expect(JSON.stringify(launch[0].Condition)).toContain('aws:RequestTag/spill:owner');
  expect(JSON.stringify(launch[0].Condition)).toContain('c7i.2xlarge');
  expect(having('ec2:RunInstances').length).toBeGreaterThanOrEqual(3);
  expect(JSON.stringify(having('iam:PassRole'))).toContain('ec2.amazonaws.com');
  expect(JSON.stringify(having('ec2:TerminateInstances')[0].Condition)).toContain('spill:owner');
  expect(JSON.stringify(having('ec2:CreateTags'))).toContain('RunInstances');
  expect(JSON.stringify(having('ssm:SendCommand'))).toContain('document/AWS-RunShellScript');
  for (const a of ['ssm:GetCommandInvocation', 'ssm:DescribeInstanceInformation',
    'cloudformation:DescribeStacks', 'ec2:DescribeInstances', 'ec2:DescribeImages']) {
    expect(having(a).length).toBeGreaterThan(0);
  }
});

test('spill role does not hold the build-time grants', () => {
  const policies = template.findResources('AWS::IAM::Policy');
  const roles = template.findResources('AWS::IAM::Role', { Properties: { RoleName: 'ephemeral-ci-spill' } });
  const roleId = Object.keys(roles)[0];
  const pol = Object.values(policies).find((p) =>
    JSON.stringify((p as { Properties: { Roles: unknown } }).Properties.Roles).includes(roleId),
  );
  const txt = JSON.stringify(pol);
  for (const a of ['ec2:CreateImage', 'ec2:DeregisterImage', 'ec2:DeleteSnapshot', 'ec2:StopInstances']) {
    expect(txt).not.toContain(a);
  }
});

test('spill role can read console output of spill:owner instances only (sp-5cgnxb)', () => {
  const stmts = Object.values(template.findResources('AWS::IAM::Policy'))
    .flatMap((p) => (p as any).Properties.PolicyDocument.Statement)
    .filter((st: any) => ([] as string[]).concat(st.Action).includes('ec2:GetConsoleOutput'));
  expect(stmts).toHaveLength(1);
  expect(stmts[0].Condition.StringEquals['ec2:ResourceTag/spill:owner']).toBe('ephemeral-ci');
});

test('token-delivery document raises threads-max as root before the init file (sp-5cgnxb)', () => {
  const docs = Object.values(template.findResources('AWS::SSM::Document')) as any[];
  const lines: string[] = docs
    .map((d) => d.Properties.Content)
    .find((c) => c.parameters?.RunnerToken).mainSteps[0].inputs.runCommand;
  const sysctl = lines.findIndex((l) => l.includes('kernel.threads-max'));
  const write = lines.findIndex((l) => l.includes('/run/gh-runner-init.partial'));
  expect(sysctl).toBeGreaterThanOrEqual(0);
  expect(sysctl).toBeLessThan(write);
});

test('a read-only diagnose document is exported for ec2-diag.sh (sp-5cgnxb)', () => {
  expect(Object.keys(template.findOutputs('DiagnoseDocumentName'))).toHaveLength(1);
  const docs = Object.values(template.findResources('AWS::SSM::Document')) as any[];
  const diag = docs.map((d) => d.Properties.Content).find((c) => !c.parameters);
  const text = JSON.stringify(diag);
  for (const needle of ['journalctl', '_diag', 'ip route get', 'tailscale status']) {
    expect(text).toContain(needle);
  }
});

// ── Round-VM spill user (sp-12hi6j) ────────────────────────────────────────

type RStmt = { Action: string | string[]; Resource: unknown; Condition?: any };
function roundUserStatements(): RStmt[] {
  const userId = Object.keys(template.findResources('AWS::IAM::User', { Properties: { UserName: 'spira-round-spill' } }))[0];
  expect(userId).toBeDefined();
  return Object.values(template.findResources('AWS::IAM::Policy')).flatMap((p: any) =>
    (p.Properties.Users ?? []).some((u: any) => u.Ref === userId) ? p.Properties.PolicyDocument.Statement : []);
}
const rHaving = (sts: RStmt[], a: string) => sts.filter((s) => ([] as string[]).concat(s.Action).includes(a));

test('round spill user exists, has no access key and no managed policy', () => {
  template.resourceCountIs('AWS::IAM::AccessKey', 0);
  const users = template.findResources('AWS::IAM::User', { Properties: { UserName: 'spira-round-spill' } });
  expect(Object.keys(users)).toHaveLength(1);
  expect((Object.values(users)[0] as any).Properties.ManagedPolicyArns).toBeUndefined();
  expect(Object.keys(template.findOutputs('RoundSpillUserName'))).toHaveLength(1);
  expect(Object.keys(template.findOutputs('RoundSpillInstanceProfileName'))).toHaveLength(1);
});

test('round spill user launches only c7i.* tagged round into the spill subnets and SG', () => {
  const runs = rHaving(roundUserStatements(), 'ec2:RunInstances');
  const inst = runs.filter((s) => JSON.stringify(s.Resource).includes(':instance/*'));
  expect(inst).toHaveLength(1);
  expect(inst[0].Condition.StringEquals['aws:RequestTag/spill:owner']).toBe('round');
  expect(inst[0].Condition.StringLike['ec2:InstanceType']).toBe('c7i.*');
  const net = JSON.stringify(runs.filter((s) => JSON.stringify(s.Resource).includes(':subnet/')));
  for (const id of ['PublicSubnet', 'PublicSubnetB', 'PublicSubnetC', 'SecurityGroup']) {
    expect(net).toContain(id);
  }
  expect(net).not.toContain('subnet/*');
  expect(net).not.toContain('security-group/*');
  const img = runs.filter((s) => JSON.stringify(s.Resource).includes('image/*'));
  expect(img).toHaveLength(1);
  expect(img[0].Condition.StringEquals['ec2:ResourceTag/spill:owner']).toBe('round');
});

test('round spill user tags only on create and manages only round instances', () => {
  const sts = roundUserStatements();
  const tags = rHaving(sts, 'ec2:CreateTags');
  expect(tags).toHaveLength(1);
  expect(tags[0].Condition.StringEquals['ec2:CreateAction']).toBe('RunInstances');
  for (const a of ['ec2:TerminateInstances', 'ec2:StopInstances', 'ec2:StartInstances']) {
    const h = rHaving(sts, a);
    expect(h).toHaveLength(1);
    expect(h[0].Condition.StringEquals['ec2:ResourceTag/spill:owner']).toBe('round');
  }
});

test('round spill user reaches SSM only via AWS-RunShellScript and round-tagged instances', () => {
  const sts = roundUserStatements();
  const send = rHaving(sts, 'ssm:SendCommand');
  expect(send).toHaveLength(2);
  expect(JSON.stringify(send.map((s) => s.Resource))).toContain('document/AWS-RunShellScript');
  const onInst = send.find((s) => JSON.stringify(s.Resource).includes(':instance/*'))!;
  expect(onInst.Condition.StringEquals['aws:ResourceTag/spill:owner']).toBe('round');
  expect(rHaving(sts, 'ssm:GetCommandInvocation')).toHaveLength(1);
  expect(rHaving(sts, 'ssm:DescribeInstanceInformation')).toHaveLength(1);
  const pass = rHaving(sts, 'iam:PassRole');
  expect(pass).toHaveLength(1);
  expect(pass[0].Condition.StringEquals['iam:PassedToService']).toBe('ec2.amazonaws.com');
  expect(JSON.stringify(pass[0].Resource)).toContain('InstanceRole');
});

test('round spill user holds nothing broader than the allowed action set', () => {
  const allowed = new Set([
    'ec2:RunInstances', 'ec2:CreateTags', 'ec2:TerminateInstances', 'ec2:StopInstances',
    'ec2:StartInstances', 'ec2:Describe*', 'ssm:SendCommand', 'ssm:GetCommandInvocation',
    'ssm:DescribeInstanceInformation', 'iam:PassRole',
  ]);
  const sts = roundUserStatements();
  for (const s of sts) {
    expect((s as any).Effect).toBe('Allow');
    for (const a of ([] as string[]).concat(s.Action)) expect(allowed.has(a)).toBe(true);
    // Every wildcard resource is a read-only action.
    if (JSON.stringify(s.Resource) === '"*"') {
      for (const a of ([] as string[]).concat(s.Action)) {
        expect(/^(ec2:Describe\*|ssm:(GetCommandInvocation|DescribeInstanceInformation))$/.test(a)).toBe(true);
      }
    }
  }
});

test('ami build role is also assumable from spira main and may use the round tag', () => {
  const subs = ([] as string[]).concat(getOidcSubs('ephemeral-ci-ami-build') as any);
  expect(subs).toContain('repo:DeckDumpster@262905033/spira@1358347130:ref:refs/heads/main');
  expect(subs).toContain('repo:DeckDumpster@262905033/ephemeral-ci@1371818598:ref:refs/heads/main');
  const sts = amiBuildStatements();
  const launch = sts.filter((s: any) => JSON.stringify(s).includes('c7i.2xlarge'));
  expect(JSON.stringify(launch)).toContain('"round"');
  expect(JSON.stringify(sts.filter((s) => ([] as string[]).concat(s.Action).includes('ec2:TerminateInstances')))).toContain('round');
});
