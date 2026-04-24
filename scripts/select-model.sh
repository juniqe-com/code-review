#!/usr/bin/env bash
set -euo pipefail

##############################################################################
# Pi Code Review — Model Selection
#
# Picks a model from the configured candidates. When `models` is a list,
# selection is weighted by each model's 👍/👎 score from the Pi Review Grades
# issue, so higher-scoring models get more volume on average.
#
# Scoring uses Bayesian shrinkage so that untested models get a neutral
# weight and noisy small-sample rates are pulled toward 50%.
#
#   weight = round( (up + α) / (up + down + 2α) · 100 )        α = 2
#
# Every weight is floored at 10 so no model is ever fully excluded — we
# always keep a bit of exploration even for a model with a terrible score.
#
# If the grades issue is missing or unreadable (e.g. the workflow lacks
# `issues: read`), every candidate gets the neutral weight and the result
# is indistinguishable from uniform random selection.
##############################################################################

MODELS_CSV="${INPUT_MODELS:-}"
SINGLE="${INPUT_MODEL:-}"

if [ -n "$MODELS_CSV" ]; then
	IFS=',' read -ra CANDIDATES <<<"$MODELS_CSV"
elif [ -n "$SINGLE" ]; then
	CANDIDATES=("$SINGLE")
else
	echo "::error::Either 'model' or 'models' input must be provided."
	exit 1
fi

TRIMMED=()
for m in "${CANDIDATES[@]}"; do
	t="$(echo "$m" | xargs)"
	[ -n "$t" ] && TRIMMED+=("$t")
done

if [ "${#TRIMMED[@]}" -eq 0 ]; then
	echo "::error::No valid models found in input."
	exit 1
fi

# Fast path: nothing to weight with a single candidate.
if [ "${#TRIMMED[@]}" -eq 1 ]; then
	SELECTED="${TRIMMED[0]}"
	echo "model=${SELECTED}" >>"$GITHUB_OUTPUT"
	echo "::notice::Selected model: ${SELECTED}"
	exit 0
fi

# ── Step 1: Fetch stats from the grades issue (best effort) ─────────────────

STATS_JSON="[]"
ISSUE_BODY=$(gh api \
	"repos/${GITHUB_REPOSITORY}/issues?labels=pi-review-stats&state=open&per_page=1" \
	--jq '.[0].body // ""' 2>/dev/null || echo "")

if [ -n "$ISSUE_BODY" ]; then
	EXTRACTED=$(awk '
		/<!-- pi-review-stats-data/ { flag = 1; next }
		/-->/ && flag            { exit }
		flag                     { print }
	' <<<"$ISSUE_BODY")

	if [ -n "$EXTRACTED" ] && echo "$EXTRACTED" | jq -e '.' >/dev/null 2>&1; then
		STATS_JSON="$EXTRACTED"
	fi
fi

# ── Step 2: Compute a weight per candidate ──────────────────────────────────

ALPHA=2
FLOOR=10

WEIGHTS=()
TOTAL_WEIGHT=0

for m in "${TRIMMED[@]}"; do
	UP=$(echo "$STATS_JSON" | jq -r --arg m "$m" \
		'map(select(.model == $m)) | .[0].up // 0')
	DOWN=$(echo "$STATS_JSON" | jq -r --arg m "$m" \
		'map(select(.model == $m)) | .[0].down // 0')

	WEIGHT=$(((UP + ALPHA) * 100 / (UP + DOWN + 2 * ALPHA)))
	[ "$WEIGHT" -lt "$FLOOR" ] && WEIGHT=$FLOOR

	WEIGHTS+=("$WEIGHT")
	TOTAL_WEIGHT=$((TOTAL_WEIGHT + WEIGHT))
done

# ── Step 3: Weighted random pick ────────────────────────────────────────────

R=$((RANDOM % TOTAL_WEIGHT))
CUMULATIVE=0
SELECTED=""

for i in "${!TRIMMED[@]}"; do
	CUMULATIVE=$((CUMULATIVE + WEIGHTS[i]))
	if [ "$R" -lt "$CUMULATIVE" ]; then
		SELECTED="${TRIMMED[i]}"
		break
	fi
done

[ -z "$SELECTED" ] && SELECTED="${TRIMMED[0]}"

echo "Model weights (higher = more likely to be picked):"
for i in "${!TRIMMED[@]}"; do
	PCT=$((WEIGHTS[i] * 100 / TOTAL_WEIGHT))
	echo "  ${TRIMMED[i]}: weight=${WEIGHTS[i]} (~${PCT}%)"
done

echo "model=${SELECTED}" >>"$GITHUB_OUTPUT"
echo "::notice::Selected model: ${SELECTED}"
