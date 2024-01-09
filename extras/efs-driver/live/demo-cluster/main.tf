provider "aws" {
  region = "eu-west-1"
}

terraform {
  backend "s3" {}
  required_providers {
    aws = {
      version = ">= 5.28.0"
      source  = "hashicorp/aws"
    }
  }
  required_version = ">= 1.6.0"
}

module "efs-driver" {
  source     = "../../modules"
  oicd-id    = var.oicd-id
  subnet-ids = var.subnet-ids
  vpc-id     = var.vpc-id
}