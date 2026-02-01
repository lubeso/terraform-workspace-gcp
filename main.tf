data "google_client_config" "main" {
  # This block is purposely empty
}

resource "google_compute_global_address" "main" {
  name = "default"
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

resource "google_compute_backend_bucket" "static" {
  bucket_name = module.storage_bucket_static.name
  name        = module.storage_bucket_static.name
  enable_cdn  = true
}
