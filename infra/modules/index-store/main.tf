# The vector index as a release artifact.
#
# Three things live here and they are deliberately separate:
#   raw/            source corpus, never expired — indexes are rebuildable, source data is not
#   indexes/vN-sha/ immutable index versions, retained for rollback then expired
#   SSM parameter   which version is live right now
#
# Promotion is a write to the SSM parameter. Rollback is the same write with the previous value,
# which is why recovering from a bad index takes seconds and needs no rebuild.

resource "aws_s3_bucket" "index" {
  bucket = "${var.name_prefix}-index-${var.account_id}"

  # Environments are torn down and rebuilt during this exercise; the corpus is re-uploadable and
  # indexes are regenerable, so an occupied bucket should not block destroy.
  force_destroy = var.force_destroy
}

resource "aws_s3_bucket_versioning" "index" {
  bucket = aws_s3_bucket.index.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "index" {
  bucket = aws_s3_bucket.index.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "index" {
  bucket = aws_s3_bucket.index.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_iam_policy_document" "index" {
  statement {
    sid    = "DenyUnencryptedTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["s3:*"]
    resources = [aws_s3_bucket.index.arn, "${aws_s3_bucket.index.arn}/*"]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "index" {
  bucket = aws_s3_bucket.index.id
  policy = data.aws_iam_policy_document.index.json

  depends_on = [aws_s3_bucket_public_access_block.index]
}

# Old index versions are the rollback window. Keeping them forever would grow without bound;
# expiring them too eagerly would remove the ability to roll back. The retention period is the
# knob that trades storage cost against how far back a rollback can reach.
resource "aws_s3_bucket_lifecycle_configuration" "index" {
  bucket = aws_s3_bucket.index.id

  rule {
    id     = "expire-superseded-index-versions"
    status = "Enabled"

    filter {
      prefix = "indexes/"
    }

    expiration {
      days = var.index_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 7
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  # The corpus is the input everything else derives from, so it is explicitly never expired.
  rule {
    id     = "retain-source-corpus"
    status = "Enabled"

    filter {
      prefix = "raw/"
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# The live pointer. Plain SSM Parameter Store rather than Secrets Manager: an index version is
# configuration, not a secret, and conflating the two costs $0.40/month per value while teaching
# the team the wrong habit.
resource "aws_ssm_parameter" "active_index_version" {
  name        = "/rag/${var.environment}/active_index_version"
  description = "Index version currently served by ${var.name_prefix}. Flip to promote or roll back."
  type        = "String"
  value       = var.initial_index_version
  tier        = "Standard"

  # Terraform provisions the parameter; the promotion pipeline owns its value from then on.
  # Without this, every apply would silently roll the index back to the bootstrap value.
  lifecycle {
    ignore_changes = [value]
  }
}
