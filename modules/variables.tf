variable "cluster-name" {
  type = string
}

variable "availability-zones" {
  type = list(string)
}

variable "instance-types" {
  type    = list(string)
  default = ["t3.medium"]
}

variable "max-size" {
  type    = number
  default = 2
}

variable "min-size" {
  type    = number
  default = 2
}