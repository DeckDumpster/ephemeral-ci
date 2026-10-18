# EphemeralCiBackup (CDK): off-box snapshot bucket and its put-only writer key
# (law-off-box-backups-are-private-and-write-only).

resource "aws_s3_bucket" "snapshot" {
  bucket = var.physical_ids["snapshot_bucket_name"]
}

resource "aws_s3_bucket_versioning" "snapshot" {
  bucket = aws_s3_bucket.snapshot.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "snapshot" {
  bucket = aws_s3_bucket.snapshot.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "snapshot" {
  bucket                  = aws_s3_bucket.snapshot.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "snapshot" {
  bucket = aws_s3_bucket.snapshot.id

  rule {
    id     = var.physical_ids["snapshot_lifecycle_rule_id"]
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }

  depends_on = [aws_s3_bucket_versioning.snapshot]
}

resource "aws_s3_bucket_policy" "snapshot" {
  bucket = aws_s3_bucket.snapshot.id
  policy = templatefile("${path.module}/policies/snapshot-bucket.policy.json.tftpl", {
    snapshot_bucket_arn = aws_s3_bucket.snapshot.arn
  })
}

resource "aws_iam_user" "backup_writer" {
  name = var.physical_ids["backup_writer_user_name"]
}

resource "aws_iam_user_policy" "backup_writer" {
  name = "WriterDefaultPolicyDC585BCE"
  user = aws_iam_user.backup_writer.name
  policy = templatefile("${path.module}/policies/backup-writer.policy.json.tftpl", {
    snapshot_bucket_arn = aws_s3_bucket.snapshot.arn
  })
}

# The writer's access key (WriterKey) is deliberately not managed: Terraform
# cannot import an access key, and its secret exists only inside the secret
# below. The key stays as it is, retained when the stack is deleted.
#
# The secret's value (the key pair and bucket name) is not managed either, so
# Terraform never holds the secret access key.
resource "aws_secretsmanager_secret" "backup_writer_key" {
  description = "Put-only access key for the Spira snapshot bucket (lc-backup.env)"
  name        = var.physical_ids["backup_secret_name"]

  # Provider-side deletion/replication settings with no API read-back: an
  # imported secret always shows them as additions, which would make the
  # adoption plan non-zero.
  lifecycle {
    ignore_changes = [recovery_window_in_days, force_overwrite_replica_secret]
  }
}

# spira-concierge is the existing role the Concierge runs as.
resource "aws_iam_role_policy" "concierge_secret_read" {
  name = "ConciergeRolePolicy50292239"
  role = "spira-concierge"
  policy = templatefile("${path.module}/policies/concierge-secret-read.policy.json.tftpl", {
    writer_secret_arn = aws_secretsmanager_secret.backup_writer_key.arn
  })
}
