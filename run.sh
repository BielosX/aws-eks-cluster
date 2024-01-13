#!/bin/bash -e

export AWS_REGION="eu-west-1"
export AWS_PAGER=""
FLUENT_BIT_STACK="fluent-bit-role"
LB_CONTROLLER_STACK="load-balancer-controller-role"
CLUSTER_BACKEND_STACK="cluster-backend"
EFS_DRIVER_BACKEND_STACK="efs-driver-backend"
WITH_FLUENT_BIT=false
WITH_LB_CONTROLLER=false
WITH_INGRESS_NGINX=false
WITH_DASHBOARD=false
WITH_PROMETHEUS_STACK=false
WITH_EFS_DRIVER=false
SKIP_UNINSTALL=false
KEEP_LOGS=false
WITH_CALICO=false
WITH_NODES_NUMBER="2"
CALICO_OPERATOR_VERSION="v3.26.4"
CALICO_OPERATOR_URL="https://raw.githubusercontent.com/projectcalico/calico/${CALICO_OPERATOR_VERSION}/manifests/tigera-operator.yaml"

function deploy() {
  number_of_args="$#"
  while (( number_of_args > 0 )); do
    case "$1" in
      "--nodes")
        WITH_NODES_NUMBER="$2"
        shift
        shift
        ;;
      *)
        shift
        ;;
    esac
    number_of_args="$#"
  done
  local table_name="aws-eks-cluster"
  aws cloudformation deploy \
    --template-file backend.yaml \
    --stack-name "${CLUSTER_BACKEND_STACK}" \
    --parameter-overrides "TableName=${table_name}" "BucketNamePrefix=aws-eks-cluster"
  aws cloudformation update-termination-protection \
    --stack-name "${CLUSTER_BACKEND_STACK}" \
    --enable-termination-protection
  pushd live/demo-cluster
  get_stack_outputs "${CLUSTER_BACKEND_STACK}"
  local bucket_name
  bucket_name=$(jq -r '.BucketName.OutputValue' <<< "$outputs")
  tofu init -backend-config="bucket=${bucket_name}" \
    -backend-config="dynamodb_table=${table_name}" \
    -backend-config="region=${AWS_REGION}" \
    -backend-config="key=cluster.tfstate"
  tofu apply -auto-approve -var="nodes=${WITH_NODES_NUMBER}"
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

function get_private_subnet_ids() {
  get_cluster_vpc_id
  subnet_ids=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=${vpc_id}" "Name=tag:Name,Values=demo-cluster-vpc-private-subnet" \
    | jq -c '.Subnets | map(.SubnetId)')
}

function get_stack_outputs() {
  outputs=$(aws cloudformation describe-stacks --stack-name "$1" | jq -r '.Stacks[0].Outputs | INDEX(.OutputKey)')
}

function install_fluent_bit() {
  echo "Installing Fluent-Bit"
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
  kubectl create namespace "$namespace" --dry-run=client -o yaml | kubectl apply -f -
  export CLUSTER_NAME="demo-cluster"
  envsubst < cluster-info.yaml | kubectl apply -f -
  helm repo add fluent https://fluent.github.io/helm-charts
  helm repo update fluent
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
  echo "Installing AWS Load Balancer Controller"
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
  helm repo update eks
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
  echo "Installing Ingress Nginx"
  pushd extras/ingress-nginx
  local namespace="ingress-nginx"
  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
  helm repo update ingress-nginx
  helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
    -f nlb-service.yaml \
    --create-namespace \
    --namespace "${namespace}"
  popd
}

function install_dashboard() {
  echo "Installing Kubernetes Dashboard"
  helm repo add kubernetes-dashboard https://kubernetes.github.io/dashboard/
  helm repo update kubernetes-dashboard
  helm upgrade --install kubernetes-dashboard kubernetes-dashboard/kubernetes-dashboard \
    --create-namespace --namespace kubernetes-dashboard \
    --set nginx.enabled=false \
    --set cert-manager.enabled=false \
    --set app.ingress.enabled=false
  pushd extras/dashboard
  kubectl apply -f service-account.yaml
  kubectl apply -f secret.yaml
  popd
}

function install_prometheus_stack() {
  echo "Installing Prometheus Stack"

  pushd extras/efs-driver/live/demo-cluster
  local fs_id
  fs_id=$(tofu output -raw fs-id)
  popd

  pushd extras/prometheus-stack
  local namespace="prometheus-stack"
  kubectl create namespace "$namespace" --dry-run=client -o yaml | kubectl apply -f -
  export FS_ID="${fs_id}"
  envsubst < storage.yaml | kubectl apply -f -
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
  helm repo update prometheus-community
  init_password=$(openssl rand -base64 12)
  helm upgrade --install prometheus-stack prometheus-community/kube-prometheus-stack \
    --namespace prometheus-stack \
    --set grafana.adminPassword="${init_password}" \
    -f storage-values.yaml \
    -f security.yaml
  echo "Initial Grafana password: ${init_password}"
  popd
}

function uninstall_prometheus_stack() {
  helm uninstall prometheus-stack --namespace prometheus-stack --ignore-not-found
  pvc=$(kubectl get persistentvolumeclaims -n prometheus-stack -o json | jq -r '.items | map(.metadata.name)')
  local length
  length=$(jq -r 'length' <<< "$pvc")
  if ((length > 0)); then
    for i in $(seq 0 $((length-1))); do
      name=$(jq -r ".[$i]" <<< "$pvc")
      echo "Deleting PVC ${name}"
      kubectl delete persistentvolumeclaims "${name}" -n prometheus-stack --ignore-not-found=true
    done
  fi
  kubectl delete persistentvolume alertmanager-efs-pv --ignore-not-found=true
  kubectl delete persistentvolume prometheus-efs-pv --ignore-not-found=true
  kubectl delete storageclass prometheus-stack-efs-sc --ignore-not-found=true
  kubectl delete namespace "prometheus-stack" --ignore-not-found=true
}

function uninstall_dashboard() {
  pushd extras/dashboard
  kubectl delete -f secret.yaml --ignore-not-found=true
  kubectl delete -f service-account.yaml --ignore-not-found=true
  popd
  helm uninstall kubernetes-dashboard --ignore-not-found
}

function uninstall_ingress_nginx() {
   helm uninstall ingress-nginx --ignore-not-found
   kubectl delete namespace "ingress-nginx" --ignore-not-found=true
}

function install_efs_driver() {
  local table_name="efs-driver"
  aws cloudformation deploy \
    --template-file backend.yaml \
    --stack-name "${EFS_DRIVER_BACKEND_STACK}" \
    --parameter-overrides "TableName=${table_name}" "BucketNamePrefix=efs-driver"
  pushd extras/efs-driver/live/demo-cluster
  get_stack_outputs "${EFS_DRIVER_BACKEND_STACK}"
  local bucket_name
  bucket_name=$(jq -r '.BucketName.OutputValue' <<< "$outputs")
  tofu init -backend-config="bucket=${bucket_name}" \
    -backend-config="dynamodb_table=${table_name}" \
    -backend-config="region=${AWS_REGION}" \
    -backend-config="key=efs-driver.tfstate"
  get_oidc_id
  get_cluster_vpc_id
  get_private_subnet_ids
  tofu apply -auto-approve \
    -var="oicd-id=${oidc_id}" \
    -var="vpc-id=${vpc_id}" \
    -var="subnet-ids=${subnet_ids}"
  local role_arn
  read -r -d '\0' node_sa << EOM
{
  "create": true,
  "name": "efs-csi-node-sa",
  "annotations": {
    "eks.amazonaws.com/role-arn": "${role_arn}"
  }
}
\0
EOM
  read -r -d '\0' controller_sa << EOM
{
  "create": true,
  "name": "efs-csi-controller-sa",
  "annotations": {
    "eks.amazonaws.com/role-arn": "${role_arn}"
  }
}
\0
EOM
  helm repo add aws-efs-csi-driver https://kubernetes-sigs.github.io/aws-efs-csi-driver/
  helm repo update aws-efs-csi-driver
  helm upgrade --install aws-efs-csi-driver \
    --namespace kube-system aws-efs-csi-driver/aws-efs-csi-driver \
    --set-json "controller.serviceAccount=${controller_sa}" \
    --set-json "node.serviceAccount=${node_sa}"
  popd
}

function uninstall_efs_driver() {
  helm uninstall aws-efs-csi-driver --namespace kube-system --ignore-not-found
  if aws cloudformation describe-stacks --stack-name "${EFS_DRIVER_BACKEND_STACK}" &> /dev/null; then
    pushd extras/efs-driver/live/demo-cluster
      get_oidc_id
      get_cluster_vpc_id
      get_private_subnet_ids
        tofu destroy -auto-approve \
          -var="oicd-id=${oidc_id}" \
          -var="vpc-id=${vpc_id}" \
          -var="subnet-ids=${subnet_ids}"
        rm -rf .terraform
    popd
    get_stack_outputs "${EFS_DRIVER_BACKEND_STACK}"
    local bucket_name
    bucket_name=$(jq -r '.BucketName.OutputValue' <<< "$outputs")
    clean_backend_bucket "${bucket_name}"
    delete_stack "${EFS_DRIVER_BACKEND_STACK}"
  fi
}

function install_calico() {
  pushd extras/calico
  read -r -d '\0' role_patch << EOM
[
  {
    "op": "add",
    "path": "/rules/0",
    "value": {
      "apiGroups": [""],
      "resources": ["pods"],
      "verbs": ["patch"]
    }
  }
]
\0
EOM
  local calico_ready
  calico_ready=$(kubectl get daemonset -n kube-system aws-node -o json | jq -r '.metadata.annotations.calicoReady')
  if [ "${calico_ready}" != true ]; then
    kubectl patch clusterrole -n kube-system aws-node --type='json' -p="${role_patch}"
    kubectl patch daemonset -n kube-system aws-node --patch-file cni-plugin-env.yaml
    kubectl annotate daemonset -n kube-system aws-node calicoReady=true
  fi
  kubectl create -f "${CALICO_OPERATOR_URL}"
  kubectl apply -f installation.yaml
  popd
}

function uninstall_calico() {
  pushd extras/calico
  kubectl delete -f installation.yaml --ignore-not-found=true || true
  popd
  kubectl delete -f "${CALICO_OPERATOR_URL}" --ignore-not-found=true || true
}

function install() {
  number_of_args="$#"
  while (( number_of_args > 0 )); do
    case "$1" in
      "efs-driver")
        WITH_EFS_DRIVER=true
        shift
        ;;
      "prometheus-stack")
        WITH_PROMETHEUS_STACK=true
        shift
        ;;
      "dashboard")
        WITH_DASHBOARD=true
        shift
        ;;
      "ingress-nginx")
        WITH_INGRESS_NGINX=true
        shift
        ;;
      "lb-controller")
        WITH_LB_CONTROLLER=true
        shift
        ;;
      "fluent-bit")
        WITH_FLUENT_BIT=true
        shift
        ;;
      "calico")
        WITH_CALICO=true
        shift
        ;;
      *)
        shift
        ;;
    esac
    number_of_args="$#"
  done
  kubeconfig
  if [ "${WITH_FLUENT_BIT}" = true ]; then
    install_fluent_bit
  fi
  if [ "${WITH_CALICO}" = true ]; then
    install_calico
  fi
  if [ "${WITH_LB_CONTROLLER}" = true ]; then
    install_load_balancer_controller
  fi
  if [ "${WITH_LB_CONTROLLER}" = false ] && [ "${WITH_INGRESS_NGINX}" = true ]; then
    install_load_balancer_controller
    install_ingress_nginx
  elif [ "${WITH_INGRESS_NGINX}" = true ]; then
    install_ingress_nginx
  fi
  if [ "${WITH_DASHBOARD}" = true ]; then
    install_dashboard
  fi
  if [ "${WITH_EFS_DRIVER}" = true ]; then
    install_efs_driver
  fi
  if [ "${WITH_EFS_DRIVER}" = false ] && [ "${WITH_PROMETHEUS_STACK}" = true ]; then
    install_efs_driver
    install_prometheus_stack
  elif [ "${WITH_PROMETHEUS_STACK}" = true ]; then
    install_prometheus_stack
  fi
}

function uninstall() {
  kubeconfig
  uninstall_fluent_bit
  uninstall_calico
  uninstall_prometheus_stack
  uninstall_ingress_nginx
  uninstall_load_balancer_controller
  uninstall_dashboard
  uninstall_efs_driver
}

function delete_versions() {
  local response="$1"
  versions=$(jq -r '.Versions' <<< "$response")
  local length
  length=$(jq -r 'length' <<< "$versions")
  if ((length > 0)); then
    for i in $(seq 0 $((length-1))); do
      local version_id
      local key
      local item
      item=$(jq -r ".[$i]" <<< "$versions")
      version_id=$(jq -r '.VersionId' <<< "$item")
      key=$(jq -r '.Key' <<< "$item")
      echo "Deleting item VersionId=${version_id} Key=${key}"
      aws s3api delete-object --bucket "$bucket_name" --key "$key" --version-id "$version_id" &> /dev/null
    done
  fi
}

function clean_backend_bucket() {
  local bucket_name="$1"
  local response
  local versions
  local next_token
  echo "Removing all versions from ${bucket_name}"
  response=$(aws s3api list-object-versions --bucket "${bucket_name}")
  next_token=$(jq -r '.NextToken' <<< "$response")
  delete_versions "$response"
  while [ "${next_token}" != "null" ]; do
    response=$(aws s3api list-object-versions --bucket "${bucket_name}" --starting-token "$next_token")
    next_token=$(jq -r '.NextToken' <<< "$response")
    delete_versions "$response"
  done
}

function delete_log_groups_page() {
  local response="$1"
  local length
  local group_name
  local groups
  groups=$(jq -r '.logGroups' <<< "$response")
  length=$(jq -r 'length' <<< "$groups")
  if ((length > 0)); then
    for i in $(seq 0 $((length-1))); do
      group_name=$(jq -r ".[$i].logGroupName" <<< "$groups")
      echo "Deleting log group ${group_name}"
      aws logs delete-log-group --log-group-name "$group_name"
    done
  fi
}

function remove_log_groups() {
  local next_token
  response=$(aws logs describe-log-groups --log-group-name-prefix "/aws/containerinsights/demo-cluster")
  next_token=$(jq -r '.NextToken' <<< "$response")
  delete_log_groups_page "$response"
  while [ "${next_token}" != "null" ]; do
    response=$(aws logs describe-log-groups \
      --log-group-name-prefix "/aws/containerinsights/demo-cluster" --starting-token "$next_token")
    next_token=$(jq -r '.NextToken' <<< "$response")
    delete_log_groups_page "$response"
  done
}

function destroy() {
  number_of_args="$#"
  while (( number_of_args > 0 )); do
    case "$1" in
      "--skip-uninstall")
        SKIP_UNINSTALL=true
        shift
        ;;
      "--keep-logs")
        KEEP_LOGS=true
        shift
        ;;
      *)
        shift
        ;;
    esac
    number_of_args="$#"
  done
  if [ "${SKIP_UNINSTALL}" = false ] && aws eks describe-cluster --name demo-cluster &> /dev/null; then
    uninstall
  fi
  pushd live/demo-cluster
  tofu destroy -auto-approve
  popd
  get_stack_outputs "${CLUSTER_BACKEND_STACK}"
  local bucket_name
  bucket_name=$(jq -r '.BucketName.OutputValue' <<< "$outputs")
  clean_backend_bucket "${bucket_name}"
  aws cloudformation update-termination-protection \
    --stack-name "${CLUSTER_BACKEND_STACK}" \
    --no-enable-termination-protection
  delete_stack "${CLUSTER_BACKEND_STACK}"
  if [ "${KEEP_LOGS}" = false ]; then
    echo "Removing cluster logs"
    remove_log_groups
  else
    echo "Cluster log groups will be kept"
  fi
}

function get_dashboard_secret_token() {
   token=$(kubectl get secret dashboard-secret -n kubernetes-dashboard -o json | jq -r '.data.token' | base64 --decode)
   echo "$token"
}

function dashboard_port_forward() {
  local namespace="kubernetes-dashboard"
  pod=$(kubectl get pods -n "${namespace}" \
    -l app.kubernetes.io/name=kubernetes-dashboard -o json | jq -r '.items[0]')
  pod_name=$(jq -r '.metadata.name' <<< "$pod")
  kubectl -n "${namespace}" port-forward "${pod_name}" 8443:8443
}

case "$1" in
  "deploy") deploy "$@" ;;
  "destroy") destroy "$@" ;;
  "install") install "$@" ;;
  "uninstall") uninstall ;;
  "kubeconfig") kubeconfig ;;
  "format") tofu fmt -recursive . ;;
  "token") get_dashboard_secret_token ;;
  "dashboard-port-forward") dashboard_port_forward ;;
esac