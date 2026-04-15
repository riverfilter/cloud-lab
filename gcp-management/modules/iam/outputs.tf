output "service_account_email" {
  description = "Email of the management VM service account."
  value       = google_service_account.mgmt_vm.email
}

output "service_account_id" {
  description = "Unique ID of the management VM service account."
  value       = google_service_account.mgmt_vm.unique_id
}
