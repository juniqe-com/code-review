#!/usr/bin/env bash
set -euo pipefail

##############################################################################
# OpenCode Code Review
#
# 1. Fetches PR metadata, comments, and review threads (with resolved status)
#    via a single GraphQL call
# 2. Generates the diff (truncated if necessary)
# 3. Builds a prompt that includes all context and tells OpenCode NOT to
#    duplicate any already-raised comment (resolved OR unresolved)
# 4. Runs OpenCode inside the repo so it can explore the full codebase
# 5. Reads the structured JSON output and posts inline PR comments
# 6. Optionally posts an overall summary comment
##############################################################################

OUTPUT_FILE="/tmp/opencode-review.json"
PROMPT_FILE="/tmp/opencode-prompt.md"
PR_DATA="/tmp/pr-data.json"

REPO="${GITHUB_REPOSITORY}"
OWNER="${REPO%%/*}"
REPO_NAME="${REPO##*/}"

MODEL="${INPUT_MODEL}"
MAX_DIFF_SIZE="${INPUT_MAX_DIFF_SIZE:-100000}"
POST_SUMMARY="${INPUT_POST_SUMMARY:-true}"
CUSTOM_PROMPT="${INPUT_REVIEW_PROMPT:-}"

# ── Step 1: Fetch PR context via GraphQL ─────────────────────────────────────

echo "::group::Fetching PR context"

gh api graphql -f query='
query($owner: String!, $repo: String!, $pr: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $pr) {
      title
      body
      author { login }
      baseRefName
      headRefName
      comments(first: 100, orderBy: {field: UPDATED_AT, direction: ASC}) {
        nodes {
          author { login }
          body
          createdAt
        }
      }
      reviewThreads(first: 100) {
        nodes {
          isResolved
          isOutdated
          path
          line
          startLine
          comments(first: 20) {
            nodes {
              author { login }
              body
              createdAt
            }
          }
        }
      }
    }
  }
}' -f owner="$OWNER" -f repo="$REPO_NAME" -F pr="$PR_NUMBER" >"$PR_DATA"

PR_TITLE=$(jq -r '.data.repository.pullRequest.title' "$PR_DATA")
PR_BODY=$(jq -r '.data.repository.pullRequest.body // "No description provided."' "$PR_DATA")
PR_AUTHOR=$(jq -r '.data.repository.pullRequest.author.login' "$PR_DATA")

echo "PR #${PR_NUMBER}: ${PR_TITLE} by @${PR_AUTHOR}"
echo "::endgroup::"

# ── Step 2: Generate diff ────────────────────────────────────────────────────

echo "::group::Generating diff"

# Make sure both refs are available locally
git fetch --no-tags --quiet origin \
	"${PR_BASE_REF}" \
	"+refs/pull/${PR_NUMBER}/head" 2>/dev/null || true

DIFF=$(git diff --unified=5 "${PR_BASE_SHA}...${PR_HEAD_SHA}" 2>/dev/null ||
	git diff --unified=5 "origin/${PR_BASE_REF}...HEAD")

DIFF_SIZE=${#DIFF}
TRUNCATED=""
if [ "$DIFF_SIZE" -gt "$MAX_DIFF_SIZE" ]; then
	TRUNCATED="
> **Note**: The diff was truncated from ${DIFF_SIZE} to ${MAX_DIFF_SIZE} bytes.
> Use your file-reading tools to inspect the full content of any file."
	DIFF="${DIFF:0:$MAX_DIFF_SIZE}"
fi

echo "Diff size: ${DIFF_SIZE} bytes"
echo "::endgroup::"

# ── Step 3: Format existing comments ────────────────────────────────────────

echo "::group::Formatting existing comments"

# Issue-level (conversation) comments
ISSUE_COMMENTS=$(jq -r '
  [.data.repository.pullRequest.comments.nodes[] |
   "- **@\(.author.login)** (\(.createdAt)):\n  \(.body | split("\n") | join("\n  "))"]
  | if length == 0 then "None." else join("\n\n") end
' "$PR_DATA")

# Review threads — each one tagged RESOLVED / UNRESOLVED
REVIEW_THREADS=$(jq -r '
  [.data.repository.pullRequest.reviewThreads.nodes[] |
   . as $t |
   "### [\(if $t.isResolved then "RESOLVED" else "UNRESOLVED" end)] `\($t.path)`" +
   (if $t.line then " line \($t.line)" else "" end) +
   (if $t.startLine and $t.line and ($t.startLine != $t.line)
      then " (lines \($t.startLine)-\($t.line))" else "" end) +
   "\n" +
   ([$t.comments.nodes[] |
     "> **@\(.author.login)**: \(.body | split("\n") | join("\n> "))"] | join("\n"))]
  | if length == 0 then "None." else join("\n\n") end
' "$PR_DATA")

echo "::endgroup::"

# ── Step 4: Build the prompt ─────────────────────────────────────────────────

echo "::group::Building prompt"

cat >"$PROMPT_FILE" <<'INSTRUCTIONS'
You are a senior code reviewer. Your job is to review the pull request below.

## Rules

1. **Full codebase access** — You are running inside the repository. Use your
   file-reading tools to look at ANY file you need for context (imports,
   callers, tests, configs, etc.). Do NOT limit yourself to the diff.

2. **Do NOT duplicate existing comments** — The section "Existing review
   threads" lists every comment already posted on this PR, tagged as either
   RESOLVED or UNRESOLVED.
   - **RESOLVED** threads: the issue was raised and fixed. Do not mention it.
   - **UNRESOLVED** threads: the issue was already raised and is still open.
     Do not raise it again.
   Only raise **new** issues that have not been mentioned in any thread.

3. **Focus on what matters** — Prioritize correctness, security, performance,
   and maintainability bugs introduced by this PR. Avoid nitpicks and style
   preferences unless they cause real problems.

4. **Be precise** — Every finding must reference the exact file path (relative
   to the repo root) and line number(s) in the HEAD version of the file. If
   you are unsure, read the file first.

5. **Structured output** — After your analysis, write a JSON file to
   `/tmp/opencode-review.json` with this exact schema:

```json
{
  "summary": "<markdown summary of the review>",
  "verdict": "approve | request_changes | comment",
  "findings": [
    {
      "path": "relative/path/to/file",
      "line": 42,
      "end_line": 42,
      "severity": "error | warning | suggestion",
      "title": "Short title (max 80 chars)",
      "body": "Detailed explanation in markdown"
    }
  ]
}
```

   - `line` / `end_line`: line numbers in the new (HEAD) version of the file.
     For single-line comments set both to the same value.
   - If there are no findings, set `findings` to an empty array `[]`.
   - You MUST write this file as your final action. The CI pipeline reads it.

INSTRUCTIONS

# Append custom instructions if provided
if [ -n "$CUSTOM_PROMPT" ]; then
	cat >>"$PROMPT_FILE" <<CUSTOM
## Additional review instructions

${CUSTOM_PROMPT}

CUSTOM
fi

# Append dynamic PR context
cat >>"$PROMPT_FILE" <<CONTEXT
---

## Pull Request

- **Title**: ${PR_TITLE}
- **Author**: @${PR_AUTHOR}
- **PR**: #${PR_NUMBER}
- **Base**: \`${PR_BASE_REF}\` (${PR_BASE_SHA:0:8})
- **Head**: ${PR_HEAD_SHA:0:8}

### Description

${PR_BODY}

---

## Conversation comments

${ISSUE_COMMENTS}

---

## Existing review threads

${REVIEW_THREADS}

---

## Diff
${TRUNCATED}

\`\`\`diff
${DIFF}
\`\`\`
CONTEXT

PROMPT_SIZE=$(wc -c <"$PROMPT_FILE" | tr -d ' ')
echo "Prompt built: ${PROMPT_SIZE} bytes"
echo "::endgroup::"

# ── Step 5: Run OpenCode ────────────────────────────────────────────────────

echo "::group::Running OpenCode"

# Clean any leftover output from a previous run
rm -f "$OUTPUT_FILE"

opencode run \
	--model "$MODEL" \
	"$(cat "$PROMPT_FILE")" \
	>/tmp/opencode-stdout.txt 2>&1 || {
	echo "::error::OpenCode exited with a non-zero status"
	cat /tmp/opencode-stdout.txt >&2
	exit 1
}

echo "::endgroup::"

# ── Step 6: Post inline comments ────────────────────────────────────────────

echo "::group::Posting review comments"

if [ ! -f "$OUTPUT_FILE" ]; then
	echo "::warning::OpenCode did not produce ${OUTPUT_FILE}."
	echo "OpenCode stdout was:"
	cat /tmp/opencode-stdout.txt
	gh api "repos/${REPO}/issues/${PR_NUMBER}/comments" \
		-f body="**OpenCode Review**: The review completed but no structured output was produced. Check the Actions log for details." \
		>/dev/null
	exit 0
fi

FINDINGS_COUNT=$(jq '.findings | length' "$OUTPUT_FILE")
echo "Findings: ${FINDINGS_COUNT}"

FAILED_INLINE=""

for i in $(seq 0 $((FINDINGS_COUNT - 1))); do
	FINDING=$(jq -c ".findings[$i]" "$OUTPUT_FILE")

	F_PATH=$(echo "$FINDING" | jq -r '.path')
	F_LINE=$(echo "$FINDING" | jq -r '.end_line // .line')
	F_START=$(echo "$FINDING" | jq -r 'if .line != .end_line then .line else empty end')
	F_SEV=$(echo "$FINDING" | jq -r '.severity // "suggestion"')
	F_TITLE=$(echo "$FINDING" | jq -r '.title')
	F_BODY=$(echo "$FINDING" | jq -r '.body')

	# Severity emoji
	case "$F_SEV" in
	error) SEV_ICON="🔴" ;;
	warning) SEV_ICON="🟡" ;;
	suggestion) SEV_ICON="🔵" ;;
	*) SEV_ICON="💬" ;;
	esac

	COMMENT_BODY="${SEV_ICON} **${F_TITLE}**

${F_BODY}"

	# Build the API payload
	PAYLOAD=$(jq -n \
		--arg body "$COMMENT_BODY" \
		--arg commit_id "$PR_HEAD_SHA" \
		--arg path "$F_PATH" \
		--argjson line "$F_LINE" \
		'{body: $body, commit_id: $commit_id, path: $path, line: $line, side: "RIGHT"}')

	# Multi-line range
	if [ -n "$F_START" ]; then
		PAYLOAD=$(echo "$PAYLOAD" | jq \
			--argjson sl "$F_START" \
			'. + {start_line: $sl, start_side: "RIGHT"}')
	fi

	# Try to post as inline comment; if the line isn't in the diff GitHub
	# returns 422, so we collect those for the summary instead.
	HTTP_CODE=$(curl -s -o /tmp/gh-response.json -w '%{http_code}' \
		-X POST \
		-H "Accept: application/vnd.github+json" \
		-H "Authorization: Bearer ${GITHUB_TOKEN}" \
		-H "X-GitHub-Api-Version: 2022-11-28" \
		"https://api.github.com/repos/${REPO}/pulls/${PR_NUMBER}/comments" \
		-d "$PAYLOAD")

	if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
		echo "  ✓ ${F_PATH}:${F_LINE} — ${F_TITLE}"
	else
		echo "  ✗ ${F_PATH}:${F_LINE} — could not post inline (HTTP ${HTTP_CODE})"
		FAILED_INLINE+="| \`${F_PATH}:${F_LINE}\` | ${SEV_ICON} ${F_SEV} | ${F_TITLE} |
"
	fi
done

echo "::endgroup::"

# ── Step 7: Post summary comment ────────────────────────────────────────────

if [ "$POST_SUMMARY" = "true" ]; then
	echo "::group::Posting summary"

	SUMMARY=$(jq -r '.summary // "No summary."' "$OUTPUT_FILE")
	VERDICT=$(jq -r '.verdict // "comment"' "$OUTPUT_FILE")

	# Verdict badge
	case "$VERDICT" in
	approve) VERDICT_BADGE="✅ **Approve**" ;;
	request_changes) VERDICT_BADGE="❌ **Changes requested**" ;;
	*) VERDICT_BADGE="💬 **Comment**" ;;
	esac

	BODY="## OpenCode Review

${VERDICT_BADGE}

${SUMMARY}
"

	if [ -n "$FAILED_INLINE" ]; then
		BODY+="
### Findings outside the diff

These could not be posted as inline comments because the lines are not part of the diff.

| Location | Severity | Issue |
|----------|----------|-------|
${FAILED_INLINE}
"
	fi

	BODY+="
---
<sub>Reviewed by <a href=\"https://opencode.ai\">OpenCode</a> · model \`${MODEL}\`</sub>"

	gh api "repos/${REPO}/issues/${PR_NUMBER}/comments" \
		-f body="$BODY" >/dev/null

	echo "::endgroup::"
fi

echo "Review complete."
