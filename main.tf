data "google_client_config" "main" {
  # This block is purposely empty
}

resource "google_compute_global_address" "main" {
  name = "default"
}

resource "google_compute_url_map" "main" {
  name            = google_compute_global_address.main.name
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
