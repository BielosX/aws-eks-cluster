provider "aws" {
  region = var.region
}

terraform {
  backend "s3" {}
  required_providers {
    aws = {
      version = ">= 5.51.1"
      source  = "hashicorp/aws"
    }
  }
  required_version = ">= 1.7.1"
}