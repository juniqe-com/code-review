#!/usr/bin/env bash
set -euo pipefail

jq -sr '
  [.[] |
    (if .type == "message" then .message.usage?.cost.total
     elif .type == "usage" or .type == "compaction" or .type == "branch_summary" then .usage?.cost.total
     else empty end) | numbers
  ] | if length == 0 then error("No cost data in Pi session") else add end
' "$1"
