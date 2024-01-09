module "efs" {
  source     = "./efs"
  subnet-ids = var.subnet-ids
  vpc-id     = var.vpc-id
}

module "iam" {
  source  = "./iam"
  oicd-id = var.oicd-id
}