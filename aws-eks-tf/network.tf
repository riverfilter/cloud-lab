data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.availability_zone_count)

  # Carve the VPC /16 into equal /20 pairs: one public + one private per AZ.
  # With a default /16 + 2 AZs this yields:
  #   public[0]   10.30.0.0/20    private[0]  10.30.32.0/20
  #   public[1]   10.30.16.0/20   private[1]  10.30.48.0/20
  # /20 = 4091 usable IPs per subnet, which is overkill for a lab but leaves
  # headroom for the VPC CNI's per-ENI secondary IP allocation (up to ~29 per
  # t3.small ENI, 3 ENIs max = ~87 pod IPs per node before prefix-delegation).
  public_subnet_cidrs  = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 4, i)]
  private_subnet_cidrs = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 4, i + 2)]
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.cluster_name}-vpc"
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.cluster_name}-igw"
  }
}

resource "aws_subnet" "public" {
  count = length(local.azs)

  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.public_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = false # NAT EIPs + ALB ENIs attach their own public IPs; we don't want auto-assign on anything else that lands here.

  tags = {
    Name = "${var.cluster_name}-public-${local.azs[count.index]}"
    # Tag required by the AWS Load Balancer Controller to discover subnets
    # where public-facing ALBs/NLBs may be placed. Harmless if the controller
    # is never installed.
    "kubernetes.io/role/elb" = "1"
  }
}

resource "aws_subnet" "private" {
  count = length(local.azs)

  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.private_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.cluster_name}-private-${local.azs[count.index]}"
    # Tag required by the AWS Load Balancer Controller for internal LBs.
    "kubernetes.io/role/internal-elb" = "1"
  }
}

# One EIP per NAT gateway. Single NAT by default (cost); per-AZ NAT when
# single_nat_gateway = false. NAT is the dominant variable cost on AWS —
# ~$32/mo per gateway + $0.045/GB processed. GCP Cloud NAT's pricing model is
# vastly more forgiving; that's the single biggest cost delta between this
# stack and the GKE sibling.
resource "aws_eip" "nat" {
  count = var.single_nat_gateway ? 1 : length(local.azs)

  domain = "vpc"

  tags = {
    Name = "${var.cluster_name}-nat-eip-${count.index}"
  }

  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  count = var.single_nat_gateway ? 1 : length(local.azs)

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = {
    Name = "${var.cluster_name}-nat-${count.index}"
  }

  depends_on = [aws_internet_gateway.this]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = {
    Name = "${var.cluster_name}-public"
  }
}

resource "aws_route_table_association" "public" {
  count = length(aws_subnet.public)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# One private route table per AZ so that, if single_nat_gateway is flipped
# off later, each AZ's private subnet can point at its own local NAT without
# a route-table refactor.
resource "aws_route_table" "private" {
  count = length(local.azs)

  vpc_id = aws_vpc.this.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = var.single_nat_gateway ? aws_nat_gateway.this[0].id : aws_nat_gateway.this[count.index].id
  }

  tags = {
    Name = "${var.cluster_name}-private-${local.azs[count.index]}"
  }
}

resource "aws_route_table_association" "private" {
  count = length(local.azs)

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# VPC flow logs — off by default. When on, log REJECTs only into a
# short-retention CloudWatch group. REJECTs are the high-signal subset:
# probing, blocked egress, attempted lateral movement. Logging ALL traffic
# at this scale isn't expensive, but REJECTs-only is closer to the GKE
# stack's flow-log-sampling-at-0.1 cost posture.
resource "aws_cloudwatch_log_group" "flow_logs" {
  count = var.enable_vpc_flow_logs ? 1 : 0

  name              = "/aws/vpc/flow-logs/${var.cluster_name}"
  retention_in_days = var.flow_logs_retention_days
}

resource "aws_iam_role" "flow_logs" {
  count = var.enable_vpc_flow_logs ? 1 : 0

  name = "${var.cluster_name}-flow-logs"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "flow_logs" {
  count = var.enable_vpc_flow_logs ? 1 : 0

  name = "${var.cluster_name}-flow-logs"
  role = aws_iam_role.flow_logs[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams",
      ]
      Resource = "${aws_cloudwatch_log_group.flow_logs[0].arn}:*"
    }]
  })
}

resource "aws_flow_log" "this" {
  count = var.enable_vpc_flow_logs ? 1 : 0

  vpc_id          = aws_vpc.this.id
  traffic_type    = "REJECT"
  log_destination = aws_cloudwatch_log_group.flow_logs[0].arn
  iam_role_arn    = aws_iam_role.flow_logs[0].arn
}
