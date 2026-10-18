variable "deploy_role_arn" {
  description = "DeployRoleArn output of the TerraformBootstrap stack (terraform-deploy)."
  type        = string
}

variable "alert_email" {
  description = "Recipient of the monthly budget notifications."
  type        = string
  default     = "me@ryangantt.com"
}

variable "physical_ids" {
  description = <<-E
    Physical ids of the resources CloudFormation named or numbered for itself.
    scripts/discover-ids.sh reads them from the three CDK stacks and writes
    physical_ids.auto.tfvars.json; they are used by the import blocks and, for
    the generated names, by the resources themselves.
  E
  type        = map(string)

  validation {
    condition = alltrue([
      for k in [
        "vpc", "subnet_a", "subnet_b", "subnet_c", "igw", "route_table", "security_group",
        "launch_template", "instance_role_name", "deliver_document_name", "diagnose_document_name",
        "staging_bucket_name", "staging_lifecycle_rule_id", "round_spill_user_policy_arn",
        "budget_name", "snapshot_bucket_name", "snapshot_lifecycle_rule_id",
        "backup_writer_user_name", "backup_secret_arn", "backup_secret_name",
      ] : contains(keys(var.physical_ids), k)
    ])
    error_message = "physical_ids is missing a key; rerun scripts/discover-ids.sh."
  }
}

variable "import_enabled" {
  description = "Adopt the CDK stacks' resources (imports.tf). Tests turn it off: a mocked provider cannot import."
  type        = bool
  default     = true
}

locals {
  import = var.import_enabled ? toset(["adopt"]) : toset([])
}
