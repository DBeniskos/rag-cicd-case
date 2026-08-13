data "aws_iam_policy_document" "assume_codedeploy" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["codedeploy.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "codedeploy" {
  name               = "${var.name_prefix}-codedeploy"
  description        = "Shifts traffic between task sets during a blue/green release."
  assume_role_policy = data.aws_iam_policy_document.assume_codedeploy.json
}

# AWS maintains this policy in step with the ECS blue/green feature set. Hand-writing an
# equivalent would mean tracking their changes forever for no additional restriction — it is
# already scoped to ECS, ELB and CloudWatch alarm reads.
resource "aws_iam_role_policy_attachment" "codedeploy" {
  role       = aws_iam_role.codedeploy.name
  policy_arn = "arn:aws:iam::aws:policy/AWSCodeDeployRoleForECS"
}
