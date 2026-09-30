#!/usr/bin/env bash
set -euo pipefail

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

if [ "${#TRIMMED[@]}" -eq 1 ]; then
	SELECTED="${TRIMMED[0]}"
	echo "model=${SELECTED}" >>"$GITHUB_OUTPUT"
	echo "::notice::Selected model: ${SELECTED}"
	exit 0
fi

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

	if [ -n "$EXTRACTED" ] && echo "$EXTRACTED" | jq -e 'type == "array"' >/dev/null 2>&1; then
		STATS_JSON="$EXTRACTED"
	fi
fi

ALPHA=2
FLOOR=10

CANDIDATE_WEIGHTS=$(jq -n --argjson stats "$STATS_JSON" \
	--argjson alpha "$ALPHA" --argjson minimum "$FLOOR" --args '
	def votes: if type == "number" and . >= 0 then floor else 0 end;
	[
		$ARGS.positional[] as $model |
		($stats | map(select(type == "object") | select(.model == $model)) | .[0] // {}) as $entry |
		($entry.up | votes) as $up |
		($entry.down | votes) as $down |
		{
			model: $model,
			quality: (($up + $alpha) * 100 / ($up + $down + 2 * $alpha) | floor),
			average_cost: (if ($entry.reviews | type == "number" and . > 0) and
				($entry.cost | type == "number" and . > 0)
				then $entry.cost / $entry.reviews else null end)
		}
	] |
	([.[].average_cost | select(. != null)] | min) as $cheapest_average |
	map(. + {weight: ([
		$minimum,
		(.quality * (if .average_cost == null then 1 else $cheapest_average / .average_cost end) | floor)
	] | max)})
' "${TRIMMED[@]}")

WEIGHTS=()
TOTAL_WEIGHT=0

while IFS= read -r WEIGHT; do
	WEIGHTS+=("$WEIGHT")
	TOTAL_WEIGHT=$((TOTAL_WEIGHT + WEIGHT))
done < <(echo "$CANDIDATE_WEIGHTS" | jq -r '.[].weight')

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
