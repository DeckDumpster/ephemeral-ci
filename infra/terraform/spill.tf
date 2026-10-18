# EphemeralCiSpill (CDK): the EC2 spill path -- VPC, launch template, SSM
# documents, the GitHub OIDC provider and the roles CI assumes through it.

locals {
  subnets = {
    a = { id_key = "subnet_a", cidr = "10.0.0.0/24", az = "us-west-2a", name = "ephemeral-ci-spill-public-a" }
    b = { id_key = "subnet_b", cidr = "10.0.1.0/24", az = "us-west-2b", name = "ephemeral-ci-spill-public-b" }
    c = { id_key = "subnet_c", cidr = "10.0.2.0/24", az = "us-west-2c", name = "ephemeral-ci-spill-public-c" }
  }
}

# ── Network: public subnets in three AZs, no NAT gateway ──────────────────────

resource "aws_vpc" "spill" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "ephemeral-ci-spill" }
}

resource "aws_subnet" "public" {
  for_each = local.subnets

  vpc_id                  = aws_vpc.spill.id
  cidr_block              = each.value.cidr
  availability_zone       = each.value.az
  map_public_ip_on_launch = true

  tags = { Name = each.value.name }
}

# Also carries the CDK IgwAttachment (the attachment is vpc_id here).
resource "aws_internet_gateway" "spill" {
  vpc_id = aws_vpc.spill.id

  tags = { Name = "ephemeral-ci-spill-igw" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.spill.id

  tags = { Name = "ephemeral-ci-spill-rt" }
}

resource "aws_route" "default" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.spill.id
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# Zero ingress, all egress: SSM needs no inbound port.
resource "aws_security_group" "spill" {
  vpc_id      = aws_vpc.spill.id
  description = "ephemeral-ci-spill runner: no inbound, all outbound"

  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
    description = "All outbound"
  }

  tags = { Name = "ephemeral-ci-spill" }
}

# ── Instance role and profile: SSM managed core only ──────────────────────────
# Token delivery uses a custom SSM document; the spill role calls SendCommand
# with RunnerToken as a plain String parameter. The instance never calls the
# SSM API itself; AmazonSSMManagedInstanceCore is all it needs.
#
# Residual: command history containing the registration token is readable by
# the spill role and by account administrators. The spill role is assumable
# from any ref of the repositories in its trust policy, so one CI run can in
# principle read another concurrent run's token. This is bounded: GitHub
# registration tokens are short-lived, the runner is --ephemeral (one token,
# one job), and every principal able to assume the role already has write
# access to the repository. IAM offers no way to scope command-history reads
# to "commands this session issued". The exposure is accepted.

resource "aws_iam_role" "instance" {
  permissions_boundary = local.permissions_boundary_arn
  name               = var.physical_ids["instance_role_name"]
  assume_role_policy = file("${path.module}/policies/instance-role.assume.json")
}

resource "aws_iam_role_policy_attachment" "instance_ssm" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "spill" {
  name = "ephemeral-ci-spill-instance"
  role = aws_iam_role.instance.name
}

# ── GitHub Actions OIDC provider ──────────────────────────────────────────────
# An account holds exactly one provider for this issuer. Every repository that
# may assume a spill role has its immutable subject prefix in the trust
# policies under policies/; re-read them from the API before changing any.

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
  ]
}

# ── Launch template: IMDSv2, gp3 root, tags propagated ────────────────────────

resource "aws_launch_template" "spill" {
  name = "ephemeral-ci-spill"

  iam_instance_profile {
    name = aws_iam_instance_profile.spill.name
  }

  # No instance_initiated_shutdown_behavior: the deployed template does not set
  # it, and adding it would make the adoption plan change a live resource.
  # provision.sh passes --instance-initiated-shutdown-behavior terminate on
  # every run-instances. Add it here in a later, separate apply.

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
    http_endpoint               = "enabled"
    instance_metadata_tags      = "enabled"
  }

  # Must match the AMI's root device (/dev/sda1, set in scripts/ami-build.sh);
  # any other name declares an additional blank volume. provision.sh overrides
  # the size per launch.
  block_device_mappings {
    device_name = "/dev/sda1"

    ebs {
      volume_size           = 32
      volume_type           = "gp3"
      delete_on_termination = "true"
      encrypted             = "true"
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      "spill:owner" = "ephemeral-ci"
      Name          = "ephemeral-ci-spill"
    }
  }

  tag_specifications {
    resource_type = "volume"
    tags = {
      "spill:owner" = "ephemeral-ci"
      Name          = "ephemeral-ci-spill"
    }
  }
}

# ── SSM documents ─────────────────────────────────────────────────────────────
# No pinned name: CloudFormation generated one, and the spill role's policy
# names the document by it.

resource "aws_ssm_document" "deliver_runner_token" {
  name            = var.physical_ids["deliver_document_name"]
  document_type   = "Command"
  document_format = "JSON"
  content         = file("${path.module}/documents/deliver-runner-token.json")
}

resource "aws_ssm_document" "diagnose_runner" {
  name            = var.physical_ids["diagnose_document_name"]
  document_type   = "Command"
  document_format = "JSON"
  content         = file("${path.module}/documents/diagnose-runner.json")
}

# The first spot request in an account needs AWSServiceRoleForEC2Spot and the
# spill role may not create it (sp-k9fhgr). An account holds at most one.
resource "aws_iam_service_linked_role" "spot" {
  aws_service_name = "spot.amazonaws.com"
  description      = "Lets EC2 Spot launch and manage spot instances for the spill runners"
}

# ── Roles assumed through OIDC ────────────────────────────────────────────────

locals {
  # terraform-deploy may write a role or user only while it carries this boundary
  # (TerraformBootstrap); the account id comes from the deploy role's own ARN.
  permissions_boundary_arn = "${regex("^arn:[^:]+:iam::[0-9]+:", var.deploy_role_arn)}policy/terraform-deploy-boundary"

  policy_vars = {
    launch_template_id     = aws_launch_template.spill.id
    deliver_document_name  = aws_ssm_document.deliver_runner_token.name
    diagnose_document_name = aws_ssm_document.diagnose_runner.name
    instance_role_arn      = aws_iam_role.instance.arn
    staging_bucket_arn     = aws_s3_bucket.round_ami_staging.arn
    oidc_provider_arn      = aws_iam_openid_connect_provider.github.arn
    subnet_a_id            = aws_subnet.public["a"].id
    subnet_b_id            = aws_subnet.public["b"].id
    subnet_c_id            = aws_subnet.public["c"].id
    security_group_id      = aws_security_group.spill.id
  }
}

resource "aws_iam_role" "spill" {
  permissions_boundary = local.permissions_boundary_arn
  name               = "ephemeral-ci-spill"
  assume_role_policy = templatefile("${path.module}/policies/spill-role.assume.json.tftpl", local.policy_vars)
}

resource "aws_iam_role_policy" "spill" {
  name   = "SpillRoleDefaultPolicyB8F8E7AD"
  role   = aws_iam_role.spill.name
  policy = templatefile("${path.module}/policies/spill-role.policy.json.tftpl", local.policy_vars)
}

# Assumed only by ami-build.yml on main; carries every spill grant plus the
# build-time operations.
resource "aws_iam_role" "ami_build" {
  permissions_boundary = local.permissions_boundary_arn
  name               = "ephemeral-ci-ami-build"
  assume_role_policy = templatefile("${path.module}/policies/ami-build-role.assume.json.tftpl", local.policy_vars)
}

resource "aws_iam_role_policy" "ami_build" {
  name   = "AmiBuildRoleDefaultPolicy4C0F4677"
  role   = aws_iam_role.ami_build.name
  policy = templatefile("${path.module}/policies/ami-build-role.policy.json.tftpl", local.policy_vars)
}

resource "aws_iam_role" "ci_test" {
  permissions_boundary = local.permissions_boundary_arn
  name               = "ephemeral-ci-ci-test"
  assume_role_policy = templatefile("${path.module}/policies/ci-test-role.assume.json.tftpl", local.policy_vars)
}

resource "aws_iam_role_policy" "ci_test" {
  name   = "CiTestRoleDefaultPolicyFE475D0D"
  role   = aws_iam_role.ci_test.name
  policy = file("${path.module}/policies/ci-test-role.policy.json")
}

# ── Round AMI staging bucket (scratch; one-day lifecycle) ─────────────────────

resource "aws_s3_bucket" "round_ami_staging" {
  bucket = var.physical_ids["staging_bucket_name"]
}

resource "aws_s3_bucket_server_side_encryption_configuration" "round_ami_staging" {
  bucket = aws_s3_bucket.round_ami_staging.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "round_ami_staging" {
  bucket                  = aws_s3_bucket.round_ami_staging.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "round_ami_staging" {
  bucket = aws_s3_bucket.round_ami_staging.id

  rule {
    id     = var.physical_ids["staging_lifecycle_rule_id"]
    status = "Enabled"

    filter {}

    expiration {
      days = 1
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

resource "aws_s3_bucket_policy" "round_ami_staging" {
  bucket = aws_s3_bucket.round_ami_staging.id
  policy = templatefile("${path.module}/policies/staging-bucket.policy.json.tftpl", local.policy_vars)
}

# ── Round-VM spill user (spira-round-spill) ───────────────────────────────────
# No access key: the operator creates it, with MFA. A managed policy, not an
# inline one: the statements exceed the 2,048-byte cap on a user's inline
# policies (sp-ifzkdi).

resource "aws_iam_user" "round_spill" {
  name                 = "spira-round-spill"
  permissions_boundary = local.permissions_boundary_arn

  # Present on the live user, keyed by the access key id; kept so the adoption
  # changes nothing.
  tags = {
    "AKIASYOCLFIYTULLVHEA" = "For spilling round certification to EC2 hosts instead of VMs"
  }
}

resource "aws_iam_policy" "round_spill" {
  name        = element(split("/", var.physical_ids["round_spill_user_policy_arn"]), 1)
  description = "spira-round-spill: launch and manage spill:owner=round instances only"
  policy      = templatefile("${path.module}/policies/round-spill.policy.json.tftpl", local.policy_vars)
}

resource "aws_iam_user_policy_attachment" "round_spill" {
  user       = aws_iam_user.round_spill.name
  policy_arn = aws_iam_policy.round_spill.arn
}

# ── Budget: $100/month, account-wide ──────────────────────────────────────────

resource "aws_budgets_budget" "monthly" {
  name         = var.physical_ids["budget_name"]
  budget_type  = "COST"
  time_unit    = "MONTHLY"
  limit_amount = "100"
  limit_unit   = "USD"

  notification {
    notification_type          = "ACTUAL"
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    subscriber_email_addresses = [var.alert_email]
  }

  notification {
    notification_type          = "FORECASTED"
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    subscriber_email_addresses = [var.alert_email]
  }
}
