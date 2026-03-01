terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.21.0"
    }
  }
}

provider "google" {
  # This block is purposely empty
}
