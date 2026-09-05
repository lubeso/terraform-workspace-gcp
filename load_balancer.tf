data "cloudflare_ip_ranges" "main" {}

locals {
  # google_compute_security_policy rules cap src_ip_ranges at 10 entries per rule, so
  # Cloudflare's published ranges are split into chunks, one allow rule per chunk.
  cloudflare_ip_range_chunks = chunklist(
    concat(data.cloudflare_ip_ranges.main.ipv4_cidrs, data.cloudflare_ip_ranges.main.ipv6_cidrs),
    10,
  )
}

resource "google_compute_global_address" "main" {
  name = "default"
}

resource "google_certificate_manager_dns_authorization" "main" {
  name   = "default"
  domain = var.domain
}

resource "google_certificate_manager_certificate" "main" {
  name  = "default"
  scope = "DEFAULT"
  managed {
    domains = [
      var.domain,
      "*.${var.domain}",
    ]
    dns_authorizations = [google_certificate_manager_dns_authorization.main.id]
  }
}

resource "google_certificate_manager_certificate_map" "main" {
  name = "default"
}

resource "google_certificate_manager_certificate_map_entry" "apex" {
  name         = "apex"
  map          = google_certificate_manager_certificate_map.main.name
  certificates = [google_certificate_manager_certificate.main.id]
  hostname     = var.domain
}

resource "google_certificate_manager_certificate_map_entry" "wildcard" {
  name         = "wildcard"
  map          = google_certificate_manager_certificate_map.main.name
  certificates = [google_certificate_manager_certificate.main.id]
  hostname     = "*.${var.domain}"
}

data "http" "cloudflare_origin_pull_ca" {
  url = "https://developers.cloudflare.com/ssl/static/authenticated_origin_pull_ca.pem"

  lifecycle {
    postcondition {
      condition     = self.status_code == 200
      error_message = "Failed to fetch the Cloudflare Authenticated Origin Pull CA certificate (HTTP ${self.status_code})."
    }
  }
}

resource "google_certificate_manager_trust_config" "cloudflare_origin_pull" {
  name     = "cloudflare-origin-pull"
  location = "global"

  trust_stores {
    trust_anchors {
      pem_certificate = trimspace(data.http.cloudflare_origin_pull_ca.response_body)
    }
  }
}

resource "google_project_service" "network_security" {
  project            = data.google_client_config.main.project
  service            = "networksecurity.googleapis.com"
  disable_on_destroy = false
}

resource "google_network_security_server_tls_policy" "cloudflare_origin_pull" {
  name       = "cloudflare-origin-pull"
  location   = "global"
  allow_open = "false"

  mtls_policy {
    client_validation_mode = "REJECT_INVALID"
    # GCP canonicalizes this reference to the project *number* form once the resource
    # exists, so build it that way up front rather than with trust_config.id (which
    # uses the project ID) - otherwise every subsequent plan sees a diff on this
    # immutable field and force-replaces the policy.
    client_validation_trust_config = "projects/${data.google_project.main.number}/locations/global/trustConfigs/${google_certificate_manager_trust_config.cloudflare_origin_pull.name}"
  }

  depends_on = [google_project_service.network_security]
}

resource "google_compute_url_map" "https" {
  name            = "https"
  default_service = google_compute_backend_bucket.static.id

  host_rule {
    hosts        = ["www.${var.domain}"]
    path_matcher = "www"
  }

  path_matcher {
    name            = "www"
    default_service = google_compute_backend_bucket.static.id
  }

  host_rule {
    hosts        = ["webhooks.${var.domain}"]
    path_matcher = "webhooks"
  }

  path_matcher {
    name            = "webhooks"
    default_service = google_compute_backend_bucket.static.id
    dynamic "path_rule" {
      for_each = local.flattened_webhooks
      content {
        paths   = ["/${path_rule.value.provider}/${path_rule.value.version}"]
        service = google_compute_backend_service.webhooks[path_rule.key].id
      }
    }
  }
}

resource "google_compute_url_map" "http" {
  name = "http"
  default_url_redirect {
    https_redirect = true
    strip_query    = false
  }
}

resource "google_compute_target_https_proxy" "main" {
  name            = google_compute_global_address.main.name
  url_map         = google_compute_url_map.https.id
  certificate_map = "//certificatemanager.googleapis.com/${google_certificate_manager_certificate_map.main.id}"
  # Built with the project number rather than server_tls_policy.id (which uses the
  # project ID) - the sibling cross-service reference in mtls_policy.client_validation_trust_config
  # was confirmed to canonicalize to project-number form once live, forcing a
  # perpetual diff; this reference is the same category (a compute.googleapis.com
  # resource pointing into networksecurity.googleapis.com), so build it the same way
  # up front.
  server_tls_policy = "projects/${data.google_project.main.number}/locations/global/serverTlsPolicies/${google_network_security_server_tls_policy.cloudflare_origin_pull.name}"
}

resource "google_compute_target_http_proxy" "main" {
  name    = google_compute_global_address.main.name
  url_map = google_compute_url_map.http.self_link
}

resource "google_compute_global_forwarding_rule" "https" {
  name                  = "https"
  target                = google_compute_target_https_proxy.main.id
  ip_address            = google_compute_global_address.main.id
  ip_protocol           = "TCP"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  port_range            = "443"
}

resource "google_compute_global_forwarding_rule" "http" {
  name                  = "http"
  target                = google_compute_target_http_proxy.main.id
  ip_address            = google_compute_global_address.main.id
  ip_protocol           = "TCP"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  port_range            = "80"
}

resource "google_compute_security_policy" "cloudflare_only" {
  name = "cloudflare-only"
  type = "CLOUD_ARMOR_EDGE"

  dynamic "rule" {
    for_each = local.cloudflare_ip_range_chunks
    content {
      action      = "allow"
      priority    = 1000 + rule.key
      description = "Allow Cloudflare edge IP ranges"
      match {
        versioned_expr = "SRC_IPS_V1"
        config {
          src_ip_ranges = rule.value
        }
      }
    }
  }

  rule {
    action      = "deny(403)"
    priority    = 2147483647
    description = "Default deny: traffic not from Cloudflare"
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
  }
}
