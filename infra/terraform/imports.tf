# Adopt what the CDK stacks created; nothing is recreated. Physical ids come
# from physical_ids (scripts/discover-ids.sh). Once the state holds every
# resource this file has done its work and may be deleted.

# ── EphemeralCiSpill ──────────────────────────────────────────────────────────
import {
  for_each = local.import
  to       = aws_vpc.spill
  id       = var.physical_ids["vpc"]
}

import {
  for_each = local.import
  to       = aws_subnet.public["a"]
  id       = var.physical_ids["subnet_a"]
}

import {
  for_each = local.import
  to       = aws_subnet.public["b"]
  id       = var.physical_ids["subnet_b"]
}

import {
  for_each = local.import
  to       = aws_subnet.public["c"]
  id       = var.physical_ids["subnet_c"]
}

import {
  for_each = local.import
  to       = aws_internet_gateway.spill
  id       = var.physical_ids["igw"]
}

import {
  for_each = local.import
  to       = aws_route_table.public
  id       = var.physical_ids["route_table"]
}

import {
  for_each = local.import
  to       = aws_route.default
  id       = "${var.physical_ids["route_table"]}_0.0.0.0/0"
}

import {
  for_each = local.import
  to       = aws_route_table_association.public["a"]
  id       = "${var.physical_ids["subnet_a"]}/${var.physical_ids["route_table"]}"
}

import {
  for_each = local.import
  to       = aws_route_table_association.public["b"]
  id       = "${var.physical_ids["subnet_b"]}/${var.physical_ids["route_table"]}"
}

import {
  for_each = local.import
  to       = aws_route_table_association.public["c"]
  id       = "${var.physical_ids["subnet_c"]}/${var.physical_ids["route_table"]}"
}

import {
  for_each = local.import
  to       = aws_security_group.spill
  id       = var.physical_ids["security_group"]
}

import {
  for_each = local.import
  to       = aws_iam_role.instance
  id       = var.physical_ids["instance_role_name"]
}

import {
  for_each = local.import
  to       = aws_iam_role_policy_attachment.instance_ssm
  id       = "${var.physical_ids["instance_role_name"]}/arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

import {
  for_each = local.import
  to       = aws_iam_instance_profile.spill
  id       = "ephemeral-ci-spill-instance"
}

import {
  for_each = local.import
  to       = aws_iam_openid_connect_provider.github
  id       = "arn:aws:iam::189923011121:oidc-provider/token.actions.githubusercontent.com"
}

import {
  for_each = local.import
  to       = aws_launch_template.spill
  id       = var.physical_ids["launch_template"]
}

import {
  for_each = local.import
  to       = aws_ssm_document.deliver_runner_token
  id       = var.physical_ids["deliver_document_name"]
}

import {
  for_each = local.import
  to       = aws_ssm_document.diagnose_runner
  id       = var.physical_ids["diagnose_document_name"]
}

import {
  for_each = local.import
  to       = aws_iam_service_linked_role.spot
  id       = "arn:aws:iam::189923011121:role/aws-service-role/spot.amazonaws.com/AWSServiceRoleForEC2Spot"
}

import {
  for_each = local.import
  to       = aws_iam_role.spill
  id       = "ephemeral-ci-spill"
}

import {
  for_each = local.import
  to       = aws_iam_role_policy.spill
  id       = "ephemeral-ci-spill:SpillRoleDefaultPolicyB8F8E7AD"
}

import {
  for_each = local.import
  to       = aws_iam_role.ami_build
  id       = "ephemeral-ci-ami-build"
}

import {
  for_each = local.import
  to       = aws_iam_role_policy.ami_build
  id       = "ephemeral-ci-ami-build:AmiBuildRoleDefaultPolicy4C0F4677"
}

import {
  for_each = local.import
  to       = aws_iam_role.ci_test
  id       = "ephemeral-ci-ci-test"
}

import {
  for_each = local.import
  to       = aws_iam_role_policy.ci_test
  id       = "ephemeral-ci-ci-test:CiTestRoleDefaultPolicyFE475D0D"
}

import {
  for_each = local.import
  to       = aws_s3_bucket.round_ami_staging
  id       = var.physical_ids["staging_bucket_name"]
}

import {
  for_each = local.import
  to       = aws_s3_bucket_server_side_encryption_configuration.round_ami_staging
  id       = var.physical_ids["staging_bucket_name"]
}

import {
  for_each = local.import
  to       = aws_s3_bucket_public_access_block.round_ami_staging
  id       = var.physical_ids["staging_bucket_name"]
}

import {
  for_each = local.import
  to       = aws_s3_bucket_lifecycle_configuration.round_ami_staging
  id       = var.physical_ids["staging_bucket_name"]
}

import {
  for_each = local.import
  to       = aws_s3_bucket_policy.round_ami_staging
  id       = var.physical_ids["staging_bucket_name"]
}

import {
  for_each = local.import
  to       = aws_iam_user.round_spill
  id       = "spira-round-spill"
}

import {
  for_each = local.import
  to       = aws_iam_policy.round_spill
  id       = var.physical_ids["round_spill_user_policy_arn"]
}

import {
  for_each = local.import
  to       = aws_iam_user_policy_attachment.round_spill
  id       = "spira-round-spill/${var.physical_ids["round_spill_user_policy_arn"]}"
}

import {
  for_each = local.import
  to       = aws_budgets_budget.monthly
  id       = "189923011121:${var.physical_ids["budget_name"]}"
}

# ── EphemeralCiBackup ─────────────────────────────────────────────────────────
import {
  for_each = local.import
  to       = aws_s3_bucket.snapshot
  id       = var.physical_ids["snapshot_bucket_name"]
}

import {
  for_each = local.import
  to       = aws_s3_bucket_versioning.snapshot
  id       = var.physical_ids["snapshot_bucket_name"]
}

import {
  for_each = local.import
  to       = aws_s3_bucket_server_side_encryption_configuration.snapshot
  id       = var.physical_ids["snapshot_bucket_name"]
}

import {
  for_each = local.import
  to       = aws_s3_bucket_public_access_block.snapshot
  id       = var.physical_ids["snapshot_bucket_name"]
}

import {
  for_each = local.import
  to       = aws_s3_bucket_lifecycle_configuration.snapshot
  id       = var.physical_ids["snapshot_bucket_name"]
}

import {
  for_each = local.import
  to       = aws_s3_bucket_policy.snapshot
  id       = var.physical_ids["snapshot_bucket_name"]
}

import {
  for_each = local.import
  to       = aws_iam_user.backup_writer
  id       = var.physical_ids["backup_writer_user_name"]
}

import {
  for_each = local.import
  to       = aws_iam_user_policy.backup_writer
  id       = "${var.physical_ids["backup_writer_user_name"]}:WriterDefaultPolicyDC585BCE"
}

import {
  for_each = local.import
  to       = aws_secretsmanager_secret.backup_writer_key
  id       = var.physical_ids["backup_secret_arn"]
}

import {
  for_each = local.import
  to       = aws_iam_role_policy.concierge_secret_read
  id       = "spira-concierge:ConciergeRolePolicy50292239"
}
