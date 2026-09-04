# terraform-workspace-gcp

Terraform root module that provisions a GCP project's public-facing static
hosting infrastructure and its CI/CD trust relationships. It is applied as a
single Terraform Cloud workspace — there are no separate environment
directories in this repo.

## What this provisions

- A global HTTPS load balancer (`google_compute_global_address`, HTTP→HTTPS
  redirect, a Certificate Manager certificate covering the apex domain and
  `*.<domain>` via DNS authorization) fronting a CDN-enabled
  `google_compute_backend_bucket`. The URL map has a literal `host_rule` for
  `www.<domain>` that maps straight through to the bucket, path-for-path (no
  rewriting) — additional hostnames (under the wildcard cert, which needs no
  further changes) are added as their own `host_rule`/`path_matcher` pair.
- The load balancer only accepts traffic from Cloudflare, which proxies DNS
  for this domain: a Cloud Armor edge security policy
  (`google_compute_security_policy`, type `CLOUD_ARMOR_EDGE`) allowlists
  Cloudflare's published IP ranges (fetched live via the `cloudflare` provider's
  `cloudflare_ip_ranges` data source) on the backend bucket.
- A public static storage bucket
  (`terraform-google-modules/cloud-storage//modules/simple_bucket`) serving
  `www.<domain>` requests directly, path-for-path.
- Workload Identity Federation trust for GitHub Actions and for this
  Terraform Cloud workspace itself, via
  [`terraform-module-gcp-oidc`](https://github.com/lubeso/terraform-module-gcp-oidc).
- CD target resources for webhook handlers: an Artifact Registry Docker
  repository plus one `google_cloud_run_v2_service` per (provider, version)
  entry in `var.webhooks`, each starting out on a placeholder image. GitHub
  Actions CI (outside this repo) builds the real image with Cloud Native
  Buildpacks (`pack`) — using the service's `runtime` label to pick the
  buildpack — pushes it to the Artifact Registry repo, and deploys it onto
  the matching Cloud Run service; Terraform ignores changes to the deployed
  image so it won't fight CI.
- Each webhook Cloud Run service sits behind its own serverless
  `google_compute_region_network_endpoint_group` and
  `google_compute_backend_service` (same Cloud Armor edge policy as the
  static bucket, plus an `allUsers` `roles/run.invoker` binding since the
  service itself only accepts traffic from the load balancer). The URL map
  routes `webhooks.<domain>/<provider>/<version>` to the matching backend
  service via a literal `path_rule` per `var.webhooks` entry.

## Requirements

| Name | Version |
|------|---------|
| terraform | ~> 1.15.0 |
| google | ~> 7.45.0 |
| random | ~> 3.9.0 |
| cloudflare | ~> 5.24.0 |

## Usage

```bash
pre-commit install          # one-time
terraform init
terraform plan
```

Formatting, provider-lock, and validation are enforced via
[pre-commit](https://pre-commit.com) (`.pre-commit-config.yaml`).

## Inputs

| Name | Description | Type |
|------|-------------|------|
| `domain` | Apex domain; `www.<domain>` is served from the static bucket. | `string` |
| `webhooks` | Provider => version => config for webhook Cloud Run services, routed at `webhooks.<domain>/<provider>/<version>`. | `map(map(object({ runtime = optional(string, "go") })))` |
| `github_owner_id` | GitHub user/org ID allowed to assume the GitHub Actions service account via WIF. | `number` |
| `terraform_workspace_id` | Terraform Cloud workspace ID allowed to assume the Terraform Cloud service account via WIF. | `string` |

Real values are supplied via Terraform Cloud workspace variables or a local
`*.tfvars` file (gitignored — these values are environment-specific).

## Outputs

| Name | Description |
|------|-------------|
| `certificate_manager_dns_authorization_record` | DNS CNAME (name/type/data) that must be created manually at the external DNS provider to authorize the Certificate Manager certificate. This repo does not manage DNS records itself. |

## Manual steps

This repo does not manage Cloudflare-side configuration. In addition to the DNS authorization
record above, the following must be set in the Cloudflare dashboard for the domain:

- DNS records for `var.domain` and `www.<domain>` must be proxied (orange-clouded) through
  Cloudflare, not DNS-only — this is already assumed by the Cloud Armor IP allowlist.
