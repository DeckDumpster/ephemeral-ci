# infra

The CDK app for ephemeral-ci. All new infrastructure is Terraform
(law-infrastructure-is-terraform); `TerraformBootstrap` is the last stack CDK
deploys, and it provides what Terraform needs.

## TerraformBootstrap

Deployed by the Concierge, with an MFA code, never by CI:

    npx cdk deploy TerraformBootstrap

It creates:

- an S3 state bucket (private, SSE-S3, versioned, TLS-only, `RETAIN`). Locking
  is S3-native, so there is no DynamoDB table.
- the IAM role `terraform-deploy`, assumable only by `spira-concierge` and only
  when `aws:MultiFactorAuthPresent` is true. Its policy is least privilege:
  the state bucket, `spira-*` buckets, `spira-*` IAM users/roles/policies/instance
  profiles, `spira-*` secrets, EC2/SSM in the stack's region, and CloudFormation
  reads. The role cannot modify itself (its name does not carry the prefix).
- outputs `StateBucketName`, `Region`, `DeployRoleArn`.

Resources Terraform creates must be named with the `spira-` prefix, or the role
will refuse them.

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

The MFA condition is checked on the calling session, so the Concierge's
`spira-concierge` credentials must themselves come from an MFA-authenticated
session (`aws sts get-session-token --serial-number <mfa-arn> --token-code <code>`,
or an equivalent MFA-gated login). Then Terraform's `assume_role` blocks above
work unmodified; to check by hand:

    aws sts assume-role --role-arn <DeployRoleArn> --role-session-name tf

## Tests

    npm ci && npm test
