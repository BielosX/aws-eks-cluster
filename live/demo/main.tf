terraform {
  required_providers {
    aws = {
      version = ">= 5.28.0"
      source  = "hashicorp/aws"
    }
  }
  required_version = ">= 1.6.0"
}

data "aws_availability_zones" "available" {
  state = "available"
}

module "cluster" {
  source             = "../../modules"
  availability-zones = slice(data.aws_availability_zones.available.names, 0, 2)
  cluster-name       = "demo-cluster"
}