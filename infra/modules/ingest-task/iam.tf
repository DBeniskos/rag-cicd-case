data "aws_iam_policy_document" "assume_tasks" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.account_id]
    }
  }
}

resource "aws_iam_role" "ingest" {
  name               = "${var.name_prefix}-ingest-task"
  description        = "Builds and publishes index versions. The only identity that may write them."
  assume_role_policy = data.aws_iam_policy_document.assume_tasks.json
}

data "aws_iam_policy_document" "ingest" {
  statement {
    sid    = "EmbedWithApprovedModelOnly"
    effect = "Allow"
    # Only the embedding model. The ingestion job has no reason to reach a text generation model,
    # and scoping it here means a bug in the job cannot start spending on one.
    actions   = ["bedrock:InvokeModel"]
    resources = ["arn:aws:bedrock:${var.region}::foundation-model/${var.embed_model_id}"]
  }

  statement {
    sid       = "ReadCorpus"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${var.index_bucket_arn}/raw/*"]
  }

  # Write is confined to the indexes prefix, so a bug in the job cannot overwrite the source
  # corpus it derives from. Existing versions are still writable in principle; immutability is
  # enforced by never reusing a version number rather than by IAM.
  statement {
    sid       = "PublishIndexVersions"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${var.index_bucket_arn}/indexes/*"]
  }

  statement {
    sid       = "ListBucketToAllocateNextVersion"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [var.index_bucket_arn]
  }
}

resource "aws_iam_role_policy" "ingest" {
  name   = "runtime"
  role   = aws_iam_role.ingest.id
  policy = data.aws_iam_policy_document.ingest.json
}
