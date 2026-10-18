variables {
  import_enabled = false
}

mock_provider "aws" {
  mock_resource "aws_iam_user" {
    defaults = { arn = "arn:aws:iam::189923011121:user/cdk-bootstrap" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::189923011121:role/cdk-bootstrap-admin" }
  }
}

run "admin_role_requires_mfa_and_one_hour" {
  command = apply

  assert {
    condition     = aws_iam_role.bootstrap_admin.max_session_duration == 3600
    error_message = "the bootstrap admin session is one hour"
  }

  assert {
    condition     = strcontains(aws_iam_role.bootstrap_admin.assume_role_policy, "aws:MultiFactorAuthPresent")
    error_message = "the bootstrap admin role must require MFA"
  }
}

run "user_can_only_assume_the_role" {
  command = apply

  assert {
    condition     = strcontains(aws_iam_user_policy.bootstrap.policy, "sts:AssumeRole") && !strcontains(aws_iam_user_policy.bootstrap.policy, "\"*\"")
    error_message = "the bootstrap user's whole permission set is sts:AssumeRole on the admin role"
  }
}
