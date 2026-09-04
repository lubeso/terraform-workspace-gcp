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

Everything lives in four top-level files with no submodules of its own — `main.tf` composes
external modules instead:

- **providers.tf** — provider/version constraints only (`google ~> 5.32.0`, `random ~> 3.9.0`).
  The `provider "google"` block is intentionally empty; project/region/credentials come from the
  environment (Terraform Cloud workspace variables), not from this file.
- **variables.tf** — all inputs: `domain`, `webhooks` (nested map, see below), `github_owner_id`,
  `terraform_workspace_id`.
  No defaults are set here; real values live in `.tfvars` (gitignored) or workspace variables.
- **outputs.tf** — `certificate_manager_dns_authorization_record`: the DNS CNAME (name/type/data)
  that must be created manually at the external DNS provider to authorize the Certificate Manager
  certificate below. This repo does not manage DNS records itself.
- **main.tf** — four logical groups of resources:
  1. **Global HTTPS load balancer for static sites** — `google_compute_global_address`,
     a Certificate Manager certificate map (`google_certificate_manager_dns_authorization`,
     `google_certificate_manager_certificate` — one cert covering the apex domain and `*.<domain>`,
     `google_certificate_manager_certificate_map`, and two `google_certificate_manager_certificate_map_entry`
     resources for apex and wildcard) that the target HTTPS proxy references via `certificate_map`,
     `google_compute_url_map` (https, with a literal `host_rule` + `path_matcher` for `www.<domain>`
     mapping straight through to the backend bucket — no rewrite — plus a second `host_rule` +
     `path_matcher` for `webhooks.<domain>`, whose `path_matcher` has a dynamic `path_rule` per
     `local.flattened_webhooks` entry routing `/<provider>/<version>` to that entry's
     `google_compute_backend_service`; both path_matchers fall back to the static bucket as
     `default_service`, and so does the url_map's own top-level `default_service`, which catches any
     other host) and a second url_map (http, unconditional redirect to https), target
     proxies, and global forwarding rules for ports 80/443. The classic
     `google_compute_managed_ssl_certificate` resource this LB used previously has been decommissioned;
     the DNS authorization CNAME (see outputs.tf) must still exist at the external DNS provider for the
     certificate to keep renewing. The LB only accepts traffic from Cloudflare, which proxies DNS for
     this domain: a `google_compute_security_policy` (`CLOUD_ARMOR_EDGE`) allowlists Cloudflare's IP
     ranges — fetched live via the `cloudflare` provider's `cloudflare_ip_ranges` data source, chunked
     into ≤10-CIDR rules — and is attached to the backend bucket and each webhook backend service via
     `edge_security_policy`; separately, the target HTTPS proxy's `server_tls_policy` points at a
     `google_network_security_server_tls_policy` whose `mtls_policy` (`REJECT_INVALID`) validates
     client certs against a `google_certificate_manager_trust_config` trusting Cloudflare's shared
     Authenticated Origin Pull CA, fetched at plan/apply time via a `data "http"` resource (the
     `hashicorp/http` provider) pointed at Cloudflare's published cert URL, rather than committing the
     certificate into this repo. Both the trust config and the server TLS policy's cross-service
     references are built from `data.google_project.main.number` rather than the resources' own `.id`
     (which render in project-ID form) — GCP canonicalizes these references to project-*number* form
     once live, so building them that way up front avoids a perpetual diff/force-replace. mTLS requires
     at least one real `google_compute_backend_service` on the load balancer alongside the backend
     bucket (satisfied by the webhook backend services); with only a backend bucket, attaching
     `server_tls_policy` previously failed with "ServerTlsPolicy is not available for ambiguous
     UrlMap". Enabling Authenticated Origin Pulls and Full/Full(strict) SSL mode on the Cloudflare side
     is a manual step this repo cannot perform (see README's Manual steps section).
  2. **Static backend bucket** — `google_compute_backend_bucket` with CDN enabled, backed by the
     `terraform-google-modules/cloud-storage//modules/simple_bucket` module (public
     `roles/storage.objectViewer` via `allUsers`, website `index.html` suffix, `force_destroy = true`).
     `www.<domain>` requests are served directly, path-for-path, from this bucket.
  3. **Webhook CD targets** — `local.flattened_webhooks` flattens the nested `var.webhooks` map
     (provider => version => config) into a single map keyed `"<provider>-<version>"`, since
     `for_each` can't iterate a nested map directly. One `google_artifact_registry_repository`
     (shared, format `DOCKER`) plus one `google_cloud_run_v2_service` per flattened entry is created
     from this — each service starts on a placeholder image (`ingress =
     "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"`, so it's only reachable once wired to the LB) with a
     `runtime` label (`"go"` by default, overridable e.g. to `"nodejs"`) that GitHub Actions CI reads
     to pick the Cloud Native Buildpacks (`pack`) builder when it builds and pushes the real image;
     `lifecycle { ignore_changes = [template[0].containers[0].image] }` keeps Terraform from
     reverting CI's deploys. Each service is exposed via its own serverless
     `google_compute_region_network_endpoint_group` (`cloud_run.service` pointing at the Cloud Run
     service) behind a `google_compute_backend_service` (same `edge_security_policy` Cloud Armor
     policy as the static bucket) plus a `google_cloud_run_v2_service_iam_member` granting `allUsers`
     `roles/run.invoker` — the LB is the auth boundary (via `ingress =
     "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"` on the service, so it rejects direct requests), same
     pattern as the public static bucket.
  4. **OIDC/Workload Identity Federation trust** — two instances of the external module
     `github.com/lubeso/terraform-module-gcp-oidc.git?ref=v0`, each creating a service account +
     WIF pool/provider:
     - `oidc_github_actions`: lets GitHub Actions in the repo owned by `var.github_owner_id`
       impersonate a service account (artifact registry, Cloud Build, Cloud Run, storage admin
       roles), restricted by `attribute_condition` to `refs/heads/main` or tag pushes.
     - `oidc_terraform_cloud`: lets the specific Terraform Cloud workspace (`var.terraform_workspace_id`)
       impersonate an `owner`-role service account, restricted by `attribute_condition` to that
       workspace ID. This is what lets Terraform Cloud runs authenticate to GCP for this same config.

When adding a new hostname beyond `www` and `webhooks`, add a `host_rule` (matching that hostname)
and a `path_matcher` pointing at its backend service directly in `google_compute_url_map.https`. The
wildcard Certificate Manager cert already covers any `*.<domain>` hostname, so no certificate changes
are needed. To add a new webhook provider/version instead, just add an entry to `var.webhooks` —
the Cloud Run service, serverless NEG, backend service, and `webhooks.<domain>` path_rule all derive
from `local.flattened_webhooks` automatically.

## Conventions

- 2-space indent, LF line endings, 88-char line length (`.editorconfig`); `terraform fmt` enforces
  Terraform's own style on top of this.
- `*.tfvars` and `.terraform/` are gitignored — never commit real domain/project values or state.
