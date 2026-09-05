locals {
  flattened_webhooks = merge([
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

resource "google_cloud_run_v2_service" "webhooks" {
  for_each = local.flattened_webhooks
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

resource "google_compute_region_network_endpoint_group" "webhooks" {
  for_each              = local.flattened_webhooks
  name                  = "webhook-${each.key}"
  region                = data.google_client_config.main.region
  network_endpoint_type = "SERVERLESS"
  cloud_run {
    service = google_cloud_run_v2_service.webhooks[each.key].name
  }
}

resource "google_compute_backend_service" "webhooks" {
  for_each              = local.flattened_webhooks
  name                  = "webhook-${each.key}"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  edge_security_policy  = google_compute_security_policy.cloudflare_only.id
  backend {
    group = google_compute_region_network_endpoint_group.webhooks[each.key].id
  }
}

resource "google_cloud_run_v2_service_iam_member" "webhook_invokers" {
  for_each = local.flattened_webhooks
  project  = google_cloud_run_v2_service.webhooks[each.key].project
  location = google_cloud_run_v2_service.webhooks[each.key].location
  name     = google_cloud_run_v2_service.webhooks[each.key].name
  role     = "roles/run.invoker"
  member   = "allUsers"
}
