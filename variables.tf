variable "domain" {
  type = string
}

variable "webhooks" {
  description = <<-EOF
    Nested map of provider name => API version => per-endpoint config, one
    Cloud Run service per (provider, version) pair, routed at
    https://webhooks.<domain>/<provider>/<version>. An empty {} config uses
    all defaults. Example: { "notion" = { "2026-03-11" = {} } }
  EOF
  type = map(map(object({
    runtime = optional(string, "go") # or "nodejs"
  })))
  default = {}

  validation {
    condition = alltrue(flatten([
      for provider, versions in var.webhooks : [
        for version, _ in versions :
        can(regex("^[a-z][a-z0-9-]*$", provider)) && can(regex("^[a-z0-9][a-z0-9-]*$", version))
      ]
    ]))
    error_message = "Provider and version keys must be lowercase alphanumeric/hyphens only (they become Cloud Run resource-name components)."
  }
}

variable "github_owner_id" {
  type = number
}

variable "terraform_workspace_id" {
  type = string
}
