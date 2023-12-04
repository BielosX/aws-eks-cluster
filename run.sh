#!/bin/bash -e

export AWS_REGION="eu-west-1"
export AWS_PAGER=""
FLUENT_BIT_STACK="fluent-bit-role"
LB_CONTROLLER_STACK="load-balancer-controller-role"

function deploy() {
  pushd live/demo-cluster
  tofu init && tofu apply -auto-approve
  popd
}

function destroy() {
  pushd live/demo-cluster
  tofu destroy -auto-approve
  popd
}

function kubeconfig() {
  rm -f ~/.kube/config
  aws eks update-kubeconfig --region "$AWS_REGION" --name "demo-cluster"
}

function get_oidc_id() {
    oidc_id=$(aws eks describe-cluster \
      --name demo-cluster \
      --query "cluster.identity.oidc.issuer" \
      --output text | cut -d '/' -f 5)
}

function get_cluster_vpc_id() {
    vpc_id=$(aws eks describe-cluster --name demo-cluster | jq -r '.cluster.resourcesVpcConfig.vpcId')
}

function get_stack_outputs() {
  outputs=$(aws cloudformation describe-stacks --stack-name "$1" | jq -r '.Stacks[0].Outputs | INDEX(.OutputKey)')
}

function install_fluent_bit() {
  pushd extras/fluent-bit
  local service_account_name="fluent-bit-sa"
  local namespace="amazon-cloudwatch"
  get_oidc_id
  aws cloudformation deploy \
    --template-file iam-role.yaml \
    --stack-name "${FLUENT_BIT_STACK}" \
    --capabilities "CAPABILITY_IAM" "CAPABILITY_NAMED_IAM" \
    --parameter-overrides "Namespace=${namespace}" "ServiceAccount=${service_account_name}" "OidcId=${oidc_id}"
  get_stack_outputs "${FLUENT_BIT_STACK}"
  local role_arn
  role_arn=$(jq -r '.RoleArn.OutputValue' <<< "$outputs")
  kubeconfig
  kubectl create namespace "$namespace" --dry-run=client -o yaml | kubectl apply -f -
  export CLUSTER_NAME="demo-cluster"
  envsubst < cluster-info.yaml | kubectl apply -f -
  helm repo add fluent https://fluent.github.io/helm-charts
read -r -d '\0' service_account << EOM
{
  "create": true,
  "name": "${service_account_name}",
  "annotations": {
    "eks.amazonaws.com/role-arn": "${role_arn}"
  }
}
\0
EOM
  helm upgrade --install fluent-bit fluent/fluent-bit \
    --namespace "${namespace}" \
    -f env.yaml \
    -f volumes.yaml \
    -f config.yaml \
    -f network.yaml \
    -f rbac.yaml \
    --set-json "serviceAccount=${service_account}"
  popd
}

function delete_stack() {
  echo "Deleting stack $1"
  aws cloudformation delete-stack --stack-name "$1"
  while aws cloudformation describe-stacks --stack-name "$1" &> /dev/null; do
    echo "Stack $1 still exists. Waiting"
    sleep 20
  done
  echo "Stack $1 deleted"
}

function uninstall_fluent_bit() {
  helm uninstall fluent-bit --namespace "amazon-cloudwatch" --ignore-not-found
  kubectl delete configmap fluent-bit-cluster-info -n "amazon-cloudwatch" --ignore-not-found=true
  kubectl delete namespace "amazon-cloudwatch" --ignore-not-found=true
  delete_stack "${FLUENT_BIT_STACK}"
}

function install_load_balancer_controller() {
  pushd extras/load-balancer-controller
  local namespace="kube-system"
  local service_account_name="aws-load-balancer-controller"
  get_oidc_id
  aws cloudformation deploy \
    --template-file iam.yaml \
    --stack-name "${LB_CONTROLLER_STACK}" \
    --capabilities "CAPABILITY_IAM" "CAPABILITY_NAMED_IAM" \
    --parameter-overrides "Namespace=${namespace}" "ServiceAccount=${service_account_name}" "OidcId=${oidc_id}"
  get_stack_outputs "${LB_CONTROLLER_STACK}"
  local role_arn
  role_arn=$(jq -r '.RoleArn.OutputValue' <<< "$outputs")
read -r -d '\0' service_account << EOM
{
  "create": true,
  "name": "aws-load-balancer-controller",
  "annotations": {
    "eks.amazonaws.com/role-arn": "${role_arn}"
  }
}
\0
EOM
  get_cluster_vpc_id
  helm repo add eks https://aws.github.io/eks-charts
  helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
    --namespace "${namespace}" \
    --set clusterName="demo-cluster" \
    --set region="${AWS_REGION}" \
    --set vpcId="${vpc_id}" \
    --set-json "serviceAccount=${service_account}"
  popd
}

function uninstall_load_balancer_controller() {
   helm uninstall aws-load-balancer-controller --namespace "kube-system" --ignore-not-found
   delete_stack "${LB_CONTROLLER_STACK}"
}

function install_ingress_nginx() {
  pushd extras/ingress-nginx
  local namespace="ingress-nginx"
  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
  helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
    -f nlb-service.yaml \
    --create-namespace \
    --namespace "${namespace}"
  popd
}

function install_dashboard() {
  helm repo add kubernetes-dashboard https://kubernetes.github.io/dashboard/
  helm upgrade --install kubernetes-dashboard kubernetes-dashboard/kubernetes-dashboard \
    --create-namespace --namespace kubernetes-dashboard \
    --set nginx.enabled=false \
    --set cert-manager.enabled=false \
    --set app.ingress.enabled=false
  pushd extras/dashboard
  kubectl apply -f permissions.yaml
  popd
}

function uninstall_dashboard() {
   pushd extras/dashboard
   kubectl delete -f permissions.yaml
   popd
   helm uninstall kubernetes-dashboard --ignore-not-found
}

function uninstall_ingress_nginx() {
   helm uninstall ingress-nginx --ignore-not-found
   kubectl delete namespace "ingress-nginx" --ignore-not-found=true
}

function install() {
  install_fluent_bit
  install_load_balancer_controller
  install_ingress_nginx
  install_dashboard
}

function uninstall() {
  uninstall_fluent_bit
  uninstall_ingress_nginx
  uninstall_load_balancer_controller
  uninstall_dashboard
}

function get_dashboard_secret_token() {
   token=$(kubectl get secret dashboard-secret -n kubernetes-dashboard -o json | jq -r '.data.token' | base64 --decode)
   echo "$token"
}

case "$1" in
  "deploy") deploy ;;
  "destroy") destroy ;;
  "install") install ;;
  "uninstall") uninstall ;;
  "kubeconfig") kubeconfig ;;
  "format") tofu fmt -recursive . ;;
  "token") get_dashboard_secret_token ;;
esac