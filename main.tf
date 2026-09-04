data "google_client_config" "main" {
  # This block is purposely empty
}

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
      for_each = local.webhooks_flat
      content {
        paths   = ["/${path_rule.value.provider}/${path_rule.value.version}"]
        service = google_compute_backend_service.webhook[path_rule.key].id
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

locals {
  webhooks_flat = merge([
    for provider, versions in var.webhooks : {
      for version, config in versions :
      "${provider}-${version}" => {
        provider = provider
        version  = version
        config   = config
      }
    }
  ]...)
}

resource "google_artifact_registry_repository" "webhooks" {
  location      = data.google_client_config.main.region
  repository_id = "webhooks"
  format        = "DOCKER"
}

resource "google_cloud_run_v2_service" "webhook" {
  for_each = local.webhooks_flat
  name     = "webhook-${each.key}"
  location = data.google_client_config.main.region
  ingress  = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"

  template {
    containers {
      # Placeholder only - CI deploys the real image built via `pack` to this
      # service (`gcloud run deploy webhook-${each.key} --image=...`).
      image = "us-docker.pkg.dev/cloudrun/container/hello"
    }
    labels = {
      runtime = each.value.config.runtime
    }
  }

  lifecycle {
    ignore_changes = [template[0].containers[0].image]
  }
}

resource "google_compute_region_network_endpoint_group" "webhook" {
  for_each              = local.webhooks_flat
  name                  = "webhook-${each.key}"
  region                = data.google_client_config.main.region
  network_endpoint_type = "SERVERLESS"
  cloud_run {
    service = google_cloud_run_v2_service.webhook[each.key].name
  }
}

resource "google_compute_backend_service" "webhook" {
  for_each             = local.webhooks_flat
  name                 = "webhook-${each.key}"
  edge_security_policy = google_compute_security_policy.cloudflare_only.id
  backend {
    group = google_compute_region_network_endpoint_group.webhook[each.key].id
  }
}

resource "google_cloud_run_v2_service_iam_member" "webhook_invoker" {
  for_each = local.webhooks_flat
  project  = google_cloud_run_v2_service.webhook[each.key].project
  location = google_cloud_run_v2_service.webhook[each.key].location
  name     = google_cloud_run_v2_service.webhook[each.key].name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

resource "google_compute_backend_bucket" "static" {
  name                 = module.storage_bucket_static.name
  bucket_name          = module.storage_bucket_static.name
  enable_cdn           = true
  edge_security_policy = google_compute_security_policy.cloudflare_only.id
}

module "storage_bucket_static" {
  source        = "terraform-google-modules/cloud-storage/google//modules/simple_bucket"
  version       = "~> 12.3.0"
  name          = "static-${data.google_client_config.main.project}"
  location      = data.google_client_config.main.region
  project_id    = data.google_client_config.main.project
  force_destroy = true
  storage_class = "STANDARD"
  versioning    = false
  website = {
    main_page_suffix = "index.html"
  }
  iam_members = [
    {
      member = "allUsers"
      role   = "roles/storage.objectViewer"
    }
  ]
}

module "oidc_github_actions" {
  source  = "github.com/lubeso/terraform-module-gcp-oidc.git?ref=v1.0.0"
  project = data.google_client_config.main.project
  service_account = {
    account_id   = "github-actions"
    display_name = "GitHub Actions"
    iam = {
      principal = {
        subject = {
          attribute_value = var.github_owner_id
        }
      }
      roles = [
        "artifactregistry.admin",
        "cloudbuild.builds.builder",
        "run.admin",
        "storage.admin",
      ]
    }
  }

  workload_identity_pool = {
    id           = "github-actions"
    display_name = "GitHub Actions"
  }

  workload_identity_pool_provider = {
    attribute_condition = <<-EOF
    (
      assertion.actor_id == '${var.github_owner_id}'
      && (
        assertion.ref == 'refs/heads/main'
        || assertion.ref.startsWith('refs/tags/')
      )
    )
    EOF
    attribute_mapping = {
      "google.subject" = "assertion.repository_owner_id"
    }
    oidc = {
      issuer_uri = "https://token.actions.githubusercontent.com"
    }
  }
}

module "oidc_terraform_cloud" {
  source  = "github.com/lubeso/terraform-module-gcp-oidc.git?ref=v1.0.0"
  project = data.google_client_config.main.project
  service_account = {
    account_id   = "terraform-cloud"
    display_name = "Terraform Cloud"
    iam = {
      principal = {
        subject = {
          attribute_value = var.terraform_workspace_id
        }
      }
      roles = ["owner"]
    }
  }
  workload_identity_pool = {
    id           = "terraform-cloud"
    display_name = "Terraform Cloud"
  }
  workload_identity_pool_provider = {
    attribute_condition = <<-EOF
    assertion.terraform_workspace_id == '${var.terraform_workspace_id}'
    EOF
    attribute_mapping = {
      "google.subject" = "assertion.terraform_workspace_id"
    }
    oidc = {
      issuer_uri = "https://app.terraform.io"
    }
  }
}
