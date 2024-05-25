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