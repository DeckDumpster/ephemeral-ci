# GitHubMainProtection: main's branch protection, declared (law-infrastructure-is-terraform).
#
# Its own root, with its own state and a GitHub token rather than AWS
# credentials. The protection already exists on the repository, so it is
# imported (import.tf), never recreated. This root adds one thing to what main
# requires today: the "infra" job, which sp-vxpvt4 (PR 198) showed can merge red
# when it is not required.

terraform {
  required_version = ">= 1.10"

  required_providers {
    github = {
      source  = "integrations/github"
      version = "~> 6.0"
    }
  }

  # Bucket comes from the TerraformBootstrap StateBucketName output:
  #   terraform init -backend-config="bucket=<StateBucketName>"
  backend "s3" {
    key          = "ephemeral-ci/infra/github/terraform.tfstate"
    region       = "us-west-2"
    encrypt      = true
    use_lockfile = true
  }
}

# Token from GITHUB_TOKEN in the environment; it needs repository
# administration on DeckDumpster/ephemeral-ci.
provider "github" {
  owner = "DeckDumpster"
}

variable "existing_required_checks" {
  type        = set(string)
  description = "Status check contexts main requires today, read with gh api (README). No default: a guessed list would drop a check."

  validation {
    condition     = length(var.existing_required_checks) > 0
    error_message = "existing_required_checks must list what main requires today; an empty list would be read as dropping them."
  }
}

variable "enforce_admins" {
  type        = bool
  description = "enforce_admins as main has it today."
}

variable "strict_status_checks" {
  type        = bool
  description = "required_status_checks.strict as main has it today."
}

variable "required_approving_review_count" {
  type        = number
  description = "Approving reviews main requires today; null when it requires no pull request review."
  default     = null
}

variable "import_enabled" {
  type        = bool
  default     = true
  description = "Import main's existing protection. Off only in the offline test, where the mocked provider has nothing to import."
}

locals {
  required_checks = setunion(var.existing_required_checks, ["infra"])
}

resource "github_branch_protection" "main" {
  repository_id  = "ephemeral-ci"
  pattern        = "main"
  enforce_admins = var.enforce_admins

  required_status_checks {
    strict   = var.strict_status_checks
    contexts = sort(tolist(local.required_checks))
  }

  dynamic "required_pull_request_reviews" {
    for_each = var.required_approving_review_count == null ? [] : [1]
    content {
      required_approving_review_count = var.required_approving_review_count
    }
  }
}
