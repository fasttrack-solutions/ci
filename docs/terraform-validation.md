# Terraform Validation CI

Validates Terraform code on pull requests using static analysis. Supports both legacy Terraform 0.11 and modern Terraform 1.x codebases. No remote state, no plans — purely offline checks.

## Quick Start

1. Identify your Terraform directories and which version each uses
2. Add the workflow calls to your repo's CI workflow (see examples below)
3. Open a pull request — CI validates your Terraform code

## Workflows

### Terraform v0 (`terraform-v0-ci.yml`)

For legacy Terraform 0.11 codebases.

| Check | What it does | Blocks PR? |
|-------|-------------|------------|
| **Format Check** | `terraform fmt -check` | No (always green) |
| **Validate** | `terraform init -backend=false` + `terraform validate -check-variables=false` | **Yes** |

### Terraform v1 (`terraform-v1-ci.yml`)

For modern Terraform 1.x codebases.

| Check | What it does | Blocks PR? |
|-------|-------------|------------|
| **Format Check** | `terraform fmt -check -recursive` | No (always green) |
| **Validate** | `terraform init -backend=false` + `terraform validate` | **Yes** |
| **TFLint** | Lints against AWS and Google rulesets | No (orange on findings) |
| **Trivy** | Scans for IaC security misconfigurations | No (orange on findings) |

All checks run in parallel. Every directory is checked even when some fail — you see all issues at once.

## Integration

Add to your repo's CI workflow file (e.g. `.github/workflows/ci.yml`):

### Repo with both v0 and v1

```yaml
jobs:
  terraform-v0:
    uses: fasttrack-solutions/ci/.github/workflows/terraform-v0-ci.yml@main
    secrets: inherit
    with:
      paths: '["deployments/oneclick/terraform"]'

  terraform-v1:
    uses: fasttrack-solutions/ci/.github/workflows/terraform-v1-ci.yml@main
    with:
      paths: '["deployments/oneclick/terraform_v1"]'
```

### Repo with multiple v1 directories

```yaml
jobs:
  terraform:
    uses: fasttrack-solutions/ci/.github/workflows/terraform-v1-ci.yml@main
    with:
      paths: '["modules/clickhouse-instance", "modules/gcp-kms-module", "modules/gcp-wip-module"]'
```

### Repo with different Terraform versions per directory group

```yaml
jobs:
  terraform-v1-default:
    uses: fasttrack-solutions/ci/.github/workflows/terraform-v1-ci.yml@main
    with:
      paths: '["modules/clickhouse-instance", "modules/gcp-kms-module"]'

  terraform-v1-custom:
    uses: fasttrack-solutions/ci/.github/workflows/terraform-v1-ci.yml@main
    with:
      paths: '["modules/cubejs", "modules/traefik"]'
      terraform_version: "1.7.0"
```

### Single directory

```yaml
jobs:
  terraform:
    uses: fasttrack-solutions/ci/.github/workflows/terraform-v1-ci.yml@main
    with:
      paths: '["infra/terraform"]'
```

## Inputs

### `terraform-v0-ci.yml`

| Input | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `paths` | string | yes | — | JSON array of paths to Terraform 0.11 directories |
| `runner` | string | no | `ubuntu-latest` | GitHub Actions runner to use |

### `terraform-v1-ci.yml`

| Input | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `paths` | string | yes | — | JSON array of paths to Terraform 1.x directories |
| `terraform_version` | string | no | `1.5.0` | Terraform version to install |
| `trivy_severity` | string | no | `HIGH,CRITICAL` | Trivy severity threshold |
| `runner` | string | no | `ubuntu-latest` | GitHub Actions runner to use |

## How It Works

### Path Input

Paths are passed as a JSON array string. Each path is relative to your repository root:

```yaml
paths: '["deployments/terraform", "modules/networking", "modules/database"]'
```

All directories in a single workflow call share the same Terraform version. If you have directories that need different versions, make separate workflow calls.

### Job Status Behavior

The CI is designed to give clear visual feedback in the GitHub Actions UI:

- **Format Check** — always green. Format issues appear in the logs but don't flag the job. Nothing is broken, just style.
- **Validate** — red on failure. This is the hard gate — your Terraform code must be syntactically valid.
- **TFLint** — orange when lint issues are found. Shows as a warning in the workflow summary without blocking merges.
- **Trivy** — orange when security findings are found. Same non-blocking visibility as TFLint.

### What Gets Checked

**Format** checks that `.tf` files follow the canonical formatting. The v1 workflow checks recursively into subdirectories; v0 only checks the top-level directory (Terraform 0.11 limitation).

**Validate** runs `terraform init -backend=false` (no remote state needed) followed by `terraform validate`. This catches syntax errors, missing required arguments, invalid resource configurations, and type mismatches. The v0 workflow uses `-check-variables=false` because 0.11 variables are provided at apply time via tfvars. The v0 validate job also builds a pinned Kubernetes Terraform provider from source (`fasttrack-solutions/terraform-provider-kubernetes`) to resolve a custom provider dependency used in legacy deployments — this requires `secrets: inherit` on the caller side for repository access.

**TFLint** (v1 only) runs the terraform, AWS, and Google linting rulesets. It catches issues like deprecated syntax, naming conventions, and provider-specific best practices. Repos not using AWS or Google providers simply won't trigger those rules.

**Trivy** (v1 only) scans for IaC security misconfigurations — exposed ports, overly permissive IAM policies, unencrypted resources, etc. Only HIGH and CRITICAL severity findings are reported by default (configurable via `trivy_severity`).

## Secrets

The v0 workflow clones a private repository (`fasttrack-solutions/terraform-provider-kubernetes`) during validation. Callers must pass `secrets: inherit` so the workflow has access to `GITHUB_TOKEN` for cross-repo cloning. The v1 workflow does not require any secrets.

## Determining Your Terraform Version

If you're unsure whether a directory uses v0 or v1:

| Indicator | v0 (0.11) | v1 (1.x) |
|-----------|-----------|----------|
| Provider version syntax | `provider "aws" { version = "2.70" }` | `required_providers { aws = { source = "..." } }` |
| Variable interpolation | `"${var.name}"` everywhere | `var.name` (no quotes needed) |
| `terraform` block | Usually absent | Present with `required_providers` |
| `-recursive` flag | Not supported | Supported |

When in doubt, try the v1 workflow first — it covers more checks and most modern Terraform code is 1.x.

## CI Files

```
.github/workflows/
  terraform-v0-ci.yml    # Reusable workflow for Terraform 0.11
  terraform-v1-ci.yml    # Reusable workflow for Terraform 1.x
```

## Deprecation

When Terraform 0.11 is fully retired from your codebases, remove the `terraform-v0-ci.yml` calls from your workflows. No changes needed to v1.
