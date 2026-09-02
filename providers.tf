terraform {
  required_version = "~> 1.15.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.45.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.24.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.6.1"
    }
  }
}

provider "google" {
  # This block is purposely empty
}

provider "cloudflare" {
  # This block is purposely empty. No credentials are required: this config only reads
  # Cloudflare's public, unauthenticated IP-ranges endpoint via a data source.
}

provider "http" {
  # This block is purposely empty
}
