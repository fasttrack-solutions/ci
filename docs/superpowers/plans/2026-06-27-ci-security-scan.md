# CI Security Scan Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add TruffleHog OSS + Semgrep OSS (blocking) and a Claude advisory step (PR comment only) to `golang-security.yml` in the FastTrack CI repo so every Go PR against master is scanned for secrets, code vulnerabilities, and access-control issues.

**Architecture:** Three new jobs added to the existing `golang-security.yml` reusable workflow. TruffleHog and Semgrep run in parallel on the PR diff, each uploading a JSON findings artifact, and fail a new `security-deterministic` aggregator if either finds anything. A `claude` job runs after both, downloads their artifacts, calls the Anthropic API with the diff and existing findings, and posts a PR comment with only net-new issues — it never fails CI.

**Tech Stack:** GitHub Actions reusable workflows, TruffleHog v3 CLI (binary install), Semgrep OSS CLI (pip3), Anthropic Messages API (`claude-sonnet-4-6`), `gh` CLI for PR comments, `jq` for JSON handling.

## Global Constraints

- All new jobs run only on `pull_request` events (`if: github.event_name == 'pull_request'`). Push-to-master runs skip them — diff-based tools need a PR base SHA.
- TruffleHog: `--only-verified` flag must be set. Unverified findings are not blocked.
- Semgrep: rulesets `p/golang` and `p/secrets` only. No custom rules in this ticket.
- Claude model: `claude-sonnet-4-6`. Max response tokens: `1024`.
- Diff sent to Claude is capped at 50,000 bytes (Go files only) to stay within token limits.
- `ANTHROPIC_API_KEY` must exist as a GitHub org-level secret. Consuming repos use `secrets: inherit` so no per-repo changes are needed.
- All `actions/checkout` steps for the new jobs must use `fetch-depth: 0` — full history required for `--since-commit` and `--baseline-commit` flags.
- SHA-pin all third-party actions following the pattern already used in the file.
- The existing `security` aggregator job and its three dependencies (`govulncheck`, `gosec`, `golangci`) are not modified.

---

## File Map

| Action | Path | Responsibility |
|---|---|---|
| Modify | `.github/workflows/golang-security.yml` | Add `trufflehog`, `semgrep`, `security-deterministic`, and `claude` jobs |
| Create | `.github/scripts/claude-security-scan.sh` | Get diff, call Anthropic API, post PR comment |

---

### Task 1: TruffleHog job

**Files:**
- Modify: `.github/workflows/golang-security.yml`

**Interfaces:**
- Produces: artifact `trufflehog-findings` containing `trufflehog-findings.json` — consumed by Task 3 (Claude job). One JSON object per line (TruffleHog native format). Empty file = no findings.

- [ ] **Step 1: Check out the existing feature branch**

The feature branch `feature/sec1-107-fasttrack-ci-introduce-claude-security-scan` already exists (created when the ticket was filed). Work on that branch:

```bash
cd ~/dev/fasttrack/ci
git checkout feature/sec1-107-fasttrack-ci-introduce-claude-security-scan
git pull origin feature/sec1-107-fasttrack-ci-introduce-claude-security-scan
```

- [ ] **Step 2: Add the `trufflehog` job to `golang-security.yml`**

Open `.github/workflows/golang-security.yml`. After the closing block of the `golangci` job and before the `security:` job, insert the following. Match the indentation of the surrounding jobs (2-space indent at the job level):

```yaml
  trufflehog:
    name: trufflehog
    runs-on: ubuntu-latest
    if: github.event_name == 'pull_request'
    steps:
      - name: Checkout Source
        uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
        with:
          fetch-depth: 0

      - name: Install TruffleHog
        run: |
          curl -sSfL https://raw.githubusercontent.com/trufflesecurity/trufflehog/main/scripts/install.sh \
            | sh -s -- -b /usr/local/bin v3.88.0

      - name: Run TruffleHog
        run: |
          trufflehog git file://. \
            --since-commit="${{ github.event.pull_request.base.sha }}" \
            --only-verified \
            --json \
            --no-update \
            2>/dev/null > trufflehog-findings.json || true

      - name: Fail if verified secrets found
        run: |
          count=$(wc -l < trufflehog-findings.json)
          if [ "$count" -gt 0 ]; then
            echo "::error::TruffleHog found $count verified secret(s):"
            jq -r '"  \(.DetectorName) in \(.SourceMetadata.Data.Git.file // "unknown")"' \
              trufflehog-findings.json
            exit 1
          fi
          echo "TruffleHog: no verified secrets found."

      - name: Upload findings artifact
        if: always()
        uses: actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02 # v4.6.2
        with:
          name: trufflehog-findings
          path: trufflehog-findings.json
          retention-days: 7
```

- [ ] **Step 3: Verify the YAML is valid**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/golang-security.yml'))" && echo "YAML OK"
```

Expected: `YAML OK`

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/golang-security.yml
git commit -m "ci(sec): add TruffleHog OSS job to golang-security workflow"
```

---

### Task 2: Semgrep job + `security-deterministic` aggregator

**Files:**
- Modify: `.github/workflows/golang-security.yml`

**Interfaces:**
- Produces:
  - Artifact `semgrep-findings` containing `semgrep-findings.json` — consumed by Task 3. Shape: `{"results": [...], "errors": []}` (standard Semgrep JSON output).
  - Job results `needs.trufflehog.result` and `needs.semgrep.result` — consumed by the `security-deterministic` job added in this task.

- [ ] **Step 1: Add the `semgrep` job to `golang-security.yml`**

After the `trufflehog` job block, insert:

```yaml
  semgrep:
    name: semgrep
    runs-on: ubuntu-latest
    if: github.event_name == 'pull_request'
    steps:
      - name: Checkout Source
        uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
        with:
          fetch-depth: 0

      - name: Install Semgrep
        run: pip3 install semgrep==1.117.0

      - name: Run Semgrep
        run: |
          semgrep scan \
            --config p/golang \
            --config p/secrets \
            --json \
            --baseline-commit="${{ github.event.pull_request.base.sha }}" \
            --output semgrep-findings.json \
            . 2>/dev/null || true

      - name: Fail if findings
        run: |
          count=$(jq '.results | length' semgrep-findings.json)
          if [ "$count" -gt 0 ]; then
            echo "::error::Semgrep found $count issue(s):"
            jq -r '.results[] | "  [\(.extra.severity)] \(.check_id): \(.path):\(.start.line)"' \
              semgrep-findings.json
            exit 1
          fi
          echo "Semgrep: no findings."

      - name: Upload findings artifact
        if: always()
        uses: actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02 # v4.6.2
        with:
          name: semgrep-findings
          path: semgrep-findings.json
          retention-days: 7
```

- [ ] **Step 2: Add the `security-deterministic` aggregator job**

After the `semgrep` job block and before the existing `security:` job, insert:

```yaml
  security-deterministic:
    name: security-deterministic
    runs-on: ubuntu-latest
    needs: [trufflehog, semgrep]
    if: always()
    steps:
      - name: Check deterministic security jobs
        run: |
          th="${{ needs.trufflehog.result }}"
          sg="${{ needs.semgrep.result }}"
          echo "trufflehog: $th  semgrep: $sg"
          for result in "$th" "$sg"; do
            if [[ "$result" != "success" && "$result" != "skipped" ]]; then
              echo "::error::Deterministic security check failed (trufflehog=$th semgrep=$sg)"
              exit 1
            fi
          done
          echo "All deterministic security checks passed."
```

- [ ] **Step 3: Verify the YAML is valid**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/golang-security.yml'))" && echo "YAML OK"
```

Expected: `YAML OK`

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/golang-security.yml
git commit -m "ci(sec): add Semgrep job and security-deterministic aggregator"
```

---

### Task 3: Claude advisory job

**Files:**
- Create: `.github/scripts/claude-security-scan.sh`
- Modify: `.github/workflows/golang-security.yml`

**Interfaces:**
- Consumes:
  - Artifact `trufflehog-findings` (Task 1): `trufflehog-findings.json` — one JSON object per line or empty
  - Artifact `semgrep-findings` (Task 2): `semgrep-findings.json` — `{"results": [...]}`
  - Env vars in the script: `ANTHROPIC_API_KEY`, `GITHUB_TOKEN`, `PR_NUMBER`, `BASE_SHA`, `REPO`
- Produces: a PR comment via `gh pr comment` — only posted when Claude finds net-new issues. No artifact.

- [ ] **Step 1: Create the script directory and file**

```bash
mkdir -p .github/scripts
```

Create `.github/scripts/claude-security-scan.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Required env vars: ANTHROPIC_API_KEY, GITHUB_TOKEN, PR_NUMBER, BASE_SHA, REPO

# Get diff of Go files only, capped at 50KB
DIFF=$(git diff "${BASE_SHA}...HEAD" -- '*.go' 2>/dev/null | head -c 50000 || echo "(diff unavailable)")

# Read existing findings — default to empty if artifacts were not uploaded
TH_FINDINGS=$(cat trufflehog-findings.json 2>/dev/null || echo "")
SG_RESULTS=$(jq -r \
  '.results // [] | map("[\(.extra.severity)] \(.check_id): \(.path):\(.start.line)") | join("\n")' \
  semgrep-findings.json 2>/dev/null || echo "")

# Build prompt
PROMPT="You are a security reviewer analyzing a Go pull request diff.

The following issues were already found by automated scanners. Do NOT repeat them.

TruffleHog (verified secrets already flagged):
${TH_FINDINGS:-none}

Semgrep (code patterns already flagged):
${SG_RESULTS:-none}

Review the diff below for security issues those tools would NOT catch:
- Access control gaps: missing auth checks, cross-tenant IDOR, unauthenticated endpoints
- Logic flaws: authorization bypasses, missing ownership checks before mutations
- Weak defaults: env var fallbacks with placeholder values (e.g. getEnv(\"KEY\", \"abc123\") where the default is a non-empty placeholder rather than a real secret)
- Leaked internals: SQL errors, stack traces, or internal paths returned in API responses

If you find no issues, respond with exactly the text: NO_FINDINGS

Otherwise respond with a markdown list. Each finding must include:
- Severity: HIGH / MEDIUM / LOW
- File and approximate line if identifiable from the diff
- What the issue is and why it matters

Diff:
\`\`\`diff
${DIFF}
\`\`\`"

# Call Claude API — build JSON payload with jq to safely handle special characters
RESPONSE=$(jq -n \
  --arg content "$PROMPT" \
  '{model:"claude-sonnet-4-6",max_tokens:1024,messages:[{role:"user",content:$content}]}' \
  | curl -sf https://api.anthropic.com/v1/messages \
    -H "x-api-key: ${ANTHROPIC_API_KEY}" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    -d @-)

FINDINGS=$(echo "$RESPONSE" | jq -r '.content[0].text')

# Post comment only if findings exist
if [ "$FINDINGS" != "NO_FINDINGS" ] && [ -n "$FINDINGS" ]; then
  gh pr comment "${PR_NUMBER}" \
    --repo "${REPO}" \
    --body "## Claude Security Review

> Advisory only — this does not block merge.

${FINDINGS}"
  echo "Posted Claude findings to PR #${PR_NUMBER}."
else
  echo "Claude: no net-new findings."
fi
```

- [ ] **Step 2: Make the script executable**

```bash
chmod +x .github/scripts/claude-security-scan.sh
```

- [ ] **Step 3: Add the `claude` job to `golang-security.yml`**

After the `security-deterministic` job block and before the existing `security:` job, insert:

```yaml
  claude:
    name: claude-advisory
    runs-on: ubuntu-latest
    needs: [trufflehog, semgrep]
    if: always() && github.event_name == 'pull_request'
    permissions:
      pull-requests: write
    steps:
      - name: Checkout Source
        uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
        with:
          fetch-depth: 0

      - name: Download TruffleHog findings
        uses: actions/download-artifact@95815c38cf2ff2164869cbab79da8d1f422bc89e # v4.2.1
        with:
          name: trufflehog-findings
        continue-on-error: true

      - name: Download Semgrep findings
        uses: actions/download-artifact@95815c38cf2ff2164869cbab79da8d1f422bc89e # v4.2.1
        with:
          name: semgrep-findings
        continue-on-error: true

      - name: Run Claude security scan
        env:
          ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          PR_NUMBER: ${{ github.event.pull_request.number }}
          BASE_SHA: ${{ github.event.pull_request.base.sha }}
          REPO: ${{ github.repository }}
        run: bash .github/scripts/claude-security-scan.sh
```

- [ ] **Step 4: Verify the YAML is valid**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/golang-security.yml'))" && echo "YAML OK"
```

Expected: `YAML OK`

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/golang-security.yml .github/scripts/claude-security-scan.sh
git commit -m "ci(sec): add Claude advisory security scan job"
```

- [ ] **Step 6: Push and open a PR in the CI repo**

```bash
git push -u origin feature/sec1-107-fasttrack-ci-introduce-claude-security-scan

gh pr create \
  --title "ci(sec): SEC1-107 — TruffleHog + Semgrep + Claude advisory scan" \
  --body "$(cat <<'EOF'
## Summary

- **TruffleHog OSS** — scans PR diff for verified secrets (blocking)
- **Semgrep OSS** — scans PR diff for code vulnerabilities via `p/golang` + `p/secrets` (blocking)
- **security-deterministic** aggregator — fails CI if either tool finds anything
- **Claude advisory** — reads both findings, posts PR comment with net-new access-control/logic issues (never blocks)

Design spec: `docs/superpowers/specs/2026-06-27-ci-security-scan-design.md`

## Prerequisites

- [ ] `ANTHROPIC_API_KEY` added as GitHub org-level secret by an org admin

## Test plan

- [ ] Validate on rewards-backend by pointing its `go-security.yml` at this branch (see plan Task 4)

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

### Task 4: End-to-end validation on rewards-backend

**Files:**
- Modify (temporarily, on a throwaway branch): `~/dev/fasttrack/rewards-backend/.github/workflows/go-security.yml`

**Interfaces:**
- Consumes: the CI feature branch from Task 3
- Produces: nothing permanent — all changes are reverted after validation

- [ ] **Step 1: Create a validation branch in rewards-backend**

```bash
cd ~/dev/fasttrack/rewards-backend
git checkout main && git pull
git checkout -b test/sec1-107-ci-scan-validation
```

- [ ] **Step 2: Point the workflow at the CI feature branch**

In `~/dev/fasttrack/rewards-backend/.github/workflows/go-security.yml`, change line 32 from:

```yaml
uses: fasttrack-solutions/ci/.github/workflows/golang-security.yml@main
```

to:

```yaml
uses: fasttrack-solutions/ci/.github/workflows/golang-security.yml@feature/sec1-107-fasttrack-ci-introduce-claude-security-scan
```

- [ ] **Step 3: Make a trivial Go change so the diff is non-empty**

```bash
echo "// sec1-107 ci scan validation" >> internal/models/bonus.go
```

- [ ] **Step 4: Commit and push**

```bash
git add .github/workflows/go-security.yml internal/models/bonus.go
git commit -m "test: validate SEC1-107 CI security scan (will not merge)"
git push -u origin test/sec1-107-ci-scan-validation
```

- [ ] **Step 5: Open a draft PR**

```bash
gh pr create \
  --title "test: SEC1-107 CI security scan validation" \
  --body "Temporary PR to validate new CI security scan jobs. Will be closed without merging." \
  --draft
```

- [ ] **Step 6: Confirm all four new jobs appear in the Checks tab**

```bash
# Poll until the run completes (or check in the GitHub UI)
gh pr checks --watch
```

Confirm:
- `trufflehog` — passes (trivial comment addition contains no secrets)
- `semgrep` — passes (trivial change has no findings)
- `security-deterministic` — passes
- `claude-advisory` — passes and either posts a comment or logs "no net-new findings"

If `claude-advisory` fails with HTTP 401: the `ANTHROPIC_API_KEY` org secret has not been added yet. Note it as a prerequisite and skip that job for now — the deterministic layer still provides value.

- [ ] **Step 7: Close the test PR and delete the branch**

```bash
gh pr close --delete-branch
```

- [ ] **Step 8: Confirm rewards-backend main is unchanged**

```bash
cd ~/dev/fasttrack/rewards-backend
git checkout main
grep "golang-security.yml" .github/workflows/go-security.yml
```

Expected: `uses: fasttrack-solutions/ci/.github/workflows/golang-security.yml@main`

- [ ] **Step 9: Mark the CI PR ready for review**

```bash
cd ~/dev/fasttrack/ci
gh pr ready
```

Once merged to `main` in the CI repo, all Go repos pick up the new jobs automatically on their next PR. No per-repo changes required.
