variable "cidr-block" {
  type    = string
  default = "10.0.0.0/16"
}

variable "name" {
  type = string
}

variable "availability-zones" {
  type = list(string)
}

variable "single-nat-gateway" {
  type    = bool
  default = true
}

variable "subnet-size" {
  type    = number
  default = 256
}