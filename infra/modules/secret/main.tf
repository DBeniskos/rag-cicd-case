# One Secrets Manager secret, wired to the environment variable the container expects.
#
# The value is generated here rather than committed anywhere, and `ignore_changes` means a rotation
# performed out of band is not reverted by the next apply. The generated value does land in
# Terraform state, which is why state lives in an encrypted, access-controlled bucket rather than
# on a laptop.

resource "random_password" "value" {
  length  = var.value_length
  special = false # keeps the key safe to paste into a header or a curl command
}

resource "aws_secretsmanager_secret" "this" {
  name        = "${var.name_prefix}/${lower(var.secret_envvar_name)}"
  description = "${var.secret_envvar_name} for ${var.name_prefix}"

  # Prod keeps a recovery window so a mistaken destroy is reversible; non-prod deletes immediately
  # so a rebuild is not blocked by a name still held in the deletion queue.
  recovery_window_in_days = var.recovery_window_days

  tags = {
    Project     = var.project
    Environment = var.environment
    Secret      = var.secret_envvar_name
  }
}

resource "aws_secretsmanager_secret_version" "this" {
  secret_id     = aws_secretsmanager_secret.this.id
  secret_string = random_password.value.result

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# A resource policy in addition to the roles' own IAM policies. Two independent grants have to
# agree before a read succeeds, so a single over-broad role policy is not enough on its own.
data "aws_iam_policy_document" "access" {
  count = length(var.allowed_roles_arn) > 0 ? 1 : 0

  statement {
    sid       = "AllowNamedRolesOnly"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = var.allowed_roles_arn
    }
  }
}

resource "aws_secretsmanager_secret_policy" "this" {
  count = length(var.allowed_roles_arn) > 0 ? 1 : 0

  secret_arn = aws_secretsmanager_secret.this.arn
  policy     = data.aws_iam_policy_document.access[0].json
}
