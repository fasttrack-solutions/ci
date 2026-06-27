# E2E on comment

Reusable workflow that lets developers run the full E2E suite against a service PR by commenting
**`run e2e`** on the PR. It POSTs a `repository_dispatch` (`event_type: service-pr-e2e`) to the e2e
repo, which runs both suites (pinned-commits source build + last-stable-PV ECR) with the service
swapped to the PR branch and posts the combined result back on the PR.

Workflow: [`.github/workflows/e2e-on-comment.yml`](../.github/workflows/e2e-on-comment.yml)

## Usage

Add this stub to a service repo as `.github/workflows/e2e-on-comment.yml`:

```yaml
name: Run E2E on comment
on:
  issue_comment:
    types: [created]
jobs:
  e2e:
    # Cheap pre-filter so the reusable workflow isn't invoked on every comment;
    # author/fork checks are enforced centrally in the reusable workflow.
    if: github.event.issue.pull_request && contains(github.event.comment.body, 'run e2e')
    permissions:
      issues: write
      pull-requests: write
    uses: fasttrack-solutions/ci/.github/workflows/e2e-on-comment.yml@main
    secrets: inherit
```

That is the entire per-repo footprint — all logic lives here in `ci`.

## Requirements

- **Secret `E2E_DISPATCH_TOKEN`** (org or repo): a PAT / GitHub App token authorized to POST
  `repository_dispatch` to the e2e repo. Passed through via `secrets: inherit`.
- **The stub must grant `issues: write` + `pull-requests: write`.** The org-default `GITHUB_TOKEN` is
  restricted to `contents: read`, and a reusable workflow cannot hold more token scopes than its
  caller — so the caller (stub) has to grant what this workflow needs (reacting to the comment +
  posting the acknowledgement). Omitting them makes the run fail at startup.

## Inputs

| Input | Default | Description |
|-------|---------|-------------|
| `e2e_repo` | `fasttrack-solutions/e2e` | Repo that receives the dispatch and runs the suites |
| `trigger_phrase` | `run e2e` | Comment substring that triggers a run |

## Behaviour

- Runs only on **PR** comments containing the trigger phrase, from an **OWNER / MEMBER / COLLABORATOR**.
- Reacts 👀 to the comment, resolves the PR head, **rejects fork PRs** (the e2e side fetches the branch
  from the repo's own origin), fires the dispatch with `{ service_repo, pr_number, head_ref, head_sha,
  requester }`, and posts a "🚀 triggered" acknowledgement. Final results are posted by the e2e repo.
