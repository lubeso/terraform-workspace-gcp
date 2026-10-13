# AGENTS.md

This file provides guidance to AI coding agents when working with code in this repository.

## Overview

This is a single Terraform root module (`terraform-workspace-gcp`) that provisions a GCP project's
public-facing static hosting infrastructure and its CI/CD trust relationships. There are no
sub-environments or workspace directories in this repo — it is applied as one Terraform Cloud
workspace, and the workspace identity itself is a resource this config manages (see
`module.oidc_terraform_cloud` in oidc.tf).

## Commands

Formatting, provider-lock, and validation are enforced via pre-commit (`.pre-commit-config.yaml`),
not a separate lint script:

```bash
pre-commit install          # one-time, sets up the git hook
pre-commit run --all-files  # run all hooks (fmt, providers lock, validate, yaml/whitespace checks) on demand
```

Standard Terraform workflow:

```bash
terraform init
terraform plan
terraform apply
terraform providers lock \
  -platform=darwin_arm64 -platform=darwin_amd64 \
  -platform=linux_amd64 -platform=linux_arm64   # regenerate .terraform.lock.hcl (keep all four platforms)
```

## Structure

- **providers.tf** — `required_version ~> 1.15.0`, provider pins (`google ~> 7.45.0`,
  `random ~> 3.9.0`, `cloudflare ~> 5.24.0`), and empty provider blocks; credentials come from
  environment variables configured in the Terraform Cloud workspace.
- **variables.tf** — all inputs: `domain`, `github_owner_id`, and `terraform_workspace_id`.
- **outputs.tf** — `certificate_manager_dns_authorization_record`, project/region outputs,
  and WIF/service account identity outputs for GitHub Actions and Terraform Cloud.
- **data.tf** — `data.google_client_config.main` and `data.google_project.main`, the two data
  sources read from multiple files.
- **load_balancer.tf**, **storage.tf**, **oidc.tf** — the three logical groups of resources:
  1. **load_balancer.tf: Global HTTPS load balancer for static sites** — `google_compute_global_address`,
     a Certificate Manager certificate map (`google_certificate_manager_dns_authorization`,
     `google_certificate_manager_certificate` covering the apex domain and `*.<domain>`,
     `google_certificate_manager_certificate_map`, and two `google_certificate_manager_certificate_map_entry`
     resources for apex and wildcard), `google_compute_url_map` (https, with a literal `host_rule` +
     `path_matcher` for `www.<domain>` routing straight through to the backend bucket),
     `google_compute_url_map` (http, redirecting to https), target proxies, and global forwarding rules.
     The load balancer only accepts traffic from Cloudflare: a `google_compute_security_policy`
     (`CLOUD_ARMOR_EDGE`) allowlists Cloudflare's published IP ranges chunked into ≤10-CIDR rules.
  2. **storage.tf: Static backend bucket** — `google_compute_backend_bucket` with CDN enabled, backed by
     the `terraform-google-modules/cloud-storage//modules/simple_bucket` module. Served directly via
     Cloud CDN's "Private Bucket Access" (`google_storage_bucket_iam_member` granting
     `roles/storage.objectViewer` to GCP's load-balancer service agent).
  3. **oidc.tf: OIDC/Workload Identity Federation trust** — two instances of the external module
     `github.com/lubeso/terraform-module-gcp-oidc.git?ref=v1.1.0`:
     - `oidc_github_actions`: lets GitHub Actions in the repo owned by `var.github_owner_id`
       impersonate a service account (`storage.admin` role), restricted by `attribute_condition`
       to `refs/heads/main` or tag pushes.
     - `oidc_terraform_cloud`: lets the specific Terraform Cloud workspace (`var.terraform_workspace_id`)
       impersonate an `owner`-role service account.

When adding a new hostname beyond `www`, add a `host_rule` and `path_matcher` in
`google_compute_url_map.https`. The wildcard Certificate Manager cert already covers any
`*.<domain>` hostname.

## Conventions

- 2-space indent, LF line endings, 88-char line length (`.editorconfig`); `terraform fmt` enforces
  Terraform's own style on top of this.
- `*.tfvars` and `.terraform/` are gitignored — never commit real domain/project values or state.
