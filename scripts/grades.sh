#!/usr/bin/env bash
set -euo pipefail

##############################################################################
# Pi Code Review — Grades & Stats
#
# Scans pull-request review comments for pi-review markers, reads 👍/👎
# reactions as quality signals, aggregates per-model statistics, and
# upserts a GitHub issue (labelled pi-review-stats) with the results.
##############################################################################

REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"

# ── Step 1: Collect grades ───────────────────────────────────────────────────

echo "::group::Collecting grades from review comments"

PAGE=1
MAX_PAGES=10
ALL_GRADES="[]"

while [ "$PAGE" -le "$MAX_PAGES" ]; do
	BATCH=$(gh api \
		"repos/${REPO}/pulls/comments?per_page=100&page=${PAGE}&sort=created&direction=desc" \
		2>/dev/null || echo '[]')

	COUNT=$(echo "$BATCH" | jq 'length')

	# Extract pi-review comments: model tag + reaction counts
	PAGE_GRADES=$(echo "$BATCH" | jq '[
		.[] | select(.body | test("<!-- pi-review-model:")) |
		{
			model: (.body | capture("<!-- pi-review-model: (?<m>.+?) -->") | .m),
			up:    (.reactions["+1"]  // 0),
			down:  (.reactions["-1"]  // 0)
		}
	]')

	ALL_GRADES=$(echo "$ALL_GRADES" "$PAGE_GRADES" | jq -s '.[0] + .[1]')

	[ "$COUNT" -lt 100 ] && break
	PAGE=$((PAGE + 1))
done

TOTAL=$(echo "$ALL_GRADES" | jq 'length')
echo "Found ${TOTAL} pi-review comments"

PAGE=1
COSTS_FILE=$(mktemp)
ARCHIVE_FILE=$(mktemp)
trap 'rm -f "$COSTS_FILE" "$ARCHIVE_FILE"' EXIT
CUTOFF=$(jq -n 'now - 90 * 86400')
while :; do
	BATCH=$(gh api "repos/${REPO}/actions/artifacts?name=pi-review-cost&per_page=100&page=${PAGE}")
	COUNT=$(echo "$BATCH" | jq '.artifacts | length')
	IDS=$(echo "$BATCH" | jq -r --argjson cutoff "$CUTOFF" '
		.artifacts[] | select(.expired == false and (.created_at | fromdateiso8601) >= $cutoff) | .id')
	for ID in $IDS; do
		if ! curl -fsSL \
			-H 'Accept: application/vnd.github+json' \
			-H "Authorization: Bearer ${GITHUB_TOKEN:?GITHUB_TOKEN is required}" \
			-o "$ARCHIVE_FILE" \
			"https://api.github.com/repos/${REPO}/actions/artifacts/${ID}/zip"; then
			echo "::warning::Could not download review cost artifact ${ID}."
			continue
		fi
		if ! unzip -p "$ARCHIVE_FILE" pi-review-cost.json 2>/dev/null |
			jq -ce 'select(.model | type == "string") | select(.usd | type == "number" and . >= 0) | {model, usd}' >>"$COSTS_FILE"; then
			echo "::warning::Invalid review cost artifact ${ID}."
		fi
	done
	[ "$COUNT" -lt 100 ] && break
	PAGE=$((PAGE + 1))
done
ALL_COSTS=$(jq -s '.' "$COSTS_FILE")

echo "Found $(echo "$ALL_COSTS" | jq 'length') reviews with cost data"
echo "::endgroup::"

# ── Step 2: Aggregate per model ──────────────────────────────────────────────

echo "::group::Aggregating stats"

ACTIVE_MODELS=$(gh api "repos/${REPO}/contents/.github/workflows/pi-review.yml" \
	-H 'Accept: application/vnd.github.raw+json' | python3 "$(dirname "$0")/active-models.py")

STATS=$(jq -n --argjson grades "$ALL_GRADES" --argjson costs "$ALL_COSTS" --argjson active "$ACTIVE_MODELS" '
	(($grades | group_by(.model) | map({
		model:   .[0].model,
		up:      ([.[].up]   | add),
		down:    ([.[].down] | add),
		graded:  ([.[] | select(.up > 0 or .down > 0)] | length),
		total:   length
	})) + ($costs | group_by(.model) | map({
		model:   .[0].model,
		reviews: length,
		cost:    ([.[].usd] | add)
	})) + ($active | map({model: .}))) | group_by(.model) | map(add | . + {
		up: (.up // 0), down: (.down // 0), graded: (.graded // 0),
		total: (.total // 0), reviews: (.reviews // 0), cost: (.cost // 0)
	}) | sort_by(-.up)')

echo "$STATS" | jq -r '.[] | "  \(.model): \(.up)👍 \(.down)👎  (\(.graded)/\(.total) graded)"'
echo "::endgroup::"

# ── Step 3: Build issue body ─────────────────────────────────────────────────

ACTIVE_STATS=$(jq -n --argjson stats "$STATS" --argjson active "$ACTIVE_MODELS" '$stats | map(select(.model as $model | $active | index($model)))')
ARCHIVED_STATS=$(jq -n --argjson stats "$STATS" --argjson active "$ACTIVE_MODELS" '$stats | map(select(.model as $model | $active | index($model) | not))')
STATS_JSON_COMPACT=$(echo "$ACTIVE_STATS" | jq -c '.')

render_rows() {
	jq -r '.[] |
		"| `" + .model + "` | " +
		(.up | tostring) + " | " +
		(.down | tostring) + " | " +
		(.graded | tostring) + " / " + (.total | tostring) + " | " +
		(if (.up + .down) > 0
		 then ((.up * 100 / (.up + .down)) | round | tostring) + "%"
		 else "—" end) + " | " +
		(.reviews | tostring) + " | " +
		(if .reviews > 0 then "$" + ((.cost / .reviews * 10000 | round / 10000) | tostring)
		 else "—" end) + " |"'
}

TABLE_HEADER='| Model | 👍 Helpful | 👎 Not Helpful | Graded / Total | Score | Reviews with cost (90d) | Avg cost / review (90d) |
|-------|-----------|----------------|----------------|-------|-------------------------|-------------------------|'
TABLE_ROWS=$(echo "$ACTIVE_STATS" | render_rows)
TOTAL_ALL=$(echo "$ACTIVE_STATS" | jq '[.[].total] | add')
TOTAL_GRADED=$(echo "$ACTIVE_STATS" | jq '[.[].graded] | add')
ARCHIVED_COUNT=$(echo "$ARCHIVED_STATS" | jq 'length')
ARCHIVED_BODY=''
if [ "$ARCHIVED_COUNT" -gt 0 ]; then
	ARCHIVED_ROWS=$(echo "$ARCHIVED_STATS" | render_rows)
	ARCHIVED_BODY="<details>
<summary>Archived models (${ARCHIVED_COUNT})</summary>

${TABLE_HEADER}
${ARCHIVED_ROWS}

</details>"
fi

STATS_BODY="Models in use (from the default branch Pi review workflow):

${TABLE_HEADER}
${TABLE_ROWS}

> **Score** = helpful ÷ (helpful + not helpful). Based on ${TOTAL_GRADED} graded out of ${TOTAL_ALL} total active-model review comments.
> **Avg cost / review (90d)** = Pi-reported USD cost ÷ completed reviews with a cost artifact from the last 90 days. Artifact retention policies may shorten this window; reviews before artifact tracking and interrupted runs have no cost data.

${ARCHIVED_BODY}

---

Each review comment posted by Pi includes a 👍 / 👎 prompt.
This issue is auto-updated by the **Pi Review Grades** workflow.
The review action reads the active-model data block below to weight model selection by score.

_Last updated: $(date -u '+%Y-%m-%d %H:%M UTC')_

<!-- pi-review-stats-data
${STATS_JSON_COMPACT}
-->"

# ── Step 4: Upsert the stats issue ──────────────────────────────────────────

echo "::group::Updating stats issue"

# Ensure the label exists (ignore error if it already does)
gh api "repos/${REPO}/labels" \
	-X POST \
	-f name="pi-review-stats" \
	-f color="0075ca" \
	-f description="Auto-managed issue for Pi review statistics" \
	2>/dev/null || true

ISSUE_NUMBER=$(gh api "repos/${REPO}/issues?labels=pi-review-stats&state=open&per_page=1" \
	--jq '.[0].number // empty' 2>/dev/null || true)

if [ -n "$ISSUE_NUMBER" ]; then
	echo "Updating issue #${ISSUE_NUMBER}"
	gh api "repos/${REPO}/issues/${ISSUE_NUMBER}" \
		-X PATCH -f body="$STATS_BODY" >/dev/null
else
	echo "Creating stats issue"
	ISSUE_NUMBER=$(jq -n \
		--arg body "$STATS_BODY" \
		'{title: "📊 Pi Review — Model Performance", body: $body, labels: ["pi-review-stats"]}' |
		gh api "repos/${REPO}/issues" --input - --jq '.number')
	echo "Created issue #${ISSUE_NUMBER}"
fi

echo "::endgroup::"
echo "Stats updated → https://github.com/${REPO}/issues/${ISSUE_NUMBER}"
