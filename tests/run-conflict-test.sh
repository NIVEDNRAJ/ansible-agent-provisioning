#!/usr/bin/env bash
# =============================================================================
# agent_packages on a host that ALREADY has software: repositories and packages
# =============================================================================
#   tests/run-conflict-test.sh                  # ubuntu-22.04 and rhel-9
#   tests/run-conflict-test.sh ubuntu-22.04     # one target
#   EXTRA_CA=/path/ca.pem tests/run-conflict-test.sh      # behind a TLS-inspecting proxy
#
# Throwaway containers only. Each scenario builds the host the way a real VM ends up
# (a hand-added Docker repository, Microsoft's own packages-microsoft-prod setup, Ubuntu's
# docker.io, a host with chrony or systemd-timesyncd) and runs the real role against it.
#
# Ubuntu 22.04 (deb)
#   1  CONTROL  Docker repo exists with another key; reuse switched OFF
#              -> must fail with apt's "Conflicting values set for option Signed-By"
#   2  Docker repo exists with another key (reuse on, the default)
#              -> role succeeds, apt update is clean, ONE Docker source, docker runs
#   3  second run                                 -> changed=0
#   4  Microsoft repo exists (packages-microsoft-prod style, its own key)
#              -> role succeeds, apt update is clean, ONE Microsoft source, sqlcmd runs
#   5  docker.io + containerd installed, install_docker=true
#              -> REFUSED before any change, naming them; docker.io is still there
#   6  the same with agent_remove_packages naming them    -> installs docker-ce, docker.io gone
#   7  an unrelated conflict the package manager would settle by removing a package
#      (chrony replaces systemd-timesyncd)        -> REFUSED, naming it; then allowed
# AlmaLinux 9 (rpm; stands in for RHEL)
#   8  podman-docker installed, install_docker=true -> REFUSED, naming it; then removed and installed
#   9  a package that cannot be installed next to an installed one (coreutils vs
#      coreutils-single)                          -> REFUSED with dnf's own reason
#
# WHAT IS NOT COVERED: the dnf "Removing" wording is matched but no scenario produces
# it (a plain `dnf install` without --allowerasing reports a conflict as an error, which
# is scenario 9); NodeSource conflicts (its signing key URL is blocked on some networks).
# =============================================================================
set -uo pipefail
source "$(dirname "$0")/lib.sh"

EXTRA_CA="${EXTRA_CA:-}"
RESULTS_DIR="${RESULTS_DIR:-${TMPDIR:-/tmp}/agent-prov-conflict}"
mkdir -p "$RESULTS_DIR"
ONLY="$*"
want() { [[ -z "$ONLY" ]] || [[ " $ONLY " == *" $1 "* ]]; }

# Everything off except what a scenario turns on: it is about repositories and conflicts.
MINIMAL=(-e agent_install_sqlcmd=false -e agent_install_kubectl=false -e agent_install_helm=false
         -e agent_install_dotnet=false -e agent_install_nodejs=false -e agent_install_maven=false
         -e agent_install_java=false -e agent_install_yq=false -e agent_install_azcopy=false)

fail=0
ok()   { printf '  %-4s PASS  %s\n' "$1" "$2"; }
bad()  { printf '  %-4s FAIL  %s\n' "$1" "$2"; fail=$((fail + 1)); }
check() { # check <id> <description> <command...>   passes when the command succeeds
  local id="$1" d="$2"; shift 2
  if "$@" >/dev/null 2>&1; then ok "$id" "$d"; else bad "$id" "$d"; fi
}
sh_in() { docker exec "$1" sh -c "$2"; }
count_in() { docker exec "$1" sh -c "$2" 2>/dev/null | tr -d '[:space:]'; }

start() { # start <name> <image> <deb|rpm>
  local c="agentprov-conflict-$1"
  docker rm -f "$c" >/dev/null 2>&1
  docker run -d --name "$c" "$2" sleep infinity >/dev/null || return 1
  if [[ "$3" == deb ]]; then
    docker exec "$c" sh -c 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3 ca-certificates curl gnupg >/dev/null' || return 1
  fi
  inject_ca "$c" "$3" "$EXTRA_CA"
  echo "$c"
}

# ─────────────────────────────────────────────────────────────────────────────
if want ubuntu-22.04; then
  echo "== ubuntu-22.04"
  c="$(start ubuntu-22.04 ubuntu:22.04 deb)" || { bad setup "container did not start"; c=""; }
  if [[ -n "$c" ]]; then
    L="$RESULTS_DIR/u2204"
    # The state a hand-set-up VM is in: Docker's repository, key kept elsewhere.
    sh_in "$c" '
      install -d -m 0755 /usr/share/keyrings
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
      echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu jammy stable" > /etc/apt/sources.list.d/docker.list
      apt-get update -qq' >"$L-seed.log" 2>&1 || bad setup "could not seed the Docker repository ($L-seed.log)"

    # 1 CONTROL: the failure that was reported, with the protection switched off.
    if play "$c" "$L-1.log" tests/test_install.yml "${MINIMAL[@]}" -e install_docker=true -e agent_reuse_existing_repos=false; then
      bad 1 "control: with reuse OFF the run was expected to fail on Signed-By, but it passed"
    elif grep -q 'Conflicting values set for option Signed-By' "$L-1.log"; then
      ok 1 "control: reuse OFF reproduces apt's 'Conflicting values set for option Signed-By'"
    else
      bad 1 "control: failed, but not with the Signed-By conflict (see $L-1.log)"
    fi
    # The control run registered its own source; put the host back to the seeded state.
    sh_in "$c" 'rm -f /etc/apt/sources.list.d/download_docker_com_linux_ubuntu.list /etc/apt/keyrings/docker.asc; apt-get update -qq' >/dev/null 2>&1

    # 2 default behaviour
    if play "$c" "$L-2.log" tests/test_install.yml "${MINIMAL[@]}" -e install_docker=true; then
      ok 2 "role succeeds on a host that already has the Docker repository"
      check 2a "the existing repository was reported as reused" grep -qi "docker repository is already defined" "$L-2.log"
      check 2b "apt update is clean" sh_in "$c" 'apt-get update 2>&1 | tee /tmp/u.log | tail -1; ! grep -q "Conflicting values" /tmp/u.log && ! grep -q "^E:" /tmp/u.log'
      n="$(count_in "$c" 'grep -rhE "^deb .*download\.docker\.com" /etc/apt/sources.list /etc/apt/sources.list.d | wc -l')"
      [[ "$n" == 1 ]] && ok 2c "exactly one Docker source on the host" || bad 2c "expected one Docker source, found $n"
      check 2d "docker-ce is installed and runs" sh_in "$c" 'docker --version'
      check 2e "the role wrote no key or source of its own" sh_in "$c" '! test -e /etc/apt/keyrings/docker.asc'
    else
      bad 2 "role failed on a host that already has the Docker repository (see $L-2.log)"
    fi

    # 3 idempotency
    if play "$c" "$L-3.log" tests/test_install.yml "${MINIMAL[@]}" -e install_docker=true && grep -Eq 'changed=0 ' "$L-3.log"; then
      ok 3 "second run changed=0"
    else
      bad 3 "second run not clean: $(grep -E 'changed=' "$L-3.log" | tail -1 | xargs)"
    fi

    # 4 Microsoft's own repository definition, with its own key, as packages-microsoft-prod.deb leaves it
    sh_in "$c" '
      curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /usr/share/keyrings/microsoft-prod.gpg
      echo "deb [arch=amd64,arm64,armhf signed-by=/usr/share/keyrings/microsoft-prod.gpg] https://packages.microsoft.com/ubuntu/22.04/prod jammy main" > /etc/apt/sources.list.d/microsoft-prod.list
      apt-get update -qq' >"$L-seed-ms.log" 2>&1 || bad setup "could not seed the Microsoft repository ($L-seed-ms.log)"
    if play "$c" "$L-4.log" tests/test_install.yml "${MINIMAL[@]}" -e agent_install_sqlcmd=true; then
      ok 4 "role succeeds on a host that already has the Microsoft repository"
      check 4a "apt update is clean" sh_in "$c" 'apt-get update 2>&1 | tee /tmp/u.log | tail -1; ! grep -q "Conflicting values" /tmp/u.log && ! grep -q "^E:" /tmp/u.log'
      n="$(count_in "$c" 'grep -rhE "^deb .*packages\.microsoft\.com/ubuntu/22\.04/prod" /etc/apt/sources.list /etc/apt/sources.list.d | wc -l')"
      [[ "$n" == 1 ]] && ok 4b "exactly one Microsoft source on the host" || bad 4b "expected one Microsoft source, found $n"
      check 4c "sqlcmd runs" sh_in "$c" '/opt/mssql-tools/bin/sqlcmd -? | head -2'
    else
      bad 4 "role failed on a host that already has the Microsoft repository (see $L-4.log)"
    fi
    docker rm -f "$c" >/dev/null 2>&1

    # 5-7 packages
    c="$(start ubuntu-22.04-pk ubuntu:22.04 deb)" || { bad setup "container did not start"; c=""; }
    if [[ -n "$c" ]]; then
      L="$RESULTS_DIR/u2204pk"
      sh_in "$c" 'DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker.io >/dev/null' >"$L-seed.log" 2>&1 || bad setup "could not install docker.io ($L-seed.log)"
      if play "$c" "$L-5.log" tests/test_install.yml "${MINIMAL[@]}" -e install_docker=true; then
        bad 5 "docker.io is installed and the run was expected to be refused, but it passed"
      elif grep -q 'cannot be installed next to' "$L-5.log" && grep -q 'docker.io' "$L-5.log"; then
        ok 5 "refused, naming docker.io"
        check 5a "nothing was changed: docker.io is still installed" sh_in "$c" 'dpkg -s docker.io | grep -q "Status: install ok installed"'
        check 5b "nothing was changed: docker-ce was not installed" sh_in "$c" '! dpkg -s docker-ce'
        check 5c "no Docker repository was registered" sh_in "$c" '! test -e /etc/apt/keyrings/docker.asc'
      else
        bad 5 "refused, but not for the expected reason (see $L-5.log)"
      fi
      if play "$c" "$L-6.log" tests/test_install.yml "${MINIMAL[@]}" -e install_docker=true \
           -e '{"agent_remove_packages": ["docker.io", "containerd", "runc"]}'; then
        ok 6 "agent_remove_packages removes exactly what was named, then installs Docker CE"
        check 6a "docker-ce is installed and runs" sh_in "$c" 'docker --version'
        check 6b "docker.io is gone" sh_in "$c" '! dpkg -s docker.io 2>/dev/null | grep -q "Status: install ok installed"'
      else
        bad 6 "install failed after agent_remove_packages (see $L-6.log)"
      fi
      docker rm -f "$c" >/dev/null 2>&1
    fi

    c="$(start ubuntu-22.04-gen ubuntu:22.04 deb)" || { bad setup "container did not start"; c=""; }
    if [[ -n "$c" ]]; then
      L="$RESULTS_DIR/u2204gen"
      sh_in "$c" 'DEBIAN_FRONTEND=noninteractive apt-get install -y -qq systemd-timesyncd >/dev/null' >"$L-seed.log" 2>&1 || bad setup "could not install systemd-timesyncd ($L-seed.log)"
      if play "$c" "$L-7.log" tests/test_install.yml "${MINIMAL[@]}" -e '{"agent_extra_packages": ["chrony"]}'; then
        bad 7 "chrony would remove systemd-timesyncd and the run was expected to be refused, but it passed"
      elif grep -q 'would REMOVE' "$L-7.log" && grep -q 'systemd-timesyncd' "$L-7.log"; then
        ok 7 "refused, naming systemd-timesyncd, before installing anything"
        check 7a "systemd-timesyncd is still installed" sh_in "$c" 'dpkg -s systemd-timesyncd | grep -q "Status: install ok installed"'
        check 7b "chrony was not installed" sh_in "$c" '! dpkg -s chrony'
      else
        bad 7 "refused, but not for the expected reason (see $L-7.log)"
      fi
      if play "$c" "$L-7b.log" tests/test_install.yml "${MINIMAL[@]}" -e '{"agent_extra_packages": ["chrony"]}' -e agent_allow_package_removal=true; then
        ok 7b "agent_allow_package_removal=true accepts it"
        check 7c "chrony is installed" sh_in "$c" 'dpkg -s chrony | grep -q "Status: install ok installed"'
      else
        bad 7b "failed even with agent_allow_package_removal=true (see $L-7b.log)"
      fi
      docker rm -f "$c" >/dev/null 2>&1
    fi
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# 10  THE STATE A REAL VM WAS FOUND IN. The host has Microsoft's and Docker's own sources
#     (microsoft-prod.list, signed-by=/usr/share/keyrings/...) AND a second source for each
#     that an earlier run of this role wrote (signed-by=/etc/apt/keyrings/*.asc). apt refuses
#     every command: "Conflicting values set for option Signed-By ... The list of sources
#     could not be read". The role must repair it itself, removing only its own duplicates.
dup_repair() { # dup_repair <name> <image>
  local name="$1" image="$2" c L="$RESULTS_DIR/dup-$1" ver code
  c="$(start "dup-$name" "$image" deb)" || { bad 10 "$name: container did not start"; return; }
  ver="$(docker exec "$c" sh -c '. /etc/os-release; echo $VERSION_ID')"
  code="$(docker exec "$c" sh -c '. /etc/os-release; echo $VERSION_CODENAME')"
  sh_in "$c" "
    install -d -m 0755 /usr/share/keyrings /etc/apt/keyrings
    curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /usr/share/keyrings/microsoft-prod.gpg
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    cp /usr/share/keyrings/microsoft-prod.gpg /etc/apt/keyrings/microsoft.asc
    cp /usr/share/keyrings/docker-archive-keyring.gpg /etc/apt/keyrings/docker.asc
    echo 'deb [arch=amd64,arm64,armhf signed-by=/usr/share/keyrings/microsoft-prod.gpg] https://packages.microsoft.com/ubuntu/$ver/prod $code main' > /etc/apt/sources.list.d/microsoft-prod.list
    echo 'deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $code stable' > /etc/apt/sources.list.d/docker.list
    echo 'deb [arch=amd64,armhf,arm64 signed-by=/etc/apt/keyrings/microsoft.asc] https://packages.microsoft.com/ubuntu/$ver/prod $code main' > /etc/apt/sources.list.d/mssql-release.list
    echo 'deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $code stable' > /etc/apt/sources.list.d/download_docker_com_linux_ubuntu.list" \
    >"$L-seed.log" 2>&1 || { bad 10 "$name: could not seed the broken state ($L-seed.log)"; docker rm -f "$c" >/dev/null 2>&1; return; }
  if sh_in "$c" 'apt-get update 2>&1 | grep -q "Conflicting values set for option Signed-By"'; then
    ok "10-$name" "precondition: apt really is broken (Conflicting values set for option Signed-By)"
  else
    bad "10-$name" "precondition: the seeded host is not broken, so this test proves nothing"
  fi
  if play "$c" "$L-run.log" tests/test_install.yml "${MINIMAL[@]}" -e agent_install_sqlcmd=true -e install_docker=true; then
    ok "10a-$name" "role succeeds on the broken host"
    check "10b-$name" "apt update is clean now" sh_in "$c" 'apt-get update 2>&1 | tee /tmp/u.log | tail -1; ! grep -q "Conflicting values" /tmp/u.log && ! grep -q "^E:" /tmp/u.log'
    check "10c-$name" "the role's own duplicate files are gone" sh_in "$c" '! test -e /etc/apt/sources.list.d/mssql-release.list && ! test -e /etc/apt/sources.list.d/download_docker_com_linux_ubuntu.list'
    check "10d-$name" "the host's own sources are untouched" sh_in "$c" 'grep -q microsoft-prod.gpg /etc/apt/sources.list.d/microsoft-prod.list && grep -q docker-archive-keyring.gpg /etc/apt/sources.list.d/docker.list'
    n="$(count_in "$c" 'grep -rhE "^deb .*(packages\.microsoft\.com|download\.docker\.com)" /etc/apt/sources.list /etc/apt/sources.list.d | wc -l')"
    [[ "$n" == 2 ]] && ok "10e-$name" "exactly one source each for Microsoft and Docker" || bad "10e-$name" "expected 2 sources (one each), found $n"
    check "10f-$name" "the removal was reported" grep -q "duplicate registration" "$L-run.log"
    check "10g-$name" "sqlcmd and docker run" sh_in "$c" '/opt/mssql-tools/bin/sqlcmd -? | head -1 && docker --version'
  else
    bad "10a-$name" "role failed on the broken host (see $L-run.log)"
  fi
  # Second run: nothing left to repair, nothing to change.
  if play "$c" "$L-run2.log" tests/test_install.yml "${MINIMAL[@]}" -e agent_install_sqlcmd=true -e install_docker=true && grep -Eq 'changed=0 ' "$L-run2.log"; then
    ok "10h-$name" "second run changed=0"
  else
    bad "10h-$name" "second run not clean: $(grep -E 'changed=' "$L-run2.log" | tail -1 | xargs)"
  fi
  docker rm -f "$c" >/dev/null 2>&1
}
want ubuntu-24.04 && { echo "== ubuntu-24.04 (the release of the VM this was found on)"; dup_repair u2404 ubuntu:24.04; }
want ubuntu-22.04 && { echo "== ubuntu-22.04, same broken state"; dup_repair u2204 ubuntu:22.04; }

# ─────────────────────────────────────────────────────────────────────────────
if want rhel-9; then
  echo "== rhel-9 (almalinux:9)"
  c="$(start rhel-9 almalinux:9 rpm)" || { bad setup "container did not start"; c=""; }
  if [[ -n "$c" ]]; then
    L="$RESULTS_DIR/r9"
    XV=(-e ansible_distribution=RedHat -e agent_crb_repo=crb)
    sh_in "$c" 'dnf -y -q install podman-docker >/dev/null' >"$L-seed.log" 2>&1 || bad setup "could not install podman-docker ($L-seed.log)"
    if play "$c" "$L-8.log" tests/test_install.yml "${MINIMAL[@]}" "${XV[@]}" -e install_docker=true; then
      bad 8 "podman-docker is installed and the run was expected to be refused, but it passed"
    elif grep -q 'cannot be installed next to' "$L-8.log" && grep -q 'podman-docker' "$L-8.log"; then
      ok 8 "refused, naming podman-docker"
      check 8a "nothing was changed: podman-docker is still installed" sh_in "$c" 'rpm -q podman-docker'
      check 8b "nothing was changed: docker-ce was not installed" sh_in "$c" '! rpm -q docker-ce'
    else
      bad 8 "refused, but not for the expected reason (see $L-8.log)"
    fi
    if play "$c" "$L-8c.log" tests/test_install.yml "${MINIMAL[@]}" "${XV[@]}" -e install_docker=true -e '{"agent_remove_packages": ["podman-docker"]}'; then
      ok 8c "agent_remove_packages removes podman-docker, then installs Docker CE"
      check 8d "docker-ce is installed and runs" sh_in "$c" 'docker --version'
    else
      bad 8c "install failed after agent_remove_packages (see $L-8c.log)"
    fi
    docker rm -f "$c" >/dev/null 2>&1
  fi

  c="$(start rhel-9-gen almalinux:9 rpm)" || { bad setup "container did not start"; c=""; }
  if [[ -n "$c" ]]; then
    L="$RESULTS_DIR/r9gen"
    if play "$c" "$L-9.log" tests/test_install.yml "${MINIMAL[@]}" -e ansible_distribution=RedHat -e agent_crb_repo=crb -e '{"agent_extra_packages": ["coreutils"]}'; then
      bad 9 "coreutils cannot be installed next to coreutils-single and the run was expected to be refused, but it passed"
    elif grep -q 'dnf cannot resolve this installation' "$L-9.log"; then
      ok 9 "refused with dnf's own reason: $(grep -o 'package coreutils[^|]*conflicts with[^|]*' "$L-9.log" | head -1 | cut -c1-110)"
      check 9a "nothing was changed: coreutils-single is still installed" sh_in "$c" 'rpm -q coreutils-single'
    else
      bad 9 "refused, but not for the expected reason (see $L-9.log)"
    fi
    docker rm -f "$c" >/dev/null 2>&1
  fi
fi

echo
echo "$fail failing check(s). Logs: $RESULTS_DIR"
[[ $fail -eq 0 ]]
