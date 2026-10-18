terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Bucket and role come from the TerraformBootstrap stack outputs
  # (scripts/discover-ids.sh writes backend.hcl):
  #   terraform init -backend-config=backend.hcl
  backend "s3" {
    key          = "ephemeral-ci/infra/terraform.tfstate"
    region       = "us-west-2"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region              = "us-west-2"
  allowed_account_ids = ["189923011121"]

  assume_role {
    role_arn = var.deploy_role_arn
  }
}
