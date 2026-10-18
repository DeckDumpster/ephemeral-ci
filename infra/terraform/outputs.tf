# The CDK stacks' outputs, under the same names, for the scripts that read
# them today with `aws cloudformation describe-stacks`.

output "SubnetIds" {
  value = join(",", [for k in ["a", "b", "c"] : aws_subnet.public[k].id])
}

output "SecurityGroupId" {
  value = aws_security_group.spill.id
}

output "LaunchTemplateId" {
  value = aws_launch_template.spill.id
}

output "LaunchTemplateName" {
  value = aws_launch_template.spill.name
}

output "InstanceProfileName" {
  value = aws_iam_instance_profile.spill.name
}

output "DeliverDocumentName" {
  value = aws_ssm_document.deliver_runner_token.name
}

output "DiagnoseDocumentName" {
  value = aws_ssm_document.diagnose_runner.name
}

output "AmiBuildRoleArn" {
  value = aws_iam_role.ami_build.arn
}

output "RoundAmiStagingBucket" {
  value = aws_s3_bucket.round_ami_staging.bucket
}

output "RoundAmiBaseParam" {
  value = "/aws/service/canonical/ubuntu/server/26.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

output "RoundSpillUserName" {
  value = aws_iam_user.round_spill.name
}

output "RoundSpillInstanceProfileName" {
  value = aws_iam_instance_profile.spill.name
}

output "BucketName" {
  value = aws_s3_bucket.snapshot.bucket
}

output "WriterSecretArn" {
  value = aws_secretsmanager_secret.backup_writer_key.arn
}
