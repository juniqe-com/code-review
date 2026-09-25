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
for entry in '1 {"model":"anthropic/model-a","usd":0.5}' \
             '2 {"model":"anthropic/model-a","usd":1.5}' \
             '3 {"model":"openai/model-b","usd":0.2}' \
             '4 {"model":"openai/model-b","usd":-1}'; do
  id=${entry%% *}
  printf '%s\n' "${entry#* }" >"$TMP/pi-review-cost.json"
  (cd "$TMP" && zip -q "cost-${id}.zip" pi-review-cost.json)
done
NOW=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
jq -n --arg now "$NOW" '{artifacts: (
  [{id: 1, created_at: $now, expired: false},
   {id: 2, created_at: $now, expired: false},
   {id: 4, created_at: $now, expired: false},
   {id: 5, created_at: "2020-01-01T00:00:00Z", expired: false},
   {id: 6, created_at: $now, expired: false}] +
  [range(10; 105) | {id: ., created_at: $now, expired: true}]
)}' >"$TMP/page-1.json"
jq -n --arg now "$NOW" '{artifacts: [{id: 3, created_at: $now, expired: false}]}' >"$TMP/page-2.json"
printf '%s\n' \
  'jobs:' \
  '  review:' \
  '    steps:' \
  '      - name: Run Pi review' \
  '        uses: juniqe-com/code-review@v1.8.5' \
  '        env:' \
  '          OPENAI_API_KEY: secret' \
  '        with:' \
  '          models: >-' \
  '            anthropic/model-a,' \
  '            openai/model-c' \
  >"$TMP/workflow.yml"
python3 "$ROOT/scripts/active-models.py" <"$TMP/workflow.yml" | jq -e '. == ["anthropic/model-a", "openai/model-c"]' >/dev/null
printf '%s\n' \
  'steps:' \
  '  - uses: example/code-review@v1' \
  '    with:' \
  '      model: "openai/model-b"' \
  | python3 "$ROOT/scripts/active-models.py" | jq -e '. == ["openai/model-b"]' >/dev/null

cat >"$TMP/bin/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
case "$2" in
  repos/test/review/pulls/comments*) cat "$FIXTURE_DIR/grades.json" ;;
  repos/test/review/actions/artifacts?name=pi-review-cost\&per_page=100\&page=1) cat "$FIXTURE_DIR/page-1.json" ;;
  repos/test/review/actions/artifacts?name=pi-review-cost\&per_page=100\&page=2) cat "$FIXTURE_DIR/page-2.json" ;;
  repos/test/review/contents/.github/workflows/pi-review.yml) cat "$FIXTURE_DIR/workflow.yml" ;;
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
cat >"$TMP/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
output=''
for ((i=1; i<=$#; i++)); do
  if [[ ${!i} == -o ]]; then
    j=$((i+1))
    output=${!j}
  fi
done
url=${!#}
id=${url%/zip}
id=${id##*/}
printf '%s\n' "$id" >>"$DOWNLOADS_FILE"
[[ $id != 6 ]] || exit 1
cp "$FIXTURE_DIR/cost-${id}.zip" "$output"
MOCK
chmod +x "$TMP/bin/gh" "$TMP/bin/curl"
export FIXTURE_DIR="$TMP" BODY_FILE="$TMP/issue.md" DOWNLOADS_FILE="$TMP/downloads" GITHUB_REPOSITORY=test/review GITHUB_TOKEN=test-token
export PATH="$TMP/bin:$PATH"
bash "$ROOT/scripts/grades.sh" >"$TMP/log"
rg -q 'anthropic/model-a.*\| 2 \| \$1 ' "$TMP/issue.md"
rg -q 'openai/model-c.*\| 0 \| — ' "$TMP/issue.md"
rg -q '<summary>Archived models \(1\)</summary>' "$TMP/issue.md"
rg -q 'openai/model-b.*\| 1 \| \$0.2 ' "$TMP/issue.md"
rg -q 'artifact from the last 90 days' "$TMP/issue.md"
rg -q 'Could not download review cost artifact 6' "$TMP/log"
rg -q 'Invalid review cost artifact 4' "$TMP/log"
if rg -q '^5$|^10$' "$TMP/downloads"; then
  exit 1
fi
jq -en --arg data "$(awk '/<!-- pi-review-stats-data/{getline;print;exit}' "$TMP/issue.md")" '
  $data | fromjson |
  length == 2 and
  (map(select(.model == "anthropic/model-a"))[0] | .up == 3 and .down == 1 and .reviews == 2 and .cost == 2) and
  (map(select(.model == "openai/model-c"))[0] | .up == 0 and .reviews == 0 and .total == 0)
' >/dev/null

printf '%s\n' '[]' >"$TMP/grades.json"
bash "$ROOT/scripts/grades.sh" >"$TMP/log"
rg -q 'openai/model-b.*\| 1 \| \$0.2 ' "$TMP/issue.md"
rg -q '0 graded out of 0 total active-model review comments' "$TMP/issue.md"

printf '%s\n' '{"artifacts":[]}' >"$TMP/page-1.json"
bash "$ROOT/scripts/grades.sh" >"$TMP/log"
rg -q 'openai/model-c.*\| 0 \| — ' "$TMP/issue.md"
if rg -q '<summary>Archived models' "$TMP/issue.md"; then
  exit 1
fi
printf '%s\n' '[]' >"$TMP/workflow.yml"
if bash "$ROOT/scripts/grades.sh" >"$TMP/log" 2>&1; then
  exit 1
fi
printf '%s\n' 'Cost artifact reporting tests passed.'
