# infra

All infrastructure is Terraform (law-infrastructure-is-terraform) and lives in
`terraform/`; see `terraform/README.md` for the roots, the migration runbook
and the CDK-logical-id to Terraform-address map. This directory's CDK app now
holds one stack, `TerraformBootstrap`, which provides what Terraform needs.

## TerraformBootstrap

Deployed by the Concierge, with an MFA code, never by CI:

    npx cdk deploy TerraformBootstrap

It creates:

- an S3 state bucket (private, SSE-S3, versioned, TLS-only, `RETAIN`). Locking
  is S3-native, so there is no DynamoDB table.
- the IAM role `terraform-deploy`, assumable only by `spira-concierge` sessions
  (MFA is not carried across role chaining, so it is enforced by
  `spira-concierge`'s own trust, not here). IAM writes on users/roles require the
  `terraform-deploy-boundary` permissions boundary (no IAM writes inside it), and
  all IAM writes on `spira-concierge`, `terraform-deploy` and the boundary are
  denied. Its policy is least privilege:
  the state bucket, `<prefix>-*` buckets, `<prefix>-*` IAM users/roles/policies/instance
  profiles, `<prefix>/*` secrets for each prefix in `TERRAFORM_NAME_PREFIXES`
  (`spira`, `cubby`), the names the retired ephemeral-ci stacks gave their
  resources (`ephemeral-ci-*`, `EphemeralCiSpill-*`, `EphemeralCiBackup-*`, the
  GitHub OIDC provider, the Spot service-linked role, the budget), EC2/SSM in
  the stack's region, and CloudFormation reads. The role cannot modify itself
  (its name does not carry a prefix).
- outputs `StateBucketName`, `Region`, `DeployRoleArn`.

Resources Terraform creates must carry one of those prefixes, or the role will
refuse them. Moving another repository to Terraform is one edit to
`TERRAFORM_NAME_PREFIXES` in `lib/terraform-bootstrap-stack.ts`, then a redeploy
of `TerraformBootstrap`.

### Pointing a Terraform root at it

Requires Terraform >= 1.10.

```hcl
terraform {
  required_version = ">= 1.10"

  backend "s3" {
    bucket       = "<StateBucketName output>"
    key          = "<repo>/<root>/terraform.tfstate"   # unique per root
    region       = "us-west-2"
    encrypt      = true
    use_lockfile = true
    assume_role = {
      role_arn = "<DeployRoleArn output>"
    }
  }
}

provider "aws" {
  region = "us-west-2"
  assume_role {
    role_arn = "<DeployRoleArn output>"
  }
}
```

### Assuming the role

`spira-concierge`'s own trust checks MFA, so the Concierge's
`spira-concierge` credentials must themselves come from an MFA-authenticated
session (`aws sts get-session-token --serial-number <mfa-arn> --token-code <code>`,
or an equivalent MFA-gated login). Then Terraform's `assume_role` blocks above
work unmodified; to check by hand:

    aws sts assume-role --role-arn <DeployRoleArn> --role-session-name tf

## Tests

    npm ci && npm test
