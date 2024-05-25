name-prefix := "eks"
backend-region := "eu-west-1"
stack-name := name-prefix + "-backend"

format:
    tofu fmt -recursive {{ justfile_directory() }}

deploy-backend:
    aws --region "{{ backend-region }}" cloudformation deploy \
      --template-file "{{ justfile_directory() }}/backend.yaml" \
      --stack-name "{{ stack-name }}" \
      --parameter-overrides "NamePrefix={{ name-prefix }}"

tofu-init:
    #!/bin/bash
    state_bucket=$(aws --region "{{ backend-region }}" ssm get-parameter --name "{{name-prefix}}-state-bucket" | jq -r '.Parameter.Value')
    lock_table=$(aws --region "{{ backend-region }}" ssm get-parameter --name "{{name-prefix}}-lock-table" | jq -r '.Parameter.Value')
    tofu init \
      -backend-config="{{ justfile_directory() }}/demo.tfbackend" \
      -backend-config="bucket=${state_bucket}" \
      -backend-config="dynamodb_table=${lock_table}"

deploy: deploy-backend tofu-init
    tofu apply -auto-approve -var-file="{{ justfile_directory() }}/demo.tfvars"

destroy:
    tofu destroy -auto-approve -var-file="{{ justfile_directory() }}/demo.tfvars"
