#!/bin/bash -e

function apply() {
  local example="$1"
  local action="$2"
  if [ ! -d "${example}" ]; then
    echo "Example ${example} does not exist"
    exit 255
  fi
  pushd "${example}/base"
  if [ "${action}" = "deploy" ]; then
    kustomize build | kubectl apply -f -
  fi
  if [ "${action}" = "destroy" ]; then
    kustomize build | kubectl delete -f -
  fi
  popd
}

case "$1" in
  "deploy") apply "$2" "deploy" ;;
  "destroy") apply "$2" "destroy" ;;
esac