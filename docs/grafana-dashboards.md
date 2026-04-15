# Grafana Dashboards CI/CD

Automatically validates Grafana dashboard JSON on pull requests and publishes to Grafana Cloud on merge to main.

## Quick Start

1. Create your dashboard in Grafana Cloud (or export an existing one)
2. Export it as JSON using the Grafana v2 format
3. Place it in `grafana/dashboards/{FolderName}/your-dashboard.json`
4. Open a pull request — CI validates the dashboard against Grafana's schema
5. Merge to main — CI publishes the dashboard to Grafana Cloud

## Directory Structure

```
grafana/dashboards/
  My Folder/                 # Folder name in Grafana (display name, spaces allowed)
    api-metrics.json         # Dashboard file (v2 format)
    error-rates.json
  Operations/
    on-call-overview.json
```

- The **directory name** is the Grafana folder display name. Name it exactly as you want it to appear in Grafana.
- Files must be in **exactly one subfolder** — loose files at the root or deeper nesting are rejected.
- Only `*.json` files are processed.

## Dashboard Format

All dashboards must use the **Grafana v2 resource format** (Kubernetes-style). The CI rejects v1 (classic) dashboards. See the [v2 schema documentation](https://grafana.com/docs/grafana/latest/as-code/observability-as-code/schema-v2/) and [dashboard JSON model reference](https://grafana.com/docs/grafana/latest/visualizations/dashboards/build-dashboards/view-dashboard-json-model/) for the full specification.

```json
{
  "apiVersion": "dashboard.grafana.app/v2",
  "kind": "Dashboard",
  "metadata": {
    "name": "any-placeholder"
  },
  "spec": {
    "title": "My Dashboard",
    "tags": ["my-tag"],
    "elements": { ... },
    "layout": { ... }
  }
}
```

You do not need to set `metadata.name` — CI derives it automatically. You do not need to add `github-ci-managed` or `repo:<repo-name>` tags — CI injects them.

### How to get a v2 JSON

- **From the Grafana UI:** Open a dashboard > Settings > JSON Model > Copy
- **Using grafanactl:** `grafanactl resources pull dashboards/{uid} --path ./output`
- **From scratch:** Use the [Grafana Foundation SDK](https://grafana.github.io/grafana-foundation-sdk/) to generate dashboards as code
- **Reference:** [Observability as code overview](https://grafana.com/docs/grafana/latest/as-code/observability-as-code/) and [dashboard automation guide](https://grafana.com/docs/grafana/latest/as-code/observability-as-code/foundation-sdk/dashboard-automation/)

## What CI Does

### On Pull Requests (validate)

1. Checks every `.json` file has `apiVersion: dashboard.grafana.app/v2`
2. Checks for duplicate filenames across folders
3. Preprocesses files (UID injection, tag injection, folder annotation)
4. Validates against the live Grafana instance via `grafanactl resources validate`

Validation runs against your actual Grafana Cloud instance, catching real schema errors — not just syntax checks.

### On Merge to Main (publish)

1. Same preprocessing as validate
2. Resolves target folders — finds existing Grafana folders by display name, creates new ones only if needed
3. Publishes dashboards via `grafanactl resources push`
4. Syncs orphans — deletes any `github-ci-managed` dashboard in Grafana whose source file no longer exists in the repo

## How UIDs Work

Dashboard UIDs are derived automatically as `{repo-name}-{normalized-filename}`.

For a repository called `my-service`:

| File | Derived UID |
|------|------------|
| `My Folder/api-metrics.json` | `my-service-api-metrics` |
| `My Folder/error-rates.json` | `my-service-error-rates` |
| `Operations/on-call-overview.json` | `my-service-on-call-overview` |

The folder name is **not** part of the UID. This means you can move a dashboard between folders without changing its identity or losing version history.

**Constraint:** Filenames must be unique across all folders. Having `Folder A/metrics.json` and `Folder B/metrics.json` will fail validation.

## Folder Resolution

CI matches folders by **display name**, not by UID. If a folder already exists in Grafana with the same title (regardless of its UID), CI uses it. It only creates a new folder if no folder with that exact title exists.

This means dashboards published by CI land in the same folder as manually created dashboards with the same folder name.

**Note:** Folder matching assumes unique titles at the root level. If multiple folders share the same title (e.g., a nested folder created manually), CI uses the first match returned by the API.

## Orphan Cleanup

When a dashboard file is removed from the repo and the change is merged to main, CI automatically deletes it from Grafana. This only applies to dashboards tagged `github-ci-managed` and `repo:<repo-name>`. Manually created dashboards are never touched.

**Removing all dashboard files** (or the entire `grafana/dashboards/` directory) will delete all of the repo's CI-managed dashboards from Grafana. This is intentional — the repo is the source of truth, and an empty directory means "this repo has no dashboards." Other repos' dashboards are never affected, even if they share the same Grafana instance or folder.

## Multi-Repo Safety

Multiple repositories can publish dashboards to the same Grafana instance and even the same folder:

- Dashboard UIDs include the repo name as a prefix, preventing collisions
- Each dashboard is tagged with `repo:<repo-name>`, so orphan sync only deletes dashboards belonging to the current repo
- Folder creation is idempotent

## Known Behaviors

**Renaming a file** changes the derived UID. CI will create a new dashboard and delete the old one. This means:
- The dashboard URL changes
- External links/bookmarks break
- Version history starts fresh

If you need to preserve the dashboard identity, keep the filename unchanged.

**Removing all dashboards** from the repo deletes all of this repo's CI-managed dashboards from Grafana on the next merge to main. If this is unintentional (e.g. you moved files to a different directory), restore them before merging.

**Local-only dashboards** (e.g. for docker-compose dev environments) should not be placed in `grafana/dashboards/`. Use a separate directory like `grafana/local/` to avoid CI processing them.

## Required Secrets

These must be configured as GitHub secrets (org-level or repo-level):

| Secret | Description |
|--------|-------------|
| `GRAFANA_SERVER` | Grafana instance URL |
| `GRAFANA_STACK_ID` | Grafana Cloud stack ID (e.g. `stacks-1212286`) |
| `GRAFANA_TOKEN` | Service account token with dashboard + folder permissions |

## CI Files

```
.github/
  actions/
    grafana-dashboard-setup/
      action.yml                        # Shared: install grafanactl, precheck, preprocess
  workflows/
    grafana-dashboard-validate.yml      # PR: setup + validate
    grafana-dashboard-publish.yml       # Main: setup + folders + push + sync
```

Consumer integration in your CI workflow:

```yaml
grafana-dashboard-validate:
  uses: fasttrack-solutions/ci/.github/workflows/grafana-dashboard-validate.yml@main
  secrets: inherit

grafana-dashboard-publish:
  uses: fasttrack-solutions/ci/.github/workflows/grafana-dashboard-publish.yml@main
  secrets: inherit
```
