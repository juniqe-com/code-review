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
echo "::endgroup::"

# ── Step 2: Aggregate per model ──────────────────────────────────────────────

echo "::group::Aggregating stats"

STATS=$(echo "$ALL_GRADES" | jq '
	group_by(.model) | map({
		model:   .[0].model,
		up:      ([.[].up]   | add),
		down:    ([.[].down] | add),
		graded:  ([.[] | select(.up > 0 or .down > 0)] | length),
		total:   length
	}) | sort_by(-.up)')

echo "$STATS" | jq -r '.[] | "  \(.model): \(.up)👍 \(.down)👎  (\(.graded)/\(.total) graded)"'
echo "::endgroup::"

# ── Step 3: Build issue body ─────────────────────────────────────────────────

HAS_DATA=$(echo "$STATS" | jq 'length > 0')
STATS_JSON_COMPACT=$(echo "$STATS" | jq -c '.')

if [ "$HAS_DATA" = "true" ]; then
	TABLE_ROWS=$(echo "$STATS" | jq -r '.[] |
		"| `" + .model + "` | " +
		(.up | tostring) + " | " +
		(.down | tostring) + " | " +
		(.graded | tostring) + " / " + (.total | tostring) + " | " +
		(if (.up + .down) > 0
		 then ((.up * 100 / (.up + .down)) | round | tostring) + "%"
		 else "—" end) +
		" |"')

	TOTAL_ALL=$(echo "$STATS" | jq '[.[].total] | add')
	TOTAL_GRADED=$(echo "$STATS" | jq '[.[].graded] | add')

	STATS_BODY="| Model | 👍 Helpful | 👎 Not Helpful | Graded / Total | Score |
|-------|-----------|----------------|----------------|-------|
${TABLE_ROWS}

> **Score** = helpful ÷ (helpful + not helpful). Based on ${TOTAL_GRADED} graded out of ${TOTAL_ALL} total review comments.

---

Each review comment posted by Pi includes a 👍 / 👎 prompt.
This issue is auto-updated by the **Pi Review Grades** workflow.
The review action reads the data block below to weight model selection by score.

_Last updated: $(date -u '+%Y-%m-%d %H:%M UTC')_

<!-- pi-review-stats-data
${STATS_JSON_COMPACT}
-->"
else
	STATS_BODY="No review comments with reactions found yet.

Once Pi starts posting review comments and authors react with 👍 or 👎,
stats will appear here automatically.

---

Each review comment posted by Pi includes a 👍 / 👎 prompt.
This issue is auto-updated by the **Pi Review Grades** workflow.

_Last updated: $(date -u '+%Y-%m-%d %H:%M UTC')_

<!-- pi-review-stats-data
[]
-->"
fi

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
