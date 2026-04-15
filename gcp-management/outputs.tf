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

output "ssh_via_iap_command" {
  description = "Ready-to-run gcloud SSH command (IAP tunnel)."
  value       = "gcloud compute ssh ${module.mgmt_vm.instance_name} --project=${var.project_id} --zone=${var.zone} --tunnel-through-iap"
}
