data "aws_caller_identity" "current" {}

locals {
  account_id   = data.aws_caller_identity.current.account_id
  oidc_id      = reverse(split("/", aws_eks_cluster.cluster.identity[0].oidc[0].issuer))[0]
  provider_arn = "arn:aws:iam::${local.account_id}:oidc-provider/oidc.eks.${var.region}.amazonaws.com/id/${local.oidc_id}"
}

resource "aws_iam_policy" "lb_controller_policy" {
  name   = "AWSLoadBalancerControllerIAMPolicy"
  policy = file("${path.module}/lb-controller-iam-policy.json")
}

module "lb_controller_role" {
  source    = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  role_name = "aws-load-balancer-controller-iam-role"

  role_policy_arns = {
    policy = aws_iam_policy.lb_controller_policy.arn
  }

  oidc_providers = {
    main = {
      provider_arn               = local.provider_arn
      namespace_service_accounts = ["kube-system"]
    }
  }
}