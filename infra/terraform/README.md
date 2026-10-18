# infra/terraform

Terraform for what ephemeral-ci's retired CDK stacks (`EphemeralCiSpill`,
`EphemeralCiBackup`, `BootstrapIdentity`) created. Nothing here recreates a
resource: `imports.tf` adopts the existing ones. The one CDK stack left is
`TerraformBootstrap` (`../lib`), which provides the state bucket and the
`terraform-deploy` role these roots run as.

| Root | Runs as | State key |
| --- | --- | --- |
| `infra/terraform` (spill + backup) | `terraform-deploy` | `ephemeral-ci/infra/terraform.tfstate` |
| `infra/terraform/bootstrap-identity` | `cdk-bootstrap-admin` (MFA) | `ephemeral-ci/infra/bootstrap-identity/terraform.tfstate` |

`bootstrap-identity` is its own root because the role it manages is
`AdministratorAccess`: if `terraform-deploy` could edit it, `terraform-deploy`
would be admin.

Policy and trust documents live as files in `policies/` and `documents/`,
generated once from the synthesised CDK templates (statement order and content
unchanged), so what Terraform compares against is what CloudFormation wrote.
The SSM documents are stored compact (no whitespace), as CloudFormation sent
them: the provider compares `content` as a string.

Expected adoption plan: `44 to import, 7 to add, 2 to change, 0 to destroy`,
the two changes being only the `ssm:GetParametersByPath` statements on
`aws_iam_role_policy.spill` and `.ami_build`.

## Migration runbook (Concierge, MFA session)

1. Widen `terraform-deploy` so it can manage the adopted names:
   `npx cdk deploy TerraformBootstrap` (from `infra/`).
2. Discover the physical ids, from the repository root, as `terraform-deploy`:

       scripts/tf-discover-ids.sh

3. Adopt and prove nothing changes:

       cd infra/terraform
       terraform init -backend-config=backend.hcl
       terraform plan -out=adopt.plan        # must end: "N to import, 0 to add, 0 to change, 0 to destroy"
       terraform apply adopt.plan
       terraform plan                        # must end: "No changes."

   Attach the last plan's output to the bead. Any diff is a mismatch between
   `*.tf` and the account: fix the `.tf` (never the account) until it is clean.

4. The same for the identity root, as `cdk-bootstrap-admin`:

       cd infra/terraform/bootstrap-identity
       terraform init -backend-config="bucket=<StateBucketName>"
       terraform plan -out=adopt.plan && terraform apply adopt.plan && terraform plan

5. Retire the stacks (as admin). This sets `DeletionPolicy: Retain` on every
   resource of the deployed template and refuses to delete unless it holds:

       scripts/tf-retire-stack.sh EphemeralCiBackup --delete
       scripts/tf-retire-stack.sh BootstrapIdentity --delete
       scripts/tf-retire-stack.sh EphemeralCiSpill --delete   # NOT YET, see below

6. Delete `imports.tf` and the `import` blocks of `bootstrap-identity/main.tf`.

**`EphemeralCiSpill` stays until one real spill has gone green reading SSM.**
Its readers (`provision.sh`, `ami-build.sh`, `ec2-diag.sh`,
`check-spill-permissions.sh`, `test-reap.sh`) now read the parameters under
`/ephemeral-ci/spill/` (`ssm.tf`; `SubnetIds`, `SecurityGroupId`,
`LaunchTemplateId`, `LaunchTemplateName`, `InstanceProfileName`,
`DeliverDocumentName`, `DiagnoseDocumentName`), so `terraform apply` must have
written them before any spill runs. Order: apply, run `spill-probe.yml`, then
step 5 for this stack. The roles still hold `cloudformation:DescribeStacks` on
the stack for consumers outside this repository (spira's round AMI build); drop
that statement when those move.

## Not managed

- `WriterKey` (the backup writer's access key): Terraform cannot import an
  access key. It is retained, untouched; rotate it by creating a new key and
  updating the secret.
- The secret's value (key pair + bucket name): Terraform never holds the secret
  access key. Only the secret's metadata is managed.
- The Terraform state bucket and `terraform-deploy` role: `TerraformBootstrap`.

## CDK logical id -> Terraform address

### EphemeralCiSpill

| CDK logical id | Terraform address |
| --- | --- |
| `Vpc` | `aws_vpc.spill` |
| `PublicSubnet` / `PublicSubnetB` / `PublicSubnetC` | `aws_subnet.public["a"]` / `["b"]` / `["c"]` |
| `Igw` | `aws_internet_gateway.spill` |
| `IgwAttachment` | `aws_internet_gateway.spill` (its `vpc_id`) |
| `RouteTable` | `aws_route_table.public` |
| `DefaultRoute` | `aws_route.default` |
| `SubnetRtAssoc` / `SubnetRtAssocB` / `SubnetRtAssocC` | `aws_route_table_association.public["a"]` / `["b"]` / `["c"]` |
| `SecurityGroup` | `aws_security_group.spill` |
| `InstanceRole3CCE2F1D` | `aws_iam_role.instance` + `aws_iam_role_policy_attachment.instance_ssm` (its managed policy) |
| `InstanceProfile` | `aws_iam_instance_profile.spill` |
| `GithubOidcProvider` | `aws_iam_openid_connect_provider.github` |
| `LaunchTemplate` | `aws_launch_template.spill` |
| `DeliverRunnerTokenDocument` | `aws_ssm_document.deliver_runner_token` |
| `DiagnoseRunnerDocument` | `aws_ssm_document.diagnose_runner` |
| `SpotServiceLinkedRole` | `aws_iam_service_linked_role.spot` |
| `SpillRoleCE3CD693` | `aws_iam_role.spill` |
| `SpillRoleDefaultPolicyB8F8E7AD` | `aws_iam_role_policy.spill` |
| `AmiBuildRole6BD673DE` | `aws_iam_role.ami_build` |
| `AmiBuildRoleDefaultPolicy4C0F4677` | `aws_iam_role_policy.ami_build` |
| `RoundAmiStagingF2C9ECD5` | `aws_s3_bucket.round_ami_staging` + `_server_side_encryption_configuration`, `_public_access_block`, `_lifecycle_configuration` |
| `RoundAmiStagingPolicyDB5C2917` | `aws_s3_bucket_policy.round_ami_staging` |
| `RoundSpillUser349294B9` | `aws_iam_user.round_spill` |
| `RoundSpillPolicyD259D208` | `aws_iam_policy.round_spill` + `aws_iam_user_policy_attachment.round_spill` |
| `CiTestRole2D425DAD` | `aws_iam_role.ci_test` |
| `CiTestRoleDefaultPolicyFE475D0D` | `aws_iam_role_policy.ci_test` |
| `MonthlyBudget` | `aws_budgets_budget.monthly` |

### EphemeralCiBackup

| CDK logical id | Terraform address |
| --- | --- |
| `SnapshotBucketB2BF31D3` | `aws_s3_bucket.snapshot` + `_versioning`, `_server_side_encryption_configuration`, `_public_access_block`, `_lifecycle_configuration` |
| `SnapshotBucketPolicy022DC250` | `aws_s3_bucket_policy.snapshot` |
| `Writer3ED51D24` | `aws_iam_user.backup_writer` |
| `WriterDefaultPolicyDC585BCE` | `aws_iam_user_policy.backup_writer` |
| `WriterKey` | not managed (see above) |
| `WriterKeySecret7FE05A53` | `aws_secretsmanager_secret.backup_writer_key` (metadata only) |
| `ConciergeRolePolicy50292239` | `aws_iam_role_policy.concierge_secret_read` |

### BootstrapIdentity (`bootstrap-identity/`)

| CDK logical id | Terraform address |
| --- | --- |
| `BootstrapUser7CDDD448` | `aws_iam_user.bootstrap` |
| `BootstrapUserDefaultPolicy59B531F4` | `aws_iam_user_policy.bootstrap` |
| `BootstrapAdminRole69ABCF3A` | `aws_iam_role.bootstrap_admin` + `aws_iam_role_policy_attachment.bootstrap_admin` |

## Tests

    terraform fmt -check -recursive
    terraform init -backend=false && terraform validate && terraform test

`terraform test` mocks the provider, so it checks shape (IMDSv2, no ingress,
OIDC audience pins, put-only writer) and not the account; the account is
checked by the zero-change plan above. CI runs all of it (`infra` job).
