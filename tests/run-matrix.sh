#!/usr/bin/env bash
# =============================================================================
# Run the roles against real distribution images in throwaway containers.
# =============================================================================
# Nothing here touches a real host: every target is a local, disposable container
# that is removed afterwards.
#
#   docker build -f tests/docker/Dockerfile.controller -t agent-prov-ctl tests/docker
#   tests/run-matrix.sh                       # every target, every phase
#   tests/run-matrix.sh ubuntu-22.04 rhel-9   # chosen targets
#   PHASES="resolve" tests/run-matrix.sh      # one phase
#
# Phases
#   resolve  register the real repositories, then ask apt/dnf to resolve the whole
#            install as a dry run. Proves every mapped package exists, in the
#            repository the role says, and that the repositories do not conflict.
#   agent    install the agent's runtime dependencies, stage the real agent archive
#            under its service user, and start Agent.Listener --version.
#   full     install everything for real, run it a second time and require
#            changed=0 (idempotency), then run each tool (tests/test_install.yml).
#
# Environment
#   EXTRA_CA        PEM added to each target's trust store (TLS-inspecting proxy)
#   AGENT_TARBALL   a pre-downloaded vsts-agent-linux-x64-<ado_agent_version>.tar.gz,
#                   copied in instead of downloading ~150 MB per target
#   FULL_TARGETS    targets the `full` phase runs on (it is the slow one)
#   NODEJS          set to 1 to include NodeSource. Off by default because its key
#                   URL (*.key) is blocked by some firewalls; see the README.
#   RESULTS_DIR     where per-run logs go (default: a temp directory)
#
# ⚑ RHEL is represented by AlmaLinux (binary compatible), with the distribution
#   fact overridden to RedHat. Subscription-only repositories, RHUI and the real
#   CodeReady Builder repository id are NOT exercised.
# =============================================================================
set -uo pipefail

source "$(dirname "$0")/lib.sh"
PHASES="${PHASES:-resolve agent full}"
FULL_TARGETS="${FULL_TARGETS:-ubuntu-22.04 debian-12 centos-stream-9}"
RESULTS_DIR="${RESULTS_DIR:-${TMPDIR:-/tmp}/agent-prov-results}"
EXTRA_CA="${EXTRA_CA:-}"
AGENT_TARBALL="${AGENT_TARBALL:-}"
NODEJS="${NODEJS:-0}"
AGENT_VERSION="${AGENT_VERSION:-4.261.0}"
mkdir -p "$RESULTS_DIR"

# name | image | family | extra ansible vars
TARGETS=(
  "ubuntu-20.04|ubuntu:20.04|deb|"
  "ubuntu-22.04|ubuntu:22.04|deb|"
  "ubuntu-24.04|ubuntu:24.04|deb|"
  "debian-12|debian:12|deb|"
  "centos-stream-9|quay.io/centos/centos:stream9|rpm|"
  "centos-stream-10|quay.io/centos/centos:stream10|rpm|"
  "rhel-8|almalinux:8|rpm|ansible_distribution=RedHat agent_crb_repo=powertools"
  "rhel-9|almalinux:9|rpm|ansible_distribution=RedHat agent_crb_repo=crb"
  "rhel-10|almalinux:10|rpm|ansible_distribution=RedHat agent_crb_repo=crb"
)

start_target() { # start_target <name> <image> <family>
  local name="$1" image="$2" fam="$3" c="agentprov-$1"
  docker rm -f "$c" >/dev/null 2>&1
  docker run -d --name "$c" "$image" sleep infinity >/dev/null || return 1
  if [[ "$fam" == deb ]]; then
    docker exec "$c" sh -c 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3 ca-certificates >/dev/null' || return 1
    inject_ca "$c" deb "$EXTRA_CA"
  else
    inject_ca "$c" rpm "$EXTRA_CA"
  fi
  if [[ -n "$AGENT_TARBALL" ]]; then
    docker exec "$c" sh -c 'mkdir -p /var/cache/ado-agent' && docker cp "$AGENT_TARBALL" "$c:/var/cache/ado-agent/vsts-agent-linux-x64-$AGENT_VERSION.tar.gz"
  fi
}

# NodeSource without its signing key. Test-only, on a throwaway container: it checks
# that the repository layout and package name are right, NOT the signature.
probe_nodesource() { # probe_nodesource <container> <family> <logfile>
  local c="$1" fam="$2" log="$3"
  if [[ "$fam" == deb ]]; then
    docker exec "$c" sh -c '
      echo "deb [trusted=yes arch=amd64] https://deb.nodesource.com/node_22.x nodistro main" > /etc/apt/sources.list.d/ns-test.list
      apt-get update -qq 2>&1 | tail -2; apt-cache policy nodejs | sed -n "1,4p"' >"$log" 2>&1
  else
    docker exec "$c" sh -c '
      printf "[ns-test]\nname=ns\nbaseurl=https://rpm.nodesource.com/pub_22.x/nodistro/nodejs/\$basearch\ngpgcheck=0\nmodule_hotfixes=1\n" > /etc/yum.repos.d/ns-test.repo
      dnf -q repoquery --repo=ns-test --latest-limit=1 --qf "%{name}-%{version}" nodejs' >"$log" 2>&1
  fi
  grep -Eq '(^|[^0-9])22\.[0-9]+\.[0-9]+' "$log"
}

declare -A RESULT
record() { RESULT["$1|$2"]="$3"; printf '  %-18s %-8s %s\n' "$1" "$2" "$3"; }

want() { [[ -z "${ONLY:-}" ]] || [[ " $ONLY " == *" $1 "* ]]; }

ONLY="$*"
NODE_ARGS=(-e agent_install_nodejs=false)
[[ "$NODEJS" == 1 ]] && NODE_ARGS=()
# Everything off except base + agent_runtime: what the agent needs to start.
MINIMAL=(-e agent_install_sqlcmd=false -e agent_install_kubectl=false -e agent_install_helm=false
         -e agent_install_dotnet=false -e agent_install_nodejs=false -e agent_install_maven=false
         -e agent_install_java=false -e agent_install_yq=false -e agent_install_azcopy=false)

echo "Results: $RESULTS_DIR"
for row in "${TARGETS[@]}"; do
  IFS='|' read -r name image fam extra <<<"$row"
  want "$name" || continue
  c="agentprov-$name"
  echo "== $name ($image)"
  read -r -a xv <<<"$extra"; XV=(); for v in "${xv[@]}"; do XV+=(-e "$v"); done

  if ! start_target "$name" "$image" "$fam"; then
    record "$name" setup "FAIL (container did not start)"; continue
  fi

  if [[ " $PHASES " == *" resolve "* ]]; then
    L="$RESULTS_DIR/$name-resolve"
    if play "$c" "$L-repos.log" tests/test_install.yml -t repo,preflight -e install_docker=true "${NODE_ARGS[@]}" "${XV[@]}"; then
      docker exec "$c" sh -c 'if command -v apt-get >/dev/null; then apt-get update -qq; else dnf -q makecache; fi' >"$L-refresh.log" 2>&1
      if play "$c" "$L-dryrun.log" tests/test_install.yml --check -t packages "${NODE_ARGS[@]}" "${XV[@]}" \
         -e install_docker=true; then
        record "$name" resolve "PASS"
      else
        record "$name" resolve "FAIL (dry-run; see $L-dryrun.log)"
      fi
    else
      record "$name" resolve "FAIL (repositories; see $L-repos.log)"
    fi
    if [[ "$NODEJS" != 1 ]]; then
      if probe_nodesource "$c" "$fam" "$L-nodesource.log"; then
        record "$name" node22 "PASS (repository + package name; signature NOT checked)"
      else
        record "$name" node22 "FAIL (see $L-nodesource.log)"
      fi
    fi
  fi

  if [[ " $PHASES " == *" agent "* ]]; then
    L="$RESULTS_DIR/$name-agent"
    if play "$c" "$L-packages.log" tests/test_install.yml "${MINIMAL[@]}" "${XV[@]}" &&
       play "$c" "$L-stage.log" tests/test_agent_stage.yml --skip-tags register,service \
         -e ansible_service_mgr=systemd -e ansible_become_method=su "${XV[@]}"; then
      record "$name" agent "PASS ($(grep -o 'Agent.Listener [0-9.]*' "$L-stage.log" | head -1))"
    else
      record "$name" agent "FAIL (see $L-packages.log / $L-stage.log)"
    fi
  fi

  if [[ " $PHASES " == *" full "* && " $FULL_TARGETS " == *" $name "* ]]; then
    L="$RESULTS_DIR/$name-full"
    if play "$c" "$L-run1.log" tests/test_install.yml -e install_docker=true "${NODE_ARGS[@]}" "${XV[@]}"; then
      if play "$c" "$L-run2.log" tests/test_install.yml -e install_docker=true "${NODE_ARGS[@]}" "${XV[@]}"; then
        if grep -Eq 'changed=0 ' "$L-run2.log"; then
          record "$name" full "PASS (installed, smoke-tested, 2nd run changed=0)"
        else
          record "$name" full "FAIL (2nd run not idempotent: $(grep -E 'changed=' "$L-run2.log" | tail -1 | xargs))"
        fi
      else
        record "$name" full "FAIL (2nd run; see $L-run2.log)"
      fi
    else
      record "$name" full "FAIL (1st run; see $L-run1.log)"
    fi
  fi

  docker rm -f "$c" >/dev/null 2>&1
done

echo
fail=0
for k in "${!RESULT[@]}"; do
  [[ "${RESULT[$k]}" == FAIL* ]] && fail=$((fail + 1))
done
echo "$fail failing check(s). Logs: $RESULTS_DIR"
[[ $fail -eq 0 ]]
