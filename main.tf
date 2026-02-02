data "google_client_config" "main" {
  # This block is purposely empty
}

resource "google_compute_global_address" "main" {
  name = "default"
}

resource "google_compute_managed_ssl_certificate" "main" {
  name = google_compute_global_address.main.name
  managed {
    domains = [
      for website in var.websites
      : "${website}.${var.domain}"
    ]
  }
}

resource "google_compute_url_map" "https" {
  name            = "https"
  default_service = google_compute_backend_bucket.static.id
  dynamic "host_rule" {
    for_each = toset(var.websites)
    content {
      hosts        = ["${host_rule.key}.${var.domain}"]
      path_matcher = host_rule.key
    }
  }
  dynamic "path_matcher" {
    for_each = toset(var.websites)
    content {
      name            = path_matcher.key
      default_service = google_compute_backend_bucket.static.id
      path_rule {
        paths = ["/*"]
        route_action {
          url_rewrite {
            path_prefix_rewrite = "/${path_matcher.key}/"
          }
        }
        service = google_compute_backend_bucket.static.id
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
  name             = google_compute_global_address.main.name
  url_map          = google_compute_url_map.https.id
  ssl_certificates = [google_compute_managed_ssl_certificate.main.id]
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

resource "google_compute_backend_bucket" "static" {
  name        = module.storage_bucket_static.name
  bucket_name = module.storage_bucket_static.name
  enable_cdn  = true
}

module "storage_bucket_static" {
  source        = "terraform-google-modules/cloud-storage/google//modules/simple_bucket"
  version       = "~> 6.1.0"
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

module "oidc_terraform_cloud" {
  source  = "github.com/lubeso/terraform-module-gcp-oidc.git?ref=v0"
  project = data.google_client_config.main.project
  service_account = {
    account_id   = "terraform-cloud"
    display_name = "Terraform Cloud"
    iam = {
      principal = {
        subject = {
          attribute_value = "${var.terraform_workspace_id}"
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

module "oidc_github_actions" {
  source  = "github.com/lubeso/terraform-module-gcp-oidc.git?ref=v0"
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
