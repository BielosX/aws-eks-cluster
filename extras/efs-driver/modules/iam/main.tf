data "aws_caller_identity" "current" {}

locals {
  account-id = data.aws_caller_identity.current.account_id
}

data "aws_iam_policy_document" "assume-role-policy" {
  version = "2012-10-17"
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      identifiers = ["arn:aws:iam::${local.account-id}:oidc-provider/oidc.eks.${local.account-id}.amazonaws.com/id/${var.oicd-id}"]
      type        = "Federated"
    }
    condition {
      test     = "StringLike"
      values   = ["system:serviceaccount:kube-system:efs-csi-*"]
      variable = "oidc.eks.${local.account-id}.amazonaws.com/id/${var.oicd-id}:sub"
    }
    condition {
      test     = "StringLike"
      values   = ["sts.amazonaws.com"]
      variable = "oidc.eks.${local.account-id}.amazonaws.com/id/${var.oicd-id}:aud"
    }
  }
}

resource "aws_iam_role" "efs-driver-role" {
  assume_role_policy  = data.aws_iam_policy_document.assume-role-policy.json
  managed_policy_arns = ["arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy"]
}