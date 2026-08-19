# Public subnets with no NAT gateway.
#
# A NAT gateway is ~$32/month plus data processing — more than every other resource in this
# solution combined, for a workload with no private-only dependency. Tasks therefore run in public
# subnets and reach Bedrock, S3 and ECR over the internet gateway.
#
# The trade-off is deliberate and bounded: tasks have public IPs but no inbound path except the
# load balancer security group, enforced by security-group reference rather than CIDR. Moving to
# private subnets later means adding NAT (or VPC endpoints) and flipping one variable — the module
# interface does not change. See docs/decisions.md.

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  # Two AZs: the minimum the load balancer accepts, and enough to survive one AZ failing.
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
}

resource "aws_vpc" "this" {
  cidr_block           = var.cidr_block
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.name_prefix}-vpc" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = { Name = "${var.name_prefix}-igw" }
}

resource "aws_subnet" "public" {
  for_each = { for index, az in local.azs : az => index }

  vpc_id                  = aws_vpc.this.id
  availability_zone       = each.key
  cidr_block              = cidrsubnet(var.cidr_block, 8, each.value)
  map_public_ip_on_launch = true

  tags = { Name = "${var.name_prefix}-public-${each.key}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = { Name = "${var.name_prefix}-public" }
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# ---------------------------------------------------------------------------
# Security groups
# ---------------------------------------------------------------------------

resource "aws_security_group" "alb" {
  name        = "${var.name_prefix}-alb"
  description = "Public entry point for the inference API"
  vpc_id      = aws_vpc.this.id

  tags = { Name = "${var.name_prefix}-alb" }
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  for_each = toset(var.ingress_cidrs)

  security_group_id = aws_security_group.alb.id
  description       = "HTTP from ${each.value}"
  cidr_ipv4         = each.value
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

# Without this the test listener exists but is unreachable, which defeats its only purpose:
# proving the green task set answers correctly before any production traffic reaches it.
resource "aws_vpc_security_group_ingress_rule" "alb_test" {
  for_each = var.test_listener_port == 0 ? toset([]) : toset(var.test_ingress_cidrs)

  security_group_id = aws_security_group.alb.id
  description       = "Deployment gate test listener from ${each.value}"
  cidr_ipv4         = each.value
  from_port         = var.test_listener_port
  to_port           = var.test_listener_port
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_tasks" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Forward to tasks"
  referenced_security_group_id = aws_security_group.tasks.id
  from_port                    = var.container_port
  to_port                      = var.container_port
  ip_protocol                  = "tcp"
}

resource "aws_security_group" "tasks" {
  name        = "${var.name_prefix}-tasks"
  description = "Fargate tasks: reachable only from the load balancer"
  vpc_id      = aws_vpc.this.id

  tags = { Name = "${var.name_prefix}-tasks" }
}

# Referencing the load balancer's security group rather than a CIDR is what makes the public
# subnet safe: a public IP alone grants nothing, because no other source is permitted inbound.
resource "aws_vpc_security_group_ingress_rule" "tasks_from_alb" {
  security_group_id            = aws_security_group.tasks.id
  description                  = "Container port from the load balancer only"
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = var.container_port
  to_port                      = var.container_port
  ip_protocol                  = "tcp"
}

# Egress stays open: tasks call Bedrock, S3, ECR and CloudWatch, all of which are public endpoints
# with rotating address ranges. VPC endpoints would let this be narrowed, at a cost per endpoint
# per hour that outweighs the benefit for this workload.
resource "aws_vpc_security_group_egress_rule" "tasks_outbound" {
  security_group_id = aws_security_group.tasks.id
  description       = "Outbound to AWS service endpoints"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
