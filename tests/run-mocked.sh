#!/usr/bin/env bash
# =============================================================================
# Every test that needs no containers and no real host.
# =============================================================================
#   tests/run-mocked.sh
# Needs ansible-core, python3 (for the mock), and optionally yamllint / ansible-lint.
#
#   syntax checks, yamllint, ansible-lint
#   tests/test_resolution.yml   package selection and platform support, mocked facts
#   tests/test_instances.yml    agent numbering, names, directories
#   tests/test_server_check.yml server preflight against tests/mock_tfs.py
# and finally that none of the mock's fake PATs appears anywhere in the output.
set -uo pipefail
cd "$(dirname "$0")/.."

PORT="${MOCK_PORT:-8099}"
OUT="$(mktemp)"
trap 'kill "${MOCK_PID:-0}" 2>/dev/null; rm -f "$OUT"' EXIT
fail=0
step() { printf '\n== %s\n' "$1"; }
run() { "$@" >>"$OUT" 2>&1 && echo "   ok" || { echo "   FAILED: $*"; fail=$((fail + 1)); tail -25 "$OUT"; }; }

step "syntax"
run ansible-playbook --syntax-check playbooks/setup-agent.yml integration/core-infra/playbooks/agentservers.yml \
  tests/test_install.yml tests/test_agent_stage.yml tests/test_service.yml tests/assert_agents.yml

if command -v yamllint >/dev/null; then step "yamllint"; run yamllint .; fi
if command -v ansible-lint >/dev/null; then step "ansible-lint"; run ansible-lint; fi

step "mocked platform and package tests"
run ansible-playbook tests/test_resolution.yml
step "agent numbering tests"
run ansible-playbook tests/test_instances.yml

step "server preflight against the mock"
python3 tests/mock_tfs.py "$PORT" &
MOCK_PID=$!
for _ in $(seq 1 20); do
  (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null && break
  sleep 0.25
done
# -vvv on purpose: it is the verbosity at which an unprotected task would print the PAT.
run ansible-playbook -vvv tests/test_server_check.yml

step "no PAT in any output"
# Plain, and as it travels in the Authorization header: base64(":" + PAT).
pats=(good-pat-SECRET-1 forbidden-pat-SECRET-2 wrong-pat-SECRET-3)
patterns=()
for p in "${pats[@]}"; do patterns+=("$p" "$(printf ':%s' "$p" | base64 | tr -d '\n=')"); done
if grep -F -n "$(printf '%s\n' "${patterns[@]}")" "$OUT" >/dev/null; then
  echo "   FAILED: a PAT appears in the output (plain or base64):"
  grep -F -n "$(printf '%s\n' "${patterns[@]}")" "$OUT" | sed -E 's/^(.{160}).*/\1.../'
  fail=$((fail + 1))
else
  echo "   ok"
fi

echo
[[ $fail -eq 0 ]] && echo "all mocked tests passed" || echo "$fail failing step(s)"
[[ $fail -eq 0 ]]
