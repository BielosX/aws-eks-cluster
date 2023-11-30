resource "aws_vpc" "vpc" {
  cidr_block           = var.cidr-block
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags = {
    Name : var.name
  }
}

locals {
  number-azs   = length(var.availability-zones)
  nat-gateways = var.single-nat-gateway ? 1 : local.number-azs
}

resource "aws_subnet" "public-subnet" {
  count                   = local.number-azs
  vpc_id                  = aws_vpc.vpc.id
  availability_zone       = var.availability-zones[count.index]
  map_public_ip_on_launch = true
  cidr_block              = cidrsubnet(var.cidr-block, ceil(log(var.subnet-size, 2)), count.index + 1)
  tags = {
    Name : "${var.name}-public-subnet",
    "kubernetes.io/role/elb" : 1
  }
}

resource "aws_internet_gateway" "internet-gateway" {
  vpc_id = aws_vpc.vpc.id
  tags = {
    Name : "${var.name}-internet-gateway"
  }
}

resource "aws_route_table" "public-route-table" {
  vpc_id = aws_vpc.vpc.id

  route {
    gateway_id = aws_internet_gateway.internet-gateway.id
    cidr_block = "0.0.0.0/0"
  }

  tags = {
    Name : "${var.name}-public-route-table"
  }
}

resource "aws_route_table_association" "public-route-table-association" {
  count          = local.number-azs
  route_table_id = aws_route_table.public-route-table.id
  subnet_id      = aws_subnet.public-subnet[count.index].id
}

resource "aws_subnet" "private-subnet" {
  count                   = local.number-azs
  vpc_id                  = aws_vpc.vpc.id
  availability_zone       = var.availability-zones[count.index]
  map_public_ip_on_launch = false
  cidr_block              = cidrsubnet(var.cidr-block, ceil(log(var.subnet-size, 2)), local.number-azs + count.index + 1)
  tags = {
    Name : "${var.name}-private-subnet",
    "kubernetes.io/role/internal-elb" : 1
  }
}

resource "aws_eip" "eip" {
  count  = local.nat-gateways
  domain = "vpc"
  tags = {
    Name : "${var.name}-nat-gateway-eip"
  }
}

resource "aws_nat_gateway" "nat-gateway" {
  count         = local.nat-gateways
  subnet_id     = aws_subnet.public-subnet[count.index].id
  allocation_id = aws_eip.eip[count.index].id
  tags = {
    Name : "${var.name}-nat-gateway"
  }
}

resource "aws_route_table" "private-route-table" {
  vpc_id = aws_vpc.vpc.id

  dynamic "route" {
    for_each = range(local.nat-gateways)
    content {
      nat_gateway_id = aws_nat_gateway.nat-gateway[route.key].id
      cidr_block     = "0.0.0.0/0"
    }
  }

  tags = {
    Name : "${var.name}-private-route-table"
  }
}

resource "aws_route_table_association" "private-route-table-association" {
  count          = local.number-azs
  route_table_id = aws_route_table.private-route-table.id
  subnet_id      = aws_subnet.private-subnet[count.index].id
}