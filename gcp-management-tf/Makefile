# GCP management VM — operator commands.
#
# Override tfvars file:  make plan TFVARS=prod.tfvars
TFVARS ?= terraform.tfvars
TF ?= terraform

.PHONY: help init fmt validate plan apply destroy ssh refresh refresh-from-states outputs

help:
	@echo "Targets:"
	@echo "  init                 - terraform init"
	@echo "  fmt                  - terraform fmt -recursive"
	@echo "  validate             - terraform validate"
	@echo "  plan                 - terraform plan (-var-file=$(TFVARS))"
	@echo "  apply                - terraform apply (-var-file=$(TFVARS))"
	@echo "  destroy              - terraform destroy"
	@echo "  ssh                  - gcloud compute ssh via IAP to the mgmt VM"
	@echo "  refresh              - SSH in and run refresh-kubeconfigs"
	@echo "  refresh-from-states  - re-pull cluster-stack outputs and re-apply (auto-approve)"
	@echo "  outputs              - terraform output"

init:
	$(TF) init

fmt:
	$(TF) fmt -recursive

validate: init
	$(TF) validate

plan:
	$(TF) plan -var-file=$(TFVARS) -out=tfplan

apply:
	$(TF) apply -var-file=$(TFVARS) tfplan || $(TF) apply -var-file=$(TFVARS)

destroy:
	$(TF) destroy -var-file=$(TFVARS)

outputs:
	$(TF) output

# Two-pass apply that lands fresh cluster-stack outputs without a code
# change in this stack. Pass 1 refreshes terraform_remote_state data
# sources; pass 2 re-renders the VM startup-script with the recomputed
# federation maps. Both passes -auto-approve (the `apply` target does
# NOT) — only run this when the only expected delta is the metadata
# startup-script.
refresh-from-states:
	$(TF) apply -var-file=$(TFVARS) -refresh-only -auto-approve
	$(TF) apply -var-file=$(TFVARS) -auto-approve

# Derive connection values from Terraform outputs.
ssh:
	@INSTANCE="$$($(TF) output -raw instance_name)"; \
	 ZONE="$$($(TF) output -raw instance_zone | awk -F/ '{print $$NF}')"; \
	 PROJECT="$$(grep -E '^project_id' $(TFVARS) | head -1 | awk -F'"' '{print $$2}')"; \
	 USER="$$(grep -E '^vm_username' $(TFVARS) | head -1 | awk -F'"' '{print $$2}')"; \
	 USER=$${USER:-devops}; \
	 echo ">> gcloud compute ssh $$INSTANCE --project=$$PROJECT --zone=$$ZONE --tunnel-through-iap"; \
	 gcloud compute ssh "$$INSTANCE" --project="$$PROJECT" --zone="$$ZONE" --tunnel-through-iap

refresh:
	@INSTANCE="$$($(TF) output -raw instance_name)"; \
	 ZONE="$$($(TF) output -raw instance_zone | awk -F/ '{print $$NF}')"; \
	 PROJECT="$$(grep -E '^project_id' $(TFVARS) | head -1 | awk -F'"' '{print $$2}')"; \
	 USER="$$(grep -E '^vm_username' $(TFVARS) | head -1 | awk -F'"' '{print $$2}')"; \
	 USER=$${USER:-devops}; \
	 gcloud compute ssh "$$INSTANCE" --project="$$PROJECT" --zone="$$ZONE" --tunnel-through-iap \
	   --command "sudo -iu $$USER /usr/local/bin/refresh-kubeconfigs"
