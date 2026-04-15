variable "org_id" {
  description = "Org ID for org-level bindings."
  type        = string
}

variable "project_id" {
  description = "Host project for the service account."
  type        = string
}

variable "name_prefix" {
  description = "Name prefix for the SA."
  type        = string
}

variable "iam_scope" {
  description = "`organization` (default) or `project`. Determines where discovery roles are bound."
  type        = string
  default     = "organization"
}
