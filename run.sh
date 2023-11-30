#!/bin/bash -e

export AWS_REGION="eu-west-1"

function deploy() {
  pushd live/demo
  tofu init && tofu apply -auto-approve
  popd
}

function destroy() {
  pushd live/demo
  tofu destroy -auto-approve
  popd
}

function kubeconfig() {
  rm ~/.kube/config
  aws eks update-kubeconfig --region "$AWS_REGION" --name "demo-cluster"
}

case "$1" in
  "deploy") deploy ;;
  "destroy") destroy ;;
  "kubeconfig") kubeconfig ;;
  "format") tofu fmt -recursive . ;;
esac