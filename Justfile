export AWS_REGION := "eu-west-1"

name-prefix := "eks"
stack-name := name-prefix + "-backend"

format:
    tofu fmt -recursive "{{ justfile_directory() }}/tf"

deploy-backend:
    aws cloudformation deploy \
      --template-file "{{ justfile_directory() }}/backend.yaml" \
      --stack-name "{{ stack-name }}" \
      --parameter-overrides "NamePrefix={{ name-prefix }}"

tofu-init:
    #!/bin/bash
    state_bucket=$(aws ssm get-parameter --name "{{name-prefix}}-state-bucket" | jq -r '.Parameter.Value')
    lock_table=$(aws ssm get-parameter --name "{{name-prefix}}-lock-table" | jq -r '.Parameter.Value')
    tofu -chdir="{{ justfile_directory() }}/tf" init \
      -backend-config="demo.tfbackend" \
      -backend-config="bucket=${state_bucket}" \
      -backend-config="dynamodb_table=${lock_table}"

deploy: deploy-backend tofu-init
    tofu -chdir="{{ justfile_directory() }}/tf" apply -auto-approve -var-file="demo.tfvars"

kubeconfig:
    aws eks update-kubeconfig --name "demo"

install-packages: kubeconfig
    ansible-playbook "{{ justfile_directory() }}/playbooks/install.yaml"

destroy:
    tofu -chdir="{{ justfile_directory() }}/tf" destroy -auto-approve -var-file="demo.tfvars"
