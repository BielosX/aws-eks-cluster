variable "region" {
  type = string
}

variable "name" {
  type = string
}

variable "cidr_block" {
  type = string
}

variable "single_nat_gateway" {
  type = bool
}

variable "availability_zones" {
  type = list(string)
}

variable "subnet_size" {
  type = number
}

variable "private_endpoint" {
  type = bool
}

variable "node_group_max" {
  type = number
}

variable "node_group_min" {
  type = number
}

variable "instance_types" {
  type = list(string)
}

variable "kubernetes_version" {
  type = string
}