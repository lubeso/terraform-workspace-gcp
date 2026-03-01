terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.32.0"
    }
  }
}

provider "google" {
  # This block is purposely empty
}
