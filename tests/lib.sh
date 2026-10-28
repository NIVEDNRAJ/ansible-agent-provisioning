#!/usr/bin/env bash
# Shared by tests/run-matrix.sh and tests/run-service-test.sh. Source it; do not run it.
#
# docker.sock is mounted so the controller container can reach the target containers
# over the docker connection plugin; the repo is copied in because bind mounts from some
# hosts are world-writable, which makes Ansible ignore ansible.cfg. (The copy goes to a
# path that cannot already exist in the image — /work and /run both do.)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CTL_IMAGE="${CTL_IMAGE:-agent-prov-ctl}"

ctl() { # ctl <logfile> <command...>   run a command in the controller, in a copy of the repo
  local log="$1"; shift
  MSYS_NO_PATHCONV=1 docker run --rm \
    -v "$HERE:/src:ro" -v /var/run/docker.sock:/var/run/docker.sock \
    -e ANSIBLE_HOME=/tmp/ah -e ANSIBLE_LOCAL_TEMP=/tmp/al -e ANSIBLE_FORCE_COLOR=0 \
    ${CTL_EXTRA_DOCKER_ARGS:-} \
    "$CTL_IMAGE" sh -c 'cp -r /src /tmp/repo && chmod -R go-w /tmp/repo && cd /tmp/repo && "$@"' _ "$@" >"$log" 2>&1
}

play() { # play <container> <logfile> <playbook> [extra ansible-playbook args...]
  local c="$1" log="$2" pb="$3"; shift 3
  ctl "$log" ansible-playbook -i "$c," -c community.docker.docker "$pb" \
    -e ansible_python_interpreter=auto_silent "$@"
}

# Add the certificates in a PEM bundle to a target container's trust store (a
# TLS-inspecting proxy re-signs HTTPS with its own CA). Debian-family
# update-ca-certificates wants ONE certificate per .crt file and silently skips a bundle,
# so the bundle is split first.
inject_ca() { # inject_ca <container> <deb|rpm> <bundle.pem>
  local c="$1" fam="$2" bundle="$3" tmp n=0
  [[ -n "$bundle" ]] || return 0
  if [[ "$fam" == rpm ]]; then
    docker cp "$bundle" "$c:/etc/pki/ca-trust/source/anchors/extra-ca.pem" && docker exec "$c" update-ca-trust
    return
  fi
  tmp="$(mktemp -d)"
  awk -v d="$tmp" '/BEGIN CERTIFICATE/{n++} n>0{print > (d "/extra-ca-" n ".crt")}' "$bundle"
  for f in "$tmp"/extra-ca-*.crt; do
    docker cp "$f" "$c:/usr/local/share/ca-certificates/$(basename "$f")"
  done
  docker exec "$c" update-ca-certificates >/dev/null
  rm -rf "$tmp"
}
