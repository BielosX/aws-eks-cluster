locals {
  subnet_ids = aws_subnet.private_subnet[*].id
}

resource "aws_eks_cluster" "cluster" {
  name     = var.name
  role_arn = aws_iam_role.cluster_role.arn
  version  = var.kubernetes_version
  vpc_config {
    subnet_ids              = local.subnet_ids
    endpoint_private_access = var.private_endpoint
    endpoint_public_access  = !var.private_endpoint
  }
}

data "tls_certificate" "certificate" {
  url = aws_eks_cluster.cluster.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "connect_provider" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.certificate.certificates[0].sha1_fingerprint]
  url             = data.tls_certificate.certificate.url
}

resource "aws_launch_template" "launch_template" {
  // https://aws.github.io/aws-eks-best-practices/security/docs/iam/#restrict-access-to-the-instance-profile-assigned-to-the-worker-node
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }
}

resource "aws_eks_node_group" "node_group" {
  node_group_name = "${var.name}-node-group"
  cluster_name    = aws_eks_cluster.cluster.name
  node_role_arn   = aws_iam_role.node_role.arn
  subnet_ids      = local.subnet_ids
  instance_types  = var.instance_types
  launch_template {
    id      = aws_launch_template.launch_template.id
    version = aws_launch_template.launch_template.latest_version
  }

  scaling_config {
    desired_size = var.node_group_max
    max_size     = var.node_group_max
    min_size     = var.node_group_min
  }

  update_config {
    max_unavailable = 1
  }

  labels = {
    nodeType : "aws-managed"
  }

  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }
}