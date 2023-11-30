module "vpc" {
  source             = "./vpc"
  availability-zones = var.availability-zones
  name               = "${var.cluster-name}-vpc"
}

module "eks" {
  source         = "./eks"
  cluster-name   = var.cluster-name
  instance-types = var.instance-types
  max-size       = var.max-size
  min-size       = var.min-size
  subnet-ids     = module.vpc.private-subnet-ids
}