# The ids the spill scripts read (provision.sh, ami-build.sh, ec2-diag.sh,
# check-spill-permissions.sh, test-reap.sh), as SSM parameters under
# /ephemeral-ci/spill/ -- one `aws ssm get-parameters-by-path` instead of
# `cloudformation describe-stacks` on the EphemeralCiSpill stack. Names are the
# former stack output names (scripts/spill-params.sh).

locals {
  spill_param_path = "/ephemeral-ci/spill"

  spill_params = {
    SubnetIds            = join(",", [for k in ["a", "b", "c"] : aws_subnet.public[k].id])
    SecurityGroupId      = aws_security_group.spill.id
    LaunchTemplateId     = aws_launch_template.spill.id
    LaunchTemplateName   = aws_launch_template.spill.name
    InstanceProfileName  = aws_iam_instance_profile.spill.name
    DeliverDocumentName  = aws_ssm_document.deliver_runner_token.name
    DiagnoseDocumentName = aws_ssm_document.diagnose_runner.name
  }
}

resource "aws_ssm_parameter" "spill" {
  for_each = local.spill_params

  name  = "${local.spill_param_path}/${each.key}"
  type  = "String"
  value = each.value
}
