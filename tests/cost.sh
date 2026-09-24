#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

printf '%s\n' \
  '{"type":"session","version":3}' \
  '{"type":"message","message":{"role":"assistant","usage":{"cost":{"total":0.1}}}}' \
  '{"type":"message","message":{"role":"toolResult","usage":{"cost":{"total":0.01}}}}' \
  '{"type":"message","message":{"role":"assistant","usage":{"cost":{"total":0.2}}}}' \
  '{"type":"compaction","usage":{"cost":{"total":0.03}}}' \
  '{"type":"usage","usage":{"cost":{"total":0.05}}}' \
  >"$TMP/session.jsonl"
COST=$(bash "$ROOT/scripts/session-cost.sh" "$TMP/session.jsonl")
jq -en --argjson cost "$COST" '$cost > 0.389 and $cost < 0.391' >/dev/null
printf '%s\n' '{"type":"session","version":3}' >"$TMP/empty.jsonl"
if bash "$ROOT/scripts/session-cost.sh" "$TMP/empty.jsonl" >/dev/null 2>&1; then
  exit 1
fi

mkdir -p "$TMP/bin"
printf '%s\n' \
  '[{"body":"<!-- pi-review-model: anthropic/model-a -->","reactions":{"+1":2,"-1":1}}, {"body":"<!-- pi-review-model: anthropic/model-a -->","reactions":{"+1":1,"-1":0}}]' >"$TMP/grades.json"
printf '%s\n' \
  '[{"body":"Pi review cost: $0.50 USD.\n<!-- pi-review-cost: {\"model\":\"anthropic/model-a\",\"usd\":0.5} -->"}, {"body":"<!-- pi-review-cost: {\"model\":\"anthropic/model-a\",\"usd\":1.5} -->"}, {"body":"<!-- pi-review-cost: {\"model\":\"openai/model-b\",\"usd\":0.2} -->"}, {"body":"<!-- pi-review-cost: invalid -->"}]' >"$TMP/costs.json"

cat >"$TMP/bin/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
case "$2" in
  repos/test/review/pulls/comments*) cat "$FIXTURE_DIR/grades.json" ;;
  repos/test/review/issues/comments*) cat "$FIXTURE_DIR/costs.json" ;;
  repos/test/review/labels) printf '%s\n' '{}' ;;
  'repos/test/review/issues?labels='*) printf '%s\n' 42 ;;
  repos/test/review/issues/42)
    for arg in "$@"; do
      if [[ "$arg" == body=* ]]; then
        printf '%s' "${arg#body=}" >"$BODY_FILE"
      fi
    done
    ;;
  *) printf 'Unexpected gh call: %s\n' "$*" >&2; exit 1 ;;
esac
MOCK
chmod +x "$TMP/bin/gh"
FIXTURE_DIR="$TMP" BODY_FILE="$TMP/issue.md" GITHUB_REPOSITORY=test/review PATH="$TMP/bin:$PATH" bash "$ROOT/scripts/grades.sh" >"$TMP/log"
rg -q 'anthropic/model-a.*\| 2 \| \$1 ' "$TMP/issue.md"
rg -q 'openai/model-b.*\| 1 \| \$0.2 ' "$TMP/issue.md"
rg -q 'Earlier runs and interrupted reviews have no cost data' "$TMP/issue.md"
jq -en --arg data "$(awk '/<!-- pi-review-stats-data/{getline;print;exit}' "$TMP/issue.md")" '
  $data | fromjson |
  length == 2 and
  (map(select(.model == "anthropic/model-a"))[0] | .up == 3 and .down == 1 and .reviews == 2 and .cost == 2) and
  (map(select(.model == "openai/model-b"))[0] | .up == 0 and .reviews == 1 and .cost == 0.2)
' >/dev/null

printf '%s\n' '[]' >"$TMP/grades.json"
FIXTURE_DIR="$TMP" BODY_FILE="$TMP/issue.md" GITHUB_REPOSITORY=test/review PATH="$TMP/bin:$PATH" bash "$ROOT/scripts/grades.sh" >"$TMP/log"
rg -q 'openai/model-b.*\| 1 \| \$0.2 ' "$TMP/issue.md"
rg -q '0 graded out of 0 total review comments' "$TMP/issue.md"

printf '%s\n' '[]' >"$TMP/costs.json"
FIXTURE_DIR="$TMP" BODY_FILE="$TMP/issue.md" GITHUB_REPOSITORY=test/review PATH="$TMP/bin:$PATH" bash "$ROOT/scripts/grades.sh" >"$TMP/log"
rg -q 'No review comments with reactions found yet' "$TMP/issue.md"
printf '%s\n' 'Cost reporting tests passed.'
