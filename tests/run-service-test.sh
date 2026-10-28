#!/usr/bin/env bash
# =============================================================================
# The ado_agent role against real systemd, in throwaway containers.
# =============================================================================
#   AGENT_TARBALL=/path/vsts-agent-linux-x64-4.261.0.tar.gz tests/run-service-test.sh
#   tests/run-service-test.sh ubuntu-22.04        # one target
#
# WHAT IS REAL: the role, config.sh, runsvc.sh, svc.sh (generated from the agent's own
# template), the unit file, systemd, `su`, the process list, the node runtime.
# WHAT IS STOOD IN FOR: bin/Agent.Listener, the one component that talks to Azure DevOps.
# It is replaced by tests/fixtures/Agent.Listener.shim, which leaves behind what a
# successful registration leaves. A test cannot register against a real server without a
# real PAT, so registration against a real server remains UNTESTED.
#
# Scenarios per target
#   1  register two agents, service skipped        → agents, creds mode 0600, PAT file gone,
#                                                    PAT never on a command line
#   2  run again without the skip                  → services installed and active, one unit
#                                                    per agent  (the "failed half way" repair)
#   3  run once more                               → changed=0  (idempotency)
#   4  registration fails                          → clear error, PAT redacted, no leftovers
#   5  the service crashes                         → fails with the journal, not silently
#   6  agent left at the old default directory     → refused before anything is done
#   7  legacy ado_agent_root, different agent      → refused, existing agent not clobbered
#   8  the REAL agent, unreachable server          → the agent's own error reaches the log, no PAT
#   9  --tags always (what --tags packages runs)   → needs no PAT, pool or server
#
# Environment: AGENT_TARBALL (required), EXTRA_CA, RESULTS_DIR, AGENT_VERSION.
set -uo pipefail
source "$(dirname "$0")/lib.sh"

RESULTS_DIR="${RESULTS_DIR:-${TMPDIR:-/tmp}/agent-prov-service-results}"
EXTRA_CA="${EXTRA_CA:-}"
AGENT_TARBALL="${AGENT_TARBALL:-}"
AGENT_VERSION="${AGENT_VERSION:-4.261.0}"
SENTINEL="PAT-SENTINEL-9f3a7c21d4"
[[ -f "$AGENT_TARBALL" ]] || { echo "set AGENT_TARBALL to a vsts-agent-linux-x64-*.tar.gz" >&2; exit 2; }
mkdir -p "$RESULTS_DIR"

# name | image | family | extra ansible vars
TARGETS=(
  "ubuntu-22.04|jrei/systemd-ubuntu:22.04|deb|"
  "debian-12|jrei/systemd-debian:12|deb|"
  "alma-9|almalinux/9-init|rpm|ansible_distribution=RedHat"
)
MINIMAL=(-e agent_install_sqlcmd=false -e agent_install_kubectl=false -e agent_install_helm=false
         -e agent_install_dotnet=false -e agent_install_nodejs=false -e agent_install_maven=false
         -e agent_install_java=false -e agent_install_yq=false -e agent_install_azcopy=false)

ONLY="$*"
want() { [[ -z "$ONLY" ]] || [[ " $ONLY " == *" $1 "* ]]; }
declare -A RESULT
record() { RESULT["$1|$2"]="$3"; printf '  %-14s %-3s %s\n' "$1" "$2" "$3"; }

# A copy of the real agent archive whose Agent.Listener is the test double.
build_shim_archive() {
  MSYS_NO_PATHCONV=1 docker run --rm -v "$AGENT_TARBALL:/in/agent.tgz:ro" -v "$HERE/tests/fixtures/Agent.Listener.shim:/in/shim:ro" \
    -v "$RESULTS_DIR:/out" "$CTL_IMAGE" sh -c \
    'mkdir /a && tar -xzf /in/agent.tgz -C /a && cp /in/shim /a/bin/Agent.Listener && chmod 755 /a/bin/Agent.Listener && tar -czf /out/agent-shim.tar.gz -C /a .' \
    >"$RESULTS_DIR/build-shim.log" 2>&1
}

start_systemd() { # start_systemd <name> <image> <family>
  local c="svc-$1" image="$2" fam="$3"
  docker rm -f "$c" >/dev/null 2>&1
  MSYS_NO_PATHCONV=1 docker run -d --name "$c" --privileged --cgroupns=host \
    -v /sys/fs/cgroup:/sys/fs/cgroup:rw "$image" >/dev/null || return 1
  local state=""
  for _ in $(seq 1 60); do
    state="$(docker exec "$c" systemctl is-system-running 2>/dev/null)"
    [[ "$state" == running || "$state" == degraded ]] && break
    sleep 1
  done
  [[ "$state" == running || "$state" == degraded ]] || { echo "systemd did not come up ($state)" >&2; return 1; }
  if [[ "$fam" == deb ]]; then
    docker exec "$c" sh -c 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3 ca-certificates procps >/dev/null' || return 1
    inject_ca "$c" deb "$EXTRA_CA"
  else
    inject_ca "$c" rpm "$EXTRA_CA"
    docker exec "$c" sh -c 'dnf -y -q install procps-ng python3 >/dev/null 2>&1' || return 1
  fi
  docker exec "$c" sh -c 'mkdir -p /var/cache/ado-agent' &&
    docker cp "$RESULTS_DIR/agent-shim.tar.gz" "$c:/var/cache/ado-agent/vsts-agent-linux-x64-$AGENT_VERSION.tar.gz"
}

# The role deletes its cached archive when it finishes (ado_agent_keep_archive: false), so
# a scenario that needs the test double puts it back.
restage() { # restage <container>   — and prove it is there; a silent failure here looks like a role bug
  local dest="/var/cache/ado-agent/vsts-agent-linux-x64-$AGENT_VERSION.tar.gz" try
  for try in 1 2 3; do
    docker exec "$1" sh -c 'mkdir -p /var/cache/ado-agent' &&
      docker cp "$RESULTS_DIR/agent-shim.tar.gz" "$1:$dest" &&
      docker exec "$1" sh -c "test -s $dest" && return 0
    sleep 2
  done
  echo "restage failed on $1" >&2
  return 1
}

echo "Results: $RESULTS_DIR"
build_shim_archive || { echo "could not build the shim archive; see $RESULTS_DIR/build-shim.log" >&2; exit 2; }

for row in "${TARGETS[@]}"; do
  IFS='|' read -r name image fam extra <<<"$row"
  want "$name" || continue
  c="svc-$name"
  L="$RESULTS_DIR/$name"
  echo "== $name ($image)"
  read -r -a xv <<<"$extra"; XV=(); for v in "${xv[@]}"; do XV+=(-e "$v"); done
  COMMON=(-e ansible_become_method=su -e ado_org_url=https://tfs.invalid:8082/ -e ado_agent_pool=Pool-A
          -e ado_agent_name=t -e "ado_pat=$SENTINEL" "${XV[@]}")

  if ! start_systemd "$name" "$image" "$fam"; then record "$name" setup "FAIL (systemd container did not start)"; continue; fi
  if ! play "$c" "$L-deps.log" tests/test_install.yml "${MINIMAL[@]}" "${XV[@]}"; then
    record "$name" setup "FAIL (agent runtime dependencies; see $L-deps.log)"; docker rm -f "$c" >/dev/null 2>&1; continue
  fi

  AG12='{"agents":[{"root":"/var/agents/agent1","name":"t-1"},{"root":"/var/agents/agent2","name":"t-2"}],"pat_sentinel":"'"$SENTINEL"'","expect_services":'
  NUM12='{"ado_agent_numbers":[1,2]}'

  # 1 ─ register, no service
  if play "$c" "$L-1.log" tests/test_service.yml "${COMMON[@]}" -e "$NUM12" --skip-tags service -vvv &&
     play "$c" "$L-1a.log" tests/assert_agents.yml "${XV[@]}" -e ansible_become_method=su -e "${AG12}false}"; then
    record "$name" 1 "PASS (2 agents registered; PAT only in the environment, never on a command line)"
  else record "$name" 1 "FAIL (see $L-1.log / $L-1a.log)"; fi

  # 2 ─ service on the already-registered agents
  # ...and the agent directories were not touched again: extraction must leave their mode as
  # the role set it, or this run's "Create the agent directory" would report a change.
  if play "$c" "$L-2.log" tests/test_service.yml "${COMMON[@]}" -e "$NUM12" &&
     play "$c" "$L-2a.log" tests/assert_agents.yml "${XV[@]}" -e ansible_become_method=su -e "${AG12}true}" &&
     ! awk '/Create the agent directory/{getline; print}' "$L-2.log" | grep -q '^changed'; then
    record "$name" 2 "PASS (2 services installed, active, enabled, distinct; directories unchanged)"
  else record "$name" 2 "FAIL (see $L-2.log / $L-2a.log)"; fi

  # 3 ─ idempotency
  if play "$c" "$L-3.log" tests/test_service.yml "${COMMON[@]}" -e "$NUM12" && grep -Eq 'changed=0 ' "$L-3.log"; then
    record "$name" 3 "PASS (re-run changed=0)"
  else record "$name" 3 "FAIL (re-run: $(grep -E 'changed=' "$L-3.log" | tail -1 | xargs))"; fi

  # 4 ─ registration fails
  restage "$c"
  if ! play "$c" "$L-4.log" tests/test_service.yml "${COMMON[@]}" -e '{"ado_agent_numbers":[3],"ado_agent_names":{"3":"fail-agent"}}' &&
     grep -q 'Registration of fail-agent failed' "$L-4.log" && grep -q 'not authorized to access' "$L-4.log" &&
     grep -q '\*\*\*\*\*\*\*\*' "$L-4.log" && ! grep -q "$SENTINEL" "$L-4.log" &&
     docker exec "$c" sh -c '! test -e /var/agents/agent3/.ansible-pat && ! test -e /var/agents/agent3/.agent'; then
    record "$name" 4 "PASS (failed clearly, PAT redacted in the error, staged PAT removed, nothing half-installed)"
  else record "$name" 4 "FAIL (see $L-4.log)"; fi

  # 5 ─ the service crashes
  restage "$c"
  if ! play "$c" "$L-5.log" tests/test_service.yml "${COMMON[@]}" -e ado_agent_service_retries=2 -e ado_agent_service_delay=2 \
        -e '{"ado_agent_numbers":[4],"ado_agent_names":{"4":"crash-agent"}}' &&
     grep -q 'did not become active' "$L-5.log" && grep -q 'Last journal lines' "$L-5.log" && ! grep -q "$SENTINEL" "$L-5.log"; then
    record "$name" 5 "PASS (failed with the journal, not silently)"
  else record "$name" 5 "FAIL (see $L-5.log)"; fi

  # 6 ─ an agent at the old default directory
  docker exec "$c" sh -c 'mkdir -p /opt/azure-pipelines-agent && echo "{\"agentName\":\"old\",\"poolName\":\"Pool-A\",\"serverUrl\":\"https://tfs.invalid:8082/\"}" > /opt/azure-pipelines-agent/.agent'
  if ! play "$c" "$L-6.log" tests/test_service.yml "${COMMON[@]}" -e "$NUM12" --tags preflight &&
     grep -q 'already configured in /opt/azure-pipelines-agent' "$L-6.log"; then
    record "$name" 6 "PASS (refused to start a second agent next to the old one)"
  else record "$name" 6 "FAIL (see $L-6.log)"; fi

  # 7 ─ legacy root, but the agent there is a different one
  if ! play "$c" "$L-7.log" tests/test_service.yml "${COMMON[@]}" -e ado_agent_root=/opt/azure-pipelines-agent &&
     grep -q 'already configured for a different agent name, pool or server' "$L-7.log"; then
    record "$name" 7 "PASS (did not clobber the existing agent)"
  else record "$name" 7 "FAIL (see $L-7.log)"; fi

  # 8 ─ the REAL agent against a server that cannot be reached (no test double)
  # The fake old-location agent from 6 and 7 goes, or the role's own guard refuses to run.
  # The real archive is placed in the cache rather than downloaded: some firewalls answer the
  # download with 403, and this scenario is about the agent's behaviour, not the network.
  docker exec "$c" sh -c "rm -rf /opt/azure-pipelines-agent /var/agents/agent5"
  docker exec "$c" sh -c 'mkdir -p /var/cache/ado-agent' &&
    docker cp "$AGENT_TARBALL" "$c:/var/cache/ado-agent/vsts-agent-linux-x64-$AGENT_VERSION.tar.gz"
  if ! play "$c" "$L-8.log" tests/test_service.yml "${COMMON[@]}" -e '{"ado_agent_numbers":[5]}' &&
     grep -q 'Registration of t failed' "$L-8.log" && grep -q 'Name or service not known' "$L-8.log" &&
     ! grep -q "$SENTINEL" "$L-8.log" && docker exec "$c" sh -c '! test -e /var/agents/agent5/.ansible-pat'; then
    record "$name" 8 "PASS (real Agent.Listener: its own connection error reached the log, no PAT, staged PAT removed)"
  else record "$name" 8 "FAIL (see $L-8.log)"; fi

  # 9 ─ a tooling-only run needs no PAT, pool or server
  if play "$c" "$L-9.log" tests/test_service.yml -e ansible_become_method=su "${XV[@]}" --tags always; then
    record "$name" 9 "PASS (--tags always/packages asks for no PAT, pool or server)"
  else record "$name" 9 "FAIL (see $L-9.log)"; fi

  # The PAT, plain or as it travels in an Authorization header, is in none of this target's logs.
  b64="$(printf ':%s' "$SENTINEL" | base64 | tr -d '\n=')"
  if grep -l -F -e "$SENTINEL" -e "$b64" "$L"-*.log >"$L-leaks.txt" 2>/dev/null && [[ -s "$L-leaks.txt" ]]; then
    record "$name" leak "FAIL (PAT found in: $(tr '\n' ' ' <"$L-leaks.txt"))"
  else record "$name" leak "PASS (PAT in none of $(ls "$L"-*.log | wc -l) logs, run at -vvv for scenario 1)"; fi

  docker rm -f "$c" >/dev/null 2>&1
done

echo
fail=0
for k in "${!RESULT[@]}"; do [[ "${RESULT[$k]}" == FAIL* ]] && fail=$((fail + 1)); done
echo "$fail failing check(s). Logs: $RESULTS_DIR"
[[ $fail -eq 0 ]]
