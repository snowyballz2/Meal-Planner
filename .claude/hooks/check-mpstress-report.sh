#!/bin/bash
# PostToolUse hook for Meal-Planner.
#
# Fires after every preview_eval call. If the tool result contains a full
# MPStress.formatReport output (header pattern "## MPStress.runStandard" or
# "## MPStress.runStandard2"), inject a system reminder telling the assistant
# to paste the report VERBATIM as native markdown — no skimping, no code
# fences, all sections.
#
# Existence of this hook is documented in CLAUDE.md "Communication rules".
# Memory: feedback_mpstress_report_rendering.md.

set -euo pipefail

input=$(cat)

# tool_response can be a string, an object, null, or missing. Coerce to a
# searchable string. jq -r prints null as "null" which is harmless.
content=$(printf '%s' "$input" | jq -r '
  .tool_response
  | if   type == "string" then .
    elif type == "object" then tojson
    elif type == "array"  then tojson
    else "" end
' 2>/dev/null || true)

# Match the formatReport header (escaped dot, optional "2"). Quoted output
# from preview_eval may have embedded \n — grep without -F handles either.
if printf '%s' "$content" | grep -qE '## MPStress\.runStandard2?'; then
  cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"REMINDER (PostToolUse hook): the preview_eval tool result above contains a full MPStress.formatReport output. You MUST paste the entire report VERBATIM in your response — native markdown tables, no code fences, no abbreviation, no replacing any section with prose. Include EVERY section the report produces: Key Metrics (with baseline deltas), Miss Breakdown, Hard Invariants, Tracking Invariants (INV6/14/15/16 with deltas), Per-slot Meal Usage, Top Picks Per Slot, Never Picked (if present), Miss Severity, Top Meals in Failing Days, Timing. The user has explicitly called out skimping these reports — do not skim, do not summarize, paste the whole thing. Per CLAUDE.md communication rules and feedback_mpstress_report_rendering.md memory."}}
JSON
fi

exit 0
