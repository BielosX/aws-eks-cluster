region             = "eu-west-1"
name               = "demo"
single_nat_gateway = true
cidr_block         = "10.0.0.0/16"
subnet_size        = 256
availability_zones = ["eu-west-1a", "eu-west-1b"]
private_endpoint   = false
node_group_max     = 2
node_group_min     = 2
instance_types     = ["t3.medium"]
kubernetes_version = "1.30"