#!/usr/bin/env bash
set -euo pipefail

##############################################################################
# Pi Code Review
#
# 1. Fetches PR metadata, comments, and review threads (with resolved status)
#    via a single GraphQL call
# 2. Generates the diff (truncated if necessary)
# 3. Builds a prompt that includes all context and tells Pi NOT to
#    duplicate any already-raised comment (resolved OR unresolved)
# 4. Runs Pi inside the repo so it can explore the full codebase
# 5. Reads the structured JSON output and posts inline PR comments
##############################################################################

OUTPUT_FILE="/tmp/pi-review.json"
PROMPT_FILE="/tmp/pi-prompt.md"
PR_DATA="/tmp/pr-data.json"

REPO="${GITHUB_REPOSITORY}"
OWNER="${REPO%%/*}"
REPO_NAME="${REPO##*/}"

MODEL="${INPUT_MODEL}"
VARIANT="${INPUT_VARIANT:-}"
MAX_DIFF_SIZE="${INPUT_MAX_DIFF_SIZE:-100000}"
CUSTOM_PROMPT="${INPUT_REVIEW_PROMPT:-}"
REVIEW_TIMEOUT="${INPUT_REVIEW_TIMEOUT:-900}"

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

5. **Structured output (write it incrementally!)** — Maintain a JSON file at
   `/tmp/pi-review.json` with this exact schema:

```json
{
  "summary": "<markdown summary of the review>",
  "verdict": "approve | request_changes",
  "complete": false,
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

   - **Write this file EARLY and rewrite it every time you confirm a new
     finding.** Always write the COMPLETE JSON object (the summary plus every
     finding so far) so the file is valid JSON at every moment. You may be
     stopped at any time, and whatever is in this file is exactly what gets
     posted — so never leave a confirmed finding only in your head.
   - `complete`: keep this `false` while you are still working. Set it to
     `true` ONLY in your final write, once the review is finished. A file left
     at `complete: false` is treated as a partial / interrupted review and will
     NOT be reported as an approval.
   - `line` / `end_line`: line numbers in the new (HEAD) version of the file.
     For single-line comments set both to the same value.
   - `verdict`: Use `approve` when the PR is mergeable — including when you
     found only minor suggestions or warnings that should not block merging.
     Use `request_changes` only for serious issues (bugs, security, correctness).
   - If there are genuinely no issues, set `findings` to `[]` AND `complete`
     to `true`. The CI pipeline reads this file.

INSTRUCTIONS

# Time budget hint (rule 6). The model can't measure elapsed time itself, so
# this only sets scope/effort — the hard `timeout` below is the real stop.
# Round up to whole minutes.
REVIEW_TIMEOUT_MIN=$(((REVIEW_TIMEOUT + 59) / 60))
cat >>"$PROMPT_FILE" <<BUDGET
6. **Time budget** — You have roughly ${REVIEW_TIMEOUT_MIN} minute(s) of
   wall-clock time before you are stopped. You cannot measure elapsed time
   yourself, so work as if time is short: triage the diff first, chase the
   highest-impact findings, and don't try to read every file exhaustively.
   Because you may be stopped at any moment, keep \`/tmp/pi-review.json\` up to
   date as you go (rule 5) — whatever is in that file when you stop is what
   gets posted.

BUDGET

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

# ── Step 5: Run Pi ───────────────────────────────────────────────────────────

echo "::group::Running Pi"

# Clean any leftover output from a previous run
rm -f "$OUTPUT_FILE"

PI_ARGS=(-p --no-context-files --model "$MODEL")

if [ -n "$VARIANT" ]; then
	PI_ARGS+=(--thinking "$VARIANT")
fi

echo "Timeout: ${REVIEW_TIMEOUT}s"

# `timeout` exits 124 on SIGTERM, 137 on SIGKILL (after --kill-after).
# Either signals a hang (commonly seen with gemini stalling on tool calls).
set +e
cat "$PROMPT_FILE" | timeout --kill-after=15s "$REVIEW_TIMEOUT" pi "${PI_ARGS[@]}" \
	2>&1 | tee /tmp/pi-stdout.txt
PIPE=("${PIPESTATUS[@]}")
set -e
PI_EXIT=${PIPE[1]:-0}

TIMED_OUT=false
if [ "$PI_EXIT" -eq 124 ] || [ "$PI_EXIT" -eq 137 ]; then
	# Don't bail — the model writes findings incrementally, so it may have left
	# a partial review on disk before being killed. Fall through and salvage it.
	TIMED_OUT=true
	echo "::warning::Pi timed out after ${REVIEW_TIMEOUT}s (model: ${MODEL}). Salvaging any partial review."
elif [ "$PI_EXIT" -ne 0 ]; then
	echo "::error::Pi exited with status ${PI_EXIT}"
	exit 1
fi

echo "::endgroup::"

# ── Step 6: Read & validate review output ────────────────────────────────────

echo "::group::Reading review output"

# A timeout can leave the file absent or (rarely) mid-write, so require valid
# JSON before trusting it.
if [ ! -f "$OUTPUT_FILE" ] || ! jq empty "$OUTPUT_FILE" >/dev/null 2>&1; then
	echo "Pi stdout was:"
	cat /tmp/pi-stdout.txt
	if [ "$TIMED_OUT" = true ]; then
		echo "::error::Pi timed out and left no valid ${OUTPUT_FILE} to salvage."
		exit 1
	fi
	echo "::warning::Pi did not produce a valid ${OUTPUT_FILE}."
	exit 0
fi

# A clean exit means the review finished. On a timeout we trust the `complete`
# flag, which the model flips to true only as its final action — anything else
# is a partial review and must not be reported as a clean pass.
if [ "$TIMED_OUT" = true ]; then
	IS_COMPLETE=$(jq -r 'if .complete == true then "true" else "false" end' "$OUTPUT_FILE")
else
	IS_COMPLETE=true
fi

if [ "$IS_COMPLETE" != "true" ]; then
	echo "::warning::Partial review — Pi was interrupted before finishing. Posting findings gathered so far."
fi

echo "::endgroup::"

# ── Step 7: Post inline comments ────────────────────────────────────────────

echo "::group::Posting review comments"

FINDINGS_COUNT=$(jq '.findings | length' "$OUTPUT_FILE")
echo "Findings: ${FINDINGS_COUNT}"

COMMIT_SHAS=$(git log --format='`%h`' "${PR_BASE_SHA}..${PR_HEAD_SHA}" | paste -sd ',' - | sed 's/,/, /g')

FAILED_COMMENTS=""

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

${F_BODY}

---
<sub>Was this helpful? React with 👍 or 👎</sub>
<!-- pi-review-model: ${MODEL} -->"

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
		FAILED_COMMENTS="${FAILED_COMMENTS}
### ${SEV_ICON} \`${F_PATH}:${F_LINE}\` — ${F_TITLE}

${F_BODY}
"
	fi
done

# Post failed inline comments as a general PR comment
if [ -n "$FAILED_COMMENTS" ]; then
	echo "Posting fallback comment for findings that could not be placed inline…"
	SUMMARY_BODY="## Code review findings (outside diff context)

The following findings could not be posted as inline comments because the referenced lines are outside the diff:
${FAILED_COMMENTS}"

	gh api \
		"repos/${REPO}/issues/${PR_NUMBER}/comments" \
		-f body="$SUMMARY_BODY"
fi

# ── Final summary ────────────────────────────────────────────────────────────
#
# Order matters: a partial (timed-out) review must never post an all-clear, so
# the incomplete case is checked before the zero-findings LGTM.
if [ "$IS_COMPLETE" != "true" ]; then
	echo "Partial review — posting interrupted-review notice (no LGTM)."
	gh api \
		"repos/${REPO}/issues/${PR_NUMBER}/comments" \
		-f body="⏱️ **Partial review** — Pi ran out of time (${REVIEW_TIMEOUT}s) and was stopped before finishing. The ${FINDINGS_COUNT} finding(s) above are what it gathered so far; the review is **incomplete**, so treat the absence of further comments as unknown, not as approval. Reviewed commits ${COMMIT_SHAS}."
elif [ "$FINDINGS_COUNT" -eq 0 ]; then
	echo "No issues found — posting LGTM."

	STATS_URL=$(gh api \
		"repos/${REPO}/issues?labels=pi-review-stats&state=open&per_page=1" \
		--jq '.[0].html_url // ""' 2>/dev/null || echo "")

	LGTM_BODY="LGTM 👍 — reviewed commits ${COMMIT_SHAS}.

React 👍 / 👎 on each of Pi's review comments."
	if [ -n "$STATS_URL" ]; then
		LGTM_BODY="${LGTM_BODY} [See live model stats](${STATS_URL})."
	fi

	gh api \
		"repos/${REPO}/issues/${PR_NUMBER}/comments" \
		-f body="$LGTM_BODY"
else
	# Findings exist but the PR is still mergeable (verdict != request_changes).
	VERDICT=$(jq -r '.verdict // "approve"' "$OUTPUT_FILE")
	if [ "$VERDICT" != "request_changes" ]; then
		echo "Verdict '${VERDICT}' — PR is mergeable, posting LGTM."
		gh api \
			"repos/${REPO}/issues/${PR_NUMBER}/comments" \
			-f body="LGTM 👍 — reviewed commits ${COMMIT_SHAS}. Some minor suggestions were posted but nothing blocking."
	fi
fi

echo "::endgroup::"

# A partial review exits non-zero so the incomplete run stays visible as a
# failed check, even though its findings were posted above. Flip this to
# `exit 0` if the review must never block merges.
if [ "$IS_COMPLETE" != "true" ]; then
	echo "Partial review posted — exiting non-zero to flag incompleteness."
	exit 1
fi

echo "Review complete."
