# One registry, one repository per independently releasable component.
#
# Tags are immutable: a deployed tag can never be repointed at different bytes, so "which code is
# in prod?" has exactly one answer. The pipeline still applies moving dev/prod alias tags for
# humans, which is why deploys resolve and pin the digest rather than trusting the tag.

resource "aws_ecr_repository" "component" {
  for_each = toset(var.components)

  name                 = "${var.project}-${each.key}"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true # teardown is part of the deliverable; images are rebuildable

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

# Untagged layers are orphans from overwritten manifests and serve no purpose. Tagged images are
# capped so the registry cannot grow without bound, while keeping enough history to roll back far.
resource "aws_ecr_lifecycle_policy" "component" {
  for_each = aws_ecr_repository.component

  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 1 day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep the most recent ${var.image_retention_count} release images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["v"]
          countType     = "imageCountMoreThan"
          countNumber   = var.image_retention_count
        }
        action = { type = "expire" }
      },
    ]
  })
}
