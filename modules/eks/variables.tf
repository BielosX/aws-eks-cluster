variable "cluster-name" {
  type = string
}

variable "subnet-ids" {
  type = list(string)
}

variable "instance-types" {
  type = list(string)
}

variable "min-size" {
  type = number
}

variable "max-size" {
  type = number
}