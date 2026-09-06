resource "google_compute_backend_bucket" "static" {
  name                 = module.storage_bucket_static.name
  bucket_name          = module.storage_bucket_static.name
  enable_cdn           = true
  edge_security_policy = google_compute_security_policy.cloudflare_only.id
}

resource "random_id" "signed_url_key" {
  byte_length = 16
}

resource "google_compute_backend_bucket_signed_url_key" "static" {
  name           = "static-signed-url-key"
  key_value      = random_id.signed_url_key.b64_url
  backend_bucket = google_compute_backend_bucket.static.name
}

module "storage_bucket_static" {
  source                   = "terraform-google-modules/cloud-storage/google//modules/simple_bucket"
  version                  = "~> 12.3.0"
  name                     = "static-${data.google_client_config.main.project}"
  location                 = data.google_client_config.main.region
  project_id               = data.google_client_config.main.project
  force_destroy            = true
  storage_class            = "STANDARD"
  versioning               = false
  bucket_policy_only       = true
  public_access_prevention = "enforced"
  website = {
    main_page_suffix = "index.html"
  }
}

# The bucket has no public IAM grants (public_access_prevention = "enforced" above), so the load
# balancer's backend bucket reads objects via Cloud CDN's "Private Bucket Access": a grant to
# GCP's dedicated load-balancer cache-fill service agent instead of allUsers. This identity is
# only meaningful once a backend bucket exists in the project, hence the explicit depends_on.
resource "google_storage_bucket_iam_member" "static_lb_reader" {
  bucket     = module.storage_bucket_static.name
  role       = "roles/storage.objectViewer"
  member     = "serviceAccount:service-${data.google_project.main.number}@https-lb.iam.gserviceaccount.com"
  depends_on = [google_compute_backend_bucket.static]
}
