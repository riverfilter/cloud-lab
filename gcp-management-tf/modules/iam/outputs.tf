output "service_account_email" {
  description = "Email of the management VM service account."
  value       = google_service_account.mgmt_vm.email
}

output "service_account_id" {
  description = "Unique ID of the management VM service account."
  value       = google_service_account.mgmt_vm.unique_id
}

output "service_account_unique_id" {
  description = "Numeric unique_id of the mgmt VM SA. Required by AWS (OIDC sub) and Azure (federated credential subject) WIF trust policies. Alias of service_account_id, named to match the variable the cluster stacks expect."
  value       = google_service_account.mgmt_vm.unique_id
}
