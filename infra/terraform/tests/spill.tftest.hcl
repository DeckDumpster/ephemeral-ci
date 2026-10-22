# Offline: the AWS provider is mocked (apply runs against the mock), so this checks the shape the CDK stacks
# had, not the account. The account is checked by `terraform plan` showing no
# changes after the imports (scripts/discover-ids.sh, README.md).

mock_provider "aws" {
  mock_resource "aws_launch_template" {
    defaults = { id = "lt-0123456789abcdef0" }
  }
  mock_resource "aws_ssm_document" {
    defaults = {}
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::189923011121:role/mock" }
  }
  mock_resource "aws_iam_openid_connect_provider" {
    defaults = { arn = "arn:aws:iam::189923011121:oidc-provider/token.actions.githubusercontent.com" }
  }
  mock_resource "aws_s3_bucket" {
    defaults = { arn = "arn:aws:s3:::mock-bucket" }
  }
  mock_resource "aws_secretsmanager_secret" {
    defaults = { arn = "arn:aws:secretsmanager:us-west-2:189923011121:secret:mock-AbCdEf" }
  }
  mock_resource "aws_iam_user" {
    defaults = { arn = "arn:aws:iam::189923011121:user/mock" }
  }
  mock_resource "aws_iam_policy" {
    defaults = { arn = "arn:aws:iam::189923011121:policy/mock" }
  }
  mock_resource "aws_subnet" {
    defaults = { id = "subnet-0123456789abcdef0" }
  }
}

variables {
  import_enabled  = false
  deploy_role_arn = "arn:aws:iam::189923011121:role/terraform-deploy"
  physical_ids = {
    vpc                         = "vpc-0"
    subnet_a                    = "subnet-a"
    subnet_b                    = "subnet-b"
    subnet_c                    = "subnet-c"
    igw                         = "igw-0"
    route_table                 = "rtb-0"
    security_group              = "sg-0"
    launch_template             = "lt-0"
    instance_role_name          = "EphemeralCiSpill-InstanceRole-X"
    deliver_document_name       = "EphemeralCiSpill-Deliver-X"
    diagnose_document_name      = "EphemeralCiSpill-Diagnose-X"
    staging_bucket_name         = "mock-staging"
    staging_lifecycle_rule_id   = "rule"
    round_spill_user_policy_arn = "arn:aws:iam::189923011121:policy/RoundSpillPolicy-X"
    budget_name                 = "budget-X"
    snapshot_bucket_name        = "mock-snapshots"
    snapshot_lifecycle_rule_id  = "rule"
    backup_writer_user_name     = "writer-X"
    backup_secret_arn           = "arn:aws:secretsmanager:us-west-2:189923011121:secret:mock-AbCdEf"
    backup_secret_name          = "mock"
  }
}

run "launch_template_requires_imdsv2" {
  command = apply

  assert {
    condition     = aws_launch_template.spill.metadata_options[0].http_tokens == "required"
    error_message = "the spill launch template must require IMDSv2"
  }
}

run "security_group_has_no_ingress" {
  command = apply

  assert {
    condition     = length(aws_security_group.spill.ingress) == 0
    error_message = "the spill security group takes no inbound traffic"
  }
}

run "three_public_subnets_in_three_zones" {
  command = apply

  assert {
    condition     = length(distinct([for s in aws_subnet.public : s.availability_zone])) == 3
    error_message = "the spill subnets must span three availability zones"
  }
}

run "oidc_trust_policies_pin_the_audience" {
  command = apply

  assert {
    condition = alltrue([
      for r in [aws_iam_role.spill, aws_iam_role.ami_build, aws_iam_role.ci_test] :
      strcontains(r.assume_role_policy, "token.actions.githubusercontent.com:aud")
    ])
    error_message = "every OIDC role must pin aud"
  }

  assert {
    condition     = !strcontains(aws_iam_role.ami_build.assume_role_policy, "pull_request") && strcontains(aws_iam_role.ami_build.assume_role_policy, "ref:refs/heads/main")
    error_message = "the AMI build role is assumable from main only"
  }

  assert {
    condition     = strcontains(aws_iam_role.ami_build.assume_role_policy, "spira@1358347130:ref:refs/heads/spira-round-candidate/*")
    error_message = "the AMI build role must trust spira's spira-round-candidate/* branches"
  }

  assert {
    condition = length(regexall("spira@1358347130:ref:[^\"]*", aws_iam_role.ami_build.assume_role_policy)) == 2 && alltrue([
      for m in regexall("spira@1358347130:ref:[^\"]*", aws_iam_role.ami_build.assume_role_policy) :
      contains(["spira@1358347130:ref:refs/heads/main", "spira@1358347130:ref:refs/heads/spira-round-candidate/*"], m)
    ])
    error_message = "no spira ref other than main and spira-round-candidate/* may be trusted"
  }
}

run "buckets_are_private" {
  command = apply

  assert {
    condition     = aws_s3_bucket_public_access_block.snapshot.block_public_acls && aws_s3_bucket_public_access_block.snapshot.restrict_public_buckets
    error_message = "the snapshot bucket must block public access"
  }

  assert {
    condition     = aws_s3_bucket_versioning.snapshot.versioning_configuration[0].status == "Enabled"
    error_message = "the snapshot bucket must be versioned"
  }
}

run "backup_writer_is_put_only" {
  command = apply

  assert {
    condition     = strcontains(aws_iam_user_policy.backup_writer.policy, "s3:PutObject") && !strcontains(aws_iam_user_policy.backup_writer.policy, "s3:Get")
    error_message = "the backup writer may put objects and nothing else"
  }
}

run "spill_scripts_read_ids_from_ssm_parameters" {
  command = apply

  assert {
    condition = toset(keys(aws_ssm_parameter.spill)) == toset([
      "SubnetIds", "SecurityGroupId", "LaunchTemplateId", "LaunchTemplateName",
      "InstanceProfileName", "DeliverDocumentName", "DiagnoseDocumentName",
    ])
    error_message = "every id the spill scripts read must be an SSM parameter"
  }

  assert {
    condition     = alltrue([for p in aws_ssm_parameter.spill : startswith(p.name, "/ephemeral-ci/spill/")])
    error_message = "the parameters live under /ephemeral-ci/spill/ and nowhere else"
  }

  assert {
    condition = alltrue([
      for r in [aws_iam_role_policy.spill, aws_iam_role_policy.ami_build] :
      strcontains(r.policy, "ssm:GetParametersByPath") && strcontains(r.policy, "parameter/ephemeral-ci/spill/*")
    ])
    error_message = "the spill and ami-build roles may read the spill parameters"
  }
}

run "every_managed_principal_carries_the_deploy_boundary" {
  command = apply

  assert {
    condition = alltrue([
      for p in [
        aws_iam_role.instance, aws_iam_role.spill, aws_iam_role.ami_build, aws_iam_role.ci_test,
        aws_iam_user.round_spill, aws_iam_user.backup_writer,
      ] : p.permissions_boundary == "arn:aws:iam::189923011121:policy/terraform-deploy-boundary"
    ])
    error_message = "terraform-deploy may write a role or user only while it carries terraform-deploy-boundary"
  }
}

# terraform-deploy-boundary (lib/terraform-bootstrap-stack.ts) allows "*" and denies
# the iam write verbs and sts:AssumeRole on terraform-deploy. A policy is therefore
# unchanged by the boundary exactly when it grants none of those.
run "boundary_cuts_nothing_the_policies_grant" {
  command = apply

  assert {
    condition = alltrue([
      for d in [
        aws_iam_role_policy.spill.policy, aws_iam_role_policy.ami_build.policy,
        aws_iam_role_policy.ci_test.policy, aws_iam_policy.round_spill.policy,
        aws_iam_user_policy.backup_writer.policy,
        ] : alltrue([
          for st in jsondecode(d).Statement : st.Effect != "Allow" || alltrue([
            for a in flatten([try(st.Action, [])]) :
            !can(regex("^(\\*|iam:\\*|iam:(Create|Put|Attach|Detach|Update|Delete|Add|Remove|Set|Tag|Untag).*|sts:(\\*|AssumeRole))$", a))
          ])
      ])
    ])
    error_message = "a granted action falls under the boundary's deny: the boundary would cut it"
  }
}

run "root_volume_leaves_the_verify_floor_free" {
  command = plan

  assert {
    condition     = aws_launch_template.spill.block_device_mappings[0].ebs[0].volume_size == 100
    error_message = "root volume must be floor (60) + AMI used (25) + margin (15) = 100 GiB; see locals in spill.tf"
  }
}
