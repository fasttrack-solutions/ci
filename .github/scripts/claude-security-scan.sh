#!/usr/bin/env bash
set -euo pipefail

# Required env vars: ANTHROPIC_API_KEY, GITHUB_TOKEN, PR_NUMBER, BASE_SHA, REPO

# Get diff of Go files only, capped at 50KB
DIFF=$(git diff "${BASE_SHA}...HEAD" -- '*.go' 2>/dev/null || echo "")
DIFF=${DIFF:0:50000}

# Read existing findings — default to empty if artifacts were not uploaded
TH_FINDINGS=$(cat trufflehog-findings.json 2>/dev/null || echo "")
SG_RESULTS=$(jq -r \
  '.results // [] | map("[\(.extra.severity)] \(.check_id): \(.path):\(.start.line)") | join("\n")' \
  semgrep-findings.json 2>/dev/null || echo "")

# Build prompt
PROMPT="You are a security reviewer analyzing a pull request diff.

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
if [ "$FINDINGS" != "NO_FINDINGS" ] && [ -n "$FINDINGS" ] && [ "$FINDINGS" != "null" ]; then
  gh pr comment "${PR_NUMBER}" \
    --repo "${REPO}" \
    --body "## Claude Security Review

> Advisory only — this does not block merge.

${FINDINGS}"
  echo "Posted Claude findings to PR #${PR_NUMBER}."
else
  echo "Claude: no net-new findings."
fi
