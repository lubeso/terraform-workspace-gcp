output "certificate_manager_dns_authorization_record" {
  description = "DNS CNAME record to add at the external DNS provider for var.domain, authorizing the Certificate Manager certificate for both var.domain and *.var.domain. Must be created manually before the certificate can reach ACTIVE status."
  value = {
    name = google_certificate_manager_dns_authorization.main.dns_resource_record[0].name
    type = google_certificate_manager_dns_authorization.main.dns_resource_record[0].type
    data = google_certificate_manager_dns_authorization.main.dns_resource_record[0].data
  }
}

# --- Identity & CI Outputs ---

output "gcp_project_id" {
  description = "GCP Project ID."
  value       = data.google_client_config.main.project
}

output "gcp_region" {
  description = "GCP region hosting static resources and Cloud Storage."
  value       = data.google_client_config.main.region
}

output "github_actions_workload_identity_provider" {
  description = "Full resource name of the WIF provider for GitHub Actions."
  value       = module.oidc_github_actions.workload_identity_pool_provider_name
}

output "github_actions_service_account_email" {
  description = "Email of the service account for GitHub Actions."
  value       = module.oidc_github_actions.service_account_email
}

output "terraform_cloud_workload_identity_provider" {
  description = "Full resource name of the WIF provider for Terraform Cloud."
  value       = module.oidc_terraform_cloud.workload_identity_pool_provider_name
}

output "terraform_cloud_service_account_email" {
  description = "Email of the service account for Terraform Cloud."
  value       = module.oidc_terraform_cloud.service_account_email
}
