output "certificate_manager_dns_authorization_record" {
  description = "DNS CNAME record to add at the external DNS provider for var.domain, authorizing the Certificate Manager certificate for both var.domain and *.var.domain. Must be created manually before the certificate can reach ACTIVE status."
  value = {
    name = google_certificate_manager_dns_authorization.main.dns_resource_record[0].name
    type = google_certificate_manager_dns_authorization.main.dns_resource_record[0].type
    data = google_certificate_manager_dns_authorization.main.dns_resource_record[0].data
  }
}
