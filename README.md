# terraform-workspace-gcp

Terraform root module that provisions a GCP project's public-facing static
hosting infrastructure and its CI/CD trust relationships. It is applied as a
single Terraform Cloud workspace — there are no separate environment
directories in this repo.

## What this provisions

- A global HTTPS load balancer (`google_compute_global_address`, HTTP→HTTPS
  redirect, a Google-managed SSL certificate covering `<website>.<domain>`
  for every entry in `var.websites`) fronting a CDN-enabled
  `google_compute_backend_bucket`.
- A public static storage bucket
  (`terraform-google-modules/cloud-storage//modules/simple_bucket`) serving
  each website as a hostname-routed subdirectory of the same bucket.
- Workload Identity Federation trust for GitHub Actions and for this
  Terraform Cloud workspace itself, via
  [`terraform-module-gcp-oidc`](https://github.com/lubeso/terraform-module-gcp-oidc).

## Requirements

| Name | Version |
|------|---------|
| google | ~> 7.45.0 |
| random | ~> 3.9.0 |

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
| `domain` | Apex domain that each entry in `websites` is hosted under. | `string` |
| `websites` | Website hostnames (without the domain) to serve from the static bucket. | `list(string)` |
| `github_owner_id` | GitHub user/org ID allowed to assume the GitHub Actions service account via WIF. | `number` |
| `terraform_workspace_id` | Terraform Cloud workspace ID allowed to assume the Terraform Cloud service account via WIF. | `string` |

Real values are supplied via Terraform Cloud workspace variables or a local
`*.tfvars` file (gitignored — these values are environment-specific).
