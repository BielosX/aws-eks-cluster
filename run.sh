#!/bin/bash -e

export AWS_REGION="eu-west-1"
export AWS_PAGER=""
FLUENT_BIT_STACK="fluent-bit-role"

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
  rm ~/.kube/config
  aws eks update-kubeconfig --region "$AWS_REGION" --name "demo-cluster"
}

function get_oidc_id() {
    oidc_id=$(aws eks describe-cluster \
      --name demo-cluster \
      --query "cluster.identity.oidc.issuer" \
      --output text | cut -d '/' -f 5)
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
  kubectl create namespace "$namespace"
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

function install() {
  install_fluent_bit
}

function uninstall() {
  uninstall_fluent_bit
}

case "$1" in
  "deploy") deploy ;;
  "destroy") destroy ;;
  "install") install ;;
  "uninstall") uninstall ;;
  "kubeconfig") kubeconfig ;;
  "format") tofu fmt -recursive . ;;
esac