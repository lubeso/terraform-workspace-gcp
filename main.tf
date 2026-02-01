data "google_client_config" "main" {
  # This block is purposely empty
}

resource "google_compute_global_address" "main" {
  name = "default"
}

import {
  to = google_compute_global_address.main
  id = var.google_compute_global_address_id
}
