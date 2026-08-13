# Two roles with different lifetimes and different blast radii:
#   execution role — used by the ECS agent to start the task (pull image, create log streams)
#   task role      — used by the application code at runtime (Bedrock, S3, SSM)
#
# Collapsing them into one would give application code permission to pull and run arbitrary
# images from the registry, which is a much larger prize for anything that achieves code execution.

data "aws_iam_policy_document" "assume_tasks" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }

    # Without this, any ECS task in any account could assume the role if its ARN leaked.
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:ecs:${var.region}:${var.account_id}:*"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.account_id]
    }
  }
}

resource "aws_iam_role" "execution" {
  name               = "${var.name_prefix}-task-execution"
  description        = "Pulls the image and writes log streams. Not available to application code."
  assume_role_policy = data.aws_iam_policy_document.assume_tasks.json
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "task" {
  name               = "${var.name_prefix}-task"
  description        = "Runtime permissions for the inference API."
  assume_role_policy = data.aws_iam_policy_document.assume_tasks.json
}

data "aws_iam_policy_document" "task" {
  # The AI-specific control. Scoping to two model ARNs means a compromised task cannot reach for a
  # frontier model at 50x the price, and a typo in a model id fails loudly instead of quietly
  # changing the bill. This is the difference between "can call Bedrock" and "can call these two
  # models".
  statement {
    sid    = "InvokeApprovedModelsOnly"
    effect = "Allow"
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
    ]
    resources = [
      "arn:aws:bedrock:${var.region}::foundation-model/${var.embed_model_id}",
      "arn:aws:bedrock:${var.region}::foundation-model/${var.text_model_id}",
    ]
  }

  # Read-only on the index: the API serves an index, it never publishes one. Publishing belongs to
  # the ingestion task, which has its own role.
  statement {
    sid       = "ReadPublishedIndexes"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${var.index_bucket_arn}/indexes/*"]
  }

  statement {
    sid       = "ListIndexPrefix"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [var.index_bucket_arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["indexes/*"]
    }
  }

  statement {
    sid       = "ReadActiveIndexPointer"
    effect    = "Allow"
    actions   = ["ssm:GetParameter"]
    resources = [var.active_index_parameter_arn]
  }
}

resource "aws_iam_role_policy" "task" {
  name   = "runtime"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task.json
}
