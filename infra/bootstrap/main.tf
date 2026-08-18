# The only layer with local state, and the only one a human runs with admin credentials.
# It holds what must exist before anything else can: the bucket every other layer stores its
# state in, and the cost budget guarding the account. Run it once, then never again.
#
#   bash scripts/bootstrap.sh
#
# Terraform >= 1.11 locks state with a lockfile object in S3, so there is no DynamoDB table here.
# That is one less resource to provision, pay for and forget to delete.
#
# State stays local rather than being migrated into the bucket it creates. Self-hosting it is a
# common pattern, but it makes teardown circular, and these resources are prevent_destroy and
# never change — so a lost state file costs an import, not an outage.

data "aws_caller_identity" "current" {}

locals {
  # Bucket names are globally unique; the account id makes that deterministic rather than random,
  # so the name can be recomputed from nothing but the account rather than looked up.
  bucket_name = "${var.project}-tfstate-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket" "state" {
  bucket = local.bucket_name

  # Losing state is the one failure here with no clean recovery: the resources keep running but
  # Terraform no longer knows about them. Tearing this down is deliberate enough to warrant
  # removing this block by hand first. `make destroy ENV=dev` never touches this layer.
  lifecycle {
    prevent_destroy = true
  }
}

# Every apply writes a new version, so a corrupted or truncated state file can be rolled back to
# the previous object version instead of rebuilt.
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      # SSE-S3 rather than SSE-KMS: state contains no secrets by design, and a customer-managed
      # key would add cost and a second failure mode for no benefit at this scale.
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Versioning without expiry grows forever. Ninety days is far longer than any realistic rollback
# window and keeps the bucket effectively free.
resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-noncurrent-state-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

data "aws_iam_policy_document" "state" {
  statement {
    sid    = "DenyUnencryptedTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]

    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state.json

  depends_on = [aws_s3_bucket_public_access_block.state]
}
