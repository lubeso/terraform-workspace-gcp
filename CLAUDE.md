# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is a single Terraform root module (`terraform-workspace-gcp`) that provisions a GCP project's
public-facing static hosting infrastructure and its CI/CD trust relationships. There are no
sub-environments or workspace directories in this repo — it is applied as one Terraform Cloud
workspace, and the workspace identity itself is a resource this config manages (see
`module.oidc_terraform_cloud` in main.tf).

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
terraform fmt -recursive
terraform validate
terraform plan
```

There is no test suite (no `.tftest.hcl` files) and no CI workflow defined in this repo.

## Architecture

Everything lives in three top-level files with no submodules of its own — `main.tf` composes
external modules instead:

- **providers.tf** — provider/version constraints only (`google ~> 5.32.0`, `random ~> 3.9.0`).
  The `provider "google"` block is intentionally empty; project/region/credentials come from the
  environment (Terraform Cloud workspace variables), not from this file.
- **variables.tf** — all inputs: `domain`, `websites` (list), `github_owner_id`, `terraform_workspace_id`.
  No defaults are set here; real values live in `.tfvars` (gitignored) or workspace variables.
- **main.tf** — three logical groups of resources:
  1. **Global HTTPS load balancer for static sites** — `google_compute_global_address`,
     `google_compute_managed_ssl_certificate` (Google-managed, one cert covering `<website>.<domain>`
     for every entry in `var.websites`), `google_compute_url_map` (https, with a `host_rule` +
     `path_matcher` pair generated per website via `dynamic` blocks) and a second url_map (http,
     unconditional redirect to https), target proxies, and global forwarding rules for ports 80/443.
  2. **Static backend bucket** — `google_compute_backend_bucket` with CDN enabled, backed by the
     `terraform-google-modules/cloud-storage//modules/simple_bucket` module (public
     `roles/storage.objectViewer` via `allUsers`, website `index.html` suffix, `force_destroy = true`).
     Each website's path matcher rewrites `/*` to `/<website>/` on the same bucket, so all sites are
     served as subdirectories of one bucket, keyed by hostname.
  3. **OIDC/Workload Identity Federation trust** — two instances of the external module
     `github.com/lubeso/terraform-module-gcp-oidc.git?ref=v0`, each creating a service account +
     WIF pool/provider:
     - `oidc_github_actions`: lets GitHub Actions in the repo owned by `var.github_owner_id`
       impersonate a service account (artifact registry, Cloud Build, Cloud Run, storage admin
       roles), restricted by `attribute_condition` to `refs/heads/main` or tag pushes.
     - `oidc_terraform_cloud`: lets the specific Terraform Cloud workspace (`var.terraform_workspace_id`)
       impersonate an `owner`-role service account, restricted by `attribute_condition` to that
       workspace ID. This is what lets Terraform Cloud runs authenticate to GCP for this same config.

When adding a new static site, add its hostname to `var.websites` — the SSL cert domains, url_map
host rules, and path matchers all derive from that list automatically; no other resource needs
editing.

## Conventions

- 2-space indent, LF line endings, 88-char line length (`.editorconfig`); `terraform fmt` enforces
  Terraform's own style on top of this.
- `*.tfvars` and `.terraform/` are gitignored — never commit real domain/project values or state.
