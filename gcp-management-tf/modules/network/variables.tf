variable "project_id" {
  type = string
}

variable "region" {
  type = string
}

variable "name_prefix" {
  description = "Prefix for every resource name created by this module (VPC, subnet, router, NAT gateway, static NAT IP, firewall rules). Must be unique within the project+region: google_compute_address.nat is named <name_prefix>-nat-ip and google_compute_address names collide per project+region, so two parallel mgmt-stack applies sharing this prefix in the same project/region (different workspaces, dev/shared pair) fail at create time with a non-idempotent error. Suffixing with workspace or environment is the conventional disambiguator. NOT auto-suffixed with random_id by design — stability of the NAT egress IP is the whole point of the static address (every cluster's authorized_cidrs references it), so the address name must be deterministic across applies."
  type        = string
}

variable "subnet_cidr" {
  type = string
}
