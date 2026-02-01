variable "domain" {
  type = string
}

variable "websites" {
  type = list(string)
}

variable "google_compute_url_map_id" {
  type = string
}
