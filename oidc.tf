module "oidc_github_actions" {
  source  = "github.com/lubeso/terraform-module-gcp-oidc.git?ref=v1.0.0"
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

module "oidc_terraform_cloud" {
  source  = "github.com/lubeso/terraform-module-gcp-oidc.git?ref=v1.0.0"
  project = data.google_client_config.main.project
  service_account = {
    account_id   = "terraform-cloud"
    display_name = "Terraform Cloud"
    iam = {
      principal = {
        subject = {
          attribute_value = var.terraform_workspace_id
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
