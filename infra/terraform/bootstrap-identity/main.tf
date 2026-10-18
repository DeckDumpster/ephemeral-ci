# BootstrapIdentity (CDK): the one identity that exists before anything else.
#
# This is its own root, run as cdk-bootstrap-admin rather than terraform-deploy:
# the role it manages is AdministratorAccess, so letting the deploy role edit
# it would hand terraform-deploy admin. Run it from an MFA session of the
# cdk-bootstrap user's role (the shape README.md in infra/ describes), with
# credentials in the environment or AWS_PROFILE; there is no assume_role here.

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Bucket comes from the TerraformBootstrap StateBucketName output:
  #   terraform init -backend-config="bucket=<StateBucketName>"
  backend "s3" {
    key          = "ephemeral-ci/infra/bootstrap-identity/terraform.tfstate"
    region       = "us-west-2"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region              = "us-west-2"
  allowed_account_ids = ["189923011121"]
}

# The user holds the long-lived access key (created in the console, kept in
# pass) and may do one thing: assume the admin role. No access key is managed.
resource "aws_iam_user" "bootstrap" {
  name = "cdk-bootstrap"
}

resource "aws_iam_role" "bootstrap_admin" {
  name        = "cdk-bootstrap-admin"
  description = "Admin for cdk bootstrap and cdk deploy. One-hour sessions, MFA required, assumable only by the cdk-bootstrap user."

  max_session_duration = 3600

  assume_role_policy = templatefile("${path.module}/policies/bootstrap-admin-role.assume.json.tftpl", {
    bootstrap_user_arn = aws_iam_user.bootstrap.arn
  })
}

resource "aws_iam_role_policy_attachment" "bootstrap_admin" {
  role       = aws_iam_role.bootstrap_admin.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_iam_user_policy" "bootstrap" {
  name = "BootstrapUserDefaultPolicy59B531F4"
  user = aws_iam_user.bootstrap.name

  policy = templatefile("${path.module}/policies/bootstrap-user.policy.json.tftpl", {
    admin_role_arn = aws_iam_role.bootstrap_admin.arn
  })
}

import {
  for_each = local.import
  to       = aws_iam_user.bootstrap
  id       = "cdk-bootstrap"
}

import {
  for_each = local.import
  to       = aws_iam_role.bootstrap_admin
  id       = "cdk-bootstrap-admin"
}

import {
  for_each = local.import
  to       = aws_iam_role_policy_attachment.bootstrap_admin
  id       = "cdk-bootstrap-admin/arn:aws:iam::aws:policy/AdministratorAccess"
}

import {
  for_each = local.import
  to       = aws_iam_user_policy.bootstrap
  id       = "cdk-bootstrap:BootstrapUserDefaultPolicy59B531F4"
}

output "BootstrapUserName" {
  value = aws_iam_user.bootstrap.name
}

output "BootstrapRoleArn" {
  value = aws_iam_role.bootstrap_admin.arn
}

variable "import_enabled" {
  description = "Adopt the BootstrapIdentity stack's resources. Tests turn it off: a mocked provider cannot import."
  type        = bool
  default     = true
}

locals {
  import = var.import_enabled ? toset(["adopt"]) : toset([])
}
