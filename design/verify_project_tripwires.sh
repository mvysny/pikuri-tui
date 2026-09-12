#!/usr/bin/env bash
# This project's own invariant checks — the T_ slugs cited from design/requirements.md's
# "Enforced by" lines and from AGENTS.md's invariant register. The doc *layer* is checked by its
# sibling, design/verify_design_tripwires.sh; both run from `rake check`.
#
# Add a check here (never as a shell one-liner in AGENTS.md, where nothing runs it): give it a
# T_<slug>, cite that slug beside the invariant it guards, and make the failure message restate
# the rule with its pointer — this message is where a tripwired rule is actually read.
#
# Run from anywhere inside the repo: design/verify_project_tripwires.sh
# Exit 0 when green, 1 with one "tripwire:" line per failure otherwise.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

fail=0
err() { printf 'tripwire: %s\n' "$*" >&2; fail=1; }

# --- T_no_llm_sdk ------------------------------------------------------------
# R_shell_only: pikuri owns the LLM transport, so this side holds no second client. A retry, a
# timeout or a rescue added here is one that drifts from the one pikuri already implements.
hits=$(grep -rInE "^ *require ['\"](ruby_llm|faraday|net/http|httparty|excon|typhoeus|rest-client|openai|anthropic)" lib bin 2>/dev/null || true)
if [ -n "$hits" ]; then
  err "T_no_llm_sdk: lib/ and bin/ must not require an HTTP or LLM client — pikuri owns the transport (R_shell_only):"
  printf '  %s\n' "$hits" >&2
fi

if [ "$fail" -eq 0 ]; then
  echo "project tripwires: ok"
fi
exit "$fail"
