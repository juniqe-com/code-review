#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

cat >"$TMP/bin/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$CALLS_FILE"
[[ ${GH_FAIL:-0} == 0 ]] || exit 1
cat "$ISSUE_FILE"
MOCK
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH" GITHUB_REPOSITORY=test/review
export ISSUE_FILE="$TMP/issue.md" CALLS_FILE="$TMP/calls" GITHUB_OUTPUT="$TMP/output"
export INPUT_MODELS=' test/cheap, test/expensive, test/unknown ' INPUT_MODEL='test/ignored'

set_stats() {
  printf '<!-- pi-review-stats-data\n%s\n-->\n' "$1" >"$ISSUE_FILE"
}

run_selection() {
  : >"$GITHUB_OUTPUT"
  : >"$CALLS_FILE"
  bash "$ROOT/scripts/select-model.sh" >"$TMP/log"
  local selected
  selected=$(awk -F= '/^model=/{print $2}' "$GITHUB_OUTPUT")
  [[ $selected == test/cheap || $selected == test/expensive || $selected == test/unknown ]]
}

assert_weights() {
  local cheap=$1 expensive=$2 unknown=$3
  grep -Fq "test/cheap: weight=${cheap} (~" "$TMP/log"
  grep -Fq "test/expensive: weight=${expensive} (~" "$TMP/log"
  grep -Fq "test/unknown: weight=${unknown} (~" "$TMP/log"
}

set_stats '[
  {"model":"test/cheap","up":8,"down":0,"reviews":2,"cost":1},
  {"model":"test/expensive","up":8,"down":0,"reviews":10,"cost":10},
  {"model":"test/unknown","up":8,"down":0},
  {"model":"test/archived","reviews":100,"cost":0.01}
]'
run_selection
assert_weights 83 41 83

set_stats '[
  {"model":"test/cheap","up":0,"down":0,"reviews":1,"cost":0.25},
  {"model":"test/expensive","up":98,"down":0,"reviews":1,"cost":0.5}
]'
run_selection
assert_weights 50 49 50

set_stats '[
  {"model":"test/cheap","reviews":1,"cost":0.001},
  {"model":"test/expensive","reviews":1,"cost":100},
  {"model":"test/unknown","up":0,"down":100}
]'
run_selection
assert_weights 50 10 10

set_stats '[
  {"model":"test/cheap","reviews":1,"cost":0},
  {"model":"test/expensive","reviews":1,"cost":10},
  {"model":"test/unknown","reviews":0,"cost":10}
]'
run_selection
assert_weights 50 50 50

set_stats '[
  {"model":"test/cheap","up":3,"down":1},
  {"model":"test/expensive","up":0,"down":100}
]'
run_selection
assert_weights 62 10 50

set_stats '[
  {"model":"test/cheap","up":"invalid","down":-1,"reviews":"1","cost":1},
  {"model":"test/expensive","reviews":1,"cost":-1},
  {"model":"test/unknown","reviews":1,"cost":"invalid"},
  null, "invalid"
]'
run_selection
assert_weights 50 50 50

for stats in '[]' 'null' '{}' 'invalid JSON'; do
  set_stats "$stats"
  run_selection
  assert_weights 50 50 50
done

printf '%s\n' 'An issue with no data block' >"$ISSUE_FILE"
run_selection
assert_weights 50 50 50
GH_FAIL=1 run_selection
assert_weights 50 50 50

INPUT_MODELS='test/unknown' run_selection
[[ ! -s $CALLS_FILE ]]
[[ $(<"$GITHUB_OUTPUT") == model=test/unknown ]]
INPUT_MODELS='' INPUT_MODEL='test/unknown' run_selection
[[ ! -s $CALLS_FILE ]]
[[ $(<"$GITHUB_OUTPUT") == model=test/unknown ]]

if INPUT_MODELS='' INPUT_MODEL='' bash "$ROOT/scripts/select-model.sh" >"$TMP/log" 2>&1; then
  exit 1
fi
if INPUT_MODELS=' , , ' bash "$ROOT/scripts/select-model.sh" >"$TMP/log" 2>&1; then
  exit 1
fi

printf '%s\n' 'Cost-aware model selection tests passed.'
