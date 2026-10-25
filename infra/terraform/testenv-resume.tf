# testenv resume records (sp-d7ju06): the S3 store behind TESTENV_RESUME=s3://<bucket>/resume.
# A dedicated private bucket, named spira-* because terraform-deploy may create
# buckets only under its name prefixes (ephemeral-ci-* is not one of them). Objects under
# resume/ expire after seven days; the spill instance role may put, get and list
# there and nothing else.

data "aws_caller_identity" "current" {}

locals {
  testenv_resume_bucket = "spira-testenv-resume-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket" "testenv_resume" {
  bucket = local.testenv_resume_bucket
}

resource "aws_s3_bucket_server_side_encryption_configuration" "testenv_resume" {
  bucket = aws_s3_bucket.testenv_resume.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "testenv_resume" {
  bucket                  = aws_s3_bucket.testenv_resume.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "testenv_resume" {
  bucket = aws_s3_bucket.testenv_resume.id

  rule {
    id     = "expire-resume-records"
    status = "Enabled"

    filter {
      prefix = "resume/"
    }

    expiration {
      days = 7
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

resource "aws_s3_bucket_policy" "testenv_resume" {
  bucket = aws_s3_bucket.testenv_resume.id
  policy = templatefile("${path.module}/policies/testenv-resume-bucket.policy.json.tftpl", {
    bucket_arn = aws_s3_bucket.testenv_resume.arn
  })
}

# The spill instance role (the one the instance profile carries), not the
# ephemeral-ci-spill launcher role.
resource "aws_iam_role_policy" "instance_testenv_resume" {
  name = "TestenvResumeRecords"
  role = aws_iam_role.instance.name
  policy = templatefile("${path.module}/policies/instance-testenv-resume.policy.json.tftpl", {
    bucket_arn = aws_s3_bucket.testenv_resume.arn
  })
}
