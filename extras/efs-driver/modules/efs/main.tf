resource "aws_efs_file_system" "efs" {
  performance_mode = "generalPurpose"
  throughput_mode  = "elastic"
}

data "aws_vpc" "vpc" {
  id = var.vpc-id
}

resource "aws_security_group" "security-group" {
  vpc_id = var.vpc-id
  ingress {
    cidr_blocks = [data.aws_vpc.vpc.cidr_block]
    protocol    = "tcp"
    from_port   = 2049
    to_port     = 2049
  }
}

resource "aws_efs_mount_target" "mount-target" {
  for_each        = toset(var.subnet-ids)
  file_system_id  = aws_efs_file_system.efs.id
  subnet_id       = each.key
  security_groups = [aws_security_group.security-group.id]
}