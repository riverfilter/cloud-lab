############################################
# Cross-stack remote-state wiring (opt-in)
############################################
#
# These data sources let mgmt-tf consume each cluster stack's outputs
# directly from its remote state, replacing the manual paste-dance that
# var.aws_role_arns / var.azure_federated_apps currently require.
#
# Both maps default to {} so this stack still applies cleanly with local
# state and explicit-map workflows. When populated, the entries are
# MERGED with the explicit maps in main.tf — explicit entries win on
# key collision (last-arg wins in `merge()`), so an operator can override
# a single label without dropping the entire remote-state path.
#
# Apply order with this wiring:
#   1. Apply mgmt-tf with all four maps empty.
#      Capture: service_account_unique_id, nat_public_ip.
#   2. Apply each cluster stack with those values + `<NAT_IP>/32` in
#      authorized_cidrs.
#   3. Re-apply mgmt-tf with `aws_eks_states` / `azure_aks_states`
#      pointing at each cluster stack's remote-state location (or paste
#      the cluster outputs into `aws_role_arns` / `azure_federated_apps`
#      directly, the legacy path). The bootstrap script regenerates
#      /etc/mgmt/federated-principals.json on the next cloud-init run.
#
# Backend choices below intentionally mirror each cluster stack's own
# backend (S3 for aws-eks-tf, azurerm for azure-aks-tf). If your fleet
# uses a different backend (e.g. all stacks in GCS), this file needs to
# be adjusted — `terraform_remote_state` does not support runtime
# backend selection.

data "terraform_remote_state" "aws_eks" {
  for_each = var.aws_eks_states

  backend = "s3"

  config = {
    bucket = each.value.bucket
    key    = each.value.key
    region = each.value.region
  }
}

data "terraform_remote_state" "azure_aks" {
  for_each = var.azure_aks_states

  backend = "azurerm"

  config = {
    resource_group_name  = each.value.resource_group_name
    storage_account_name = each.value.storage_account_name
    container_name       = each.value.container_name
    key                  = each.value.key
  }
}
