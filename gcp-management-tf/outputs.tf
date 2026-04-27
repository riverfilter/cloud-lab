output "instance_name" {
  description = "Name of the management VM."
  value       = module.mgmt_vm.instance_name
}

output "instance_zone" {
  description = "Zone the VM lives in."
  value       = module.mgmt_vm.instance_zone
}

output "internal_ip" {
  description = "Internal IP of the management VM."
  value       = module.mgmt_vm.internal_ip
}

output "external_ip" {
  description = "External IP (null when allow_public_ip = false)."
  value       = module.mgmt_vm.external_ip
}

output "service_account_email" {
  description = "Email of the VM's dedicated service account."
  value       = module.iam.service_account_email
}

output "service_account_unique_id" {
  description = "Numeric unique_id of the mgmt VM SA. Pass this to aws-eks-tf and azure-aks-tf as var.mgmt_vm_gcp_sa_unique_id — it is the OIDC subject in the AWS/Azure federated trust policies."
  value       = module.iam.service_account_unique_id
}

output "ssh_via_iap_command" {
  description = "Ready-to-run gcloud SSH command (IAP tunnel)."
  value       = "gcloud compute ssh ${module.mgmt_vm.instance_name} --project=${var.project_id} --zone=${var.zone} --tunnel-through-iap"
}

output "nat_public_ip" {
  description = "Static egress IP of the management VM. Append '<IP>/32' to authorized_cidrs in gcp-gke-tf, aws-eks-tf, and azure-aks-tf tfvars so the mgmt VM can reach each cluster's control plane. Null when create_network = false."
  value       = var.create_network ? module.network[0].nat_public_ip : null
}
