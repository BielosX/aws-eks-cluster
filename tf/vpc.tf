resource "aws_vpc" "vpc" {
  cidr_block           = var.cidr_block
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags = {
    Name : var.name
  }
}

locals {
  number_azs   = length(var.availability_zones)
  nat_gateways = var.single_nat_gateway ? 1 : local.number_azs
}

resource "aws_subnet" "public_subnet" {
  count                   = local.number_azs
  vpc_id                  = aws_vpc.vpc.id
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true
  cidr_block              = cidrsubnet(var.cidr_block, ceil(log(var.subnet_size, 2)), count.index + 1)
  tags = {
    Name : "${var.name}-public-subnet",
    "kubernetes.io/role/elb" : 1
  }
}

resource "aws_internet_gateway" "internet_gateway" {
  vpc_id = aws_vpc.vpc.id
  tags = {
    Name : "${var.name}-internet-gateway"
  }
}

resource "aws_route_table" "public-route-table" {
  vpc_id = aws_vpc.vpc.id

  route {
    gateway_id = aws_internet_gateway.internet_gateway.id
    cidr_block = "0.0.0.0/0"
  }

  tags = {
    Name : "${var.name}-public-route-table"
  }
}

resource "aws_route_table_association" "public_route_table_association" {
  count          = local.number_azs
  route_table_id = aws_route_table.public-route-table.id
  subnet_id      = aws_subnet.public_subnet[count.index].id
}

resource "aws_subnet" "private_subnet" {
  count                   = local.number_azs
  vpc_id                  = aws_vpc.vpc.id
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = false
  cidr_block              = cidrsubnet(var.cidr_block, ceil(log(var.subnet_size, 2)), local.number_azs + count.index + 1)
  tags = {
    Name : "${var.name}-private-subnet",
    "kubernetes.io/role/internal-elb" : 1
  }
}

resource "aws_eip" "eip" {
  count  = local.nat_gateways
  domain = "vpc"
  tags = {
    Name : "${var.name}-nat-gateway-eip"
  }
}

resource "aws_nat_gateway" "nat_gateway" {
  count         = local.nat_gateways
  subnet_id     = aws_subnet.public_subnet[count.index].id
  allocation_id = aws_eip.eip[count.index].id
  tags = {
    Name : "${var.name}-nat-gateway"
  }
}

resource "aws_route_table" "private_route_table" {
  vpc_id = aws_vpc.vpc.id

  dynamic "route" {
    for_each = range(local.nat_gateways)
    content {
      nat_gateway_id = aws_nat_gateway.nat_gateway[route.key].id
      cidr_block     = "0.0.0.0/0"
    }
  }

  tags = {
    Name : "${var.name}-private-route-table"
  }
}

resource "aws_route_table_association" "private_route_table_association" {
  count          = local.number_azs
  route_table_id = aws_route_table.private_route_table.id
  subnet_id      = aws_subnet.private_subnet[count.index].id
}