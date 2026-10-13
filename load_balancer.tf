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

resource "google_compute_security_policy" "cloudflare_only" {
  name = "cloudflare-only"
  type = "CLOUD_ARMOR_EDGE"

  dynamic "rule" {
    for_each = local.cloudflare_ip_range_chunks
    content {
      action   = "allow"
      priority = 1000 + rule.key
      match {
        versioned_expr = "SRC_IPS_V1"
        config {
          src_ip_ranges = rule.value
        }
      }
      description = "Allow traffic from Cloudflare IP range chunk ${rule.key}"
    }
  }

  rule {
    action   = "deny(403)"
    priority = 2147483647
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    description = "Default deny all non-Cloudflare traffic"
  }
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
