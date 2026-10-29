# Ansible Azure DevOps Agent Provisioning

Provision a Linux VM over SSH, install the build-agent tooling listed in `packages.txt`, verify it, then register one or more self-hosted Azure Pipelines agents (under `/var/agents/agent<N>`) in an **existing** agent pool on Azure DevOps Services or an on-premises Azure DevOps Server / TFS.

Supported targets — anything else is refused in preflight, with the reason named:

| Distribution | Releases | Notes |
|---|---|---|
| Ubuntu | 20.04, 22.04, 24.04 | |
| Debian | 12 | 11 is end of life (its security archive now returns 404); 13 is out: `openjdk-17-jdk` is not in trixie |
| CentOS | Stream 9, 10 | CentOS 7/8 are end of life |
| RHEL | 8, 9, 10 | |

x86_64 only. Rocky, Alma, Oracle Linux, Fedora, SUSE and Alpine are refused even though some report `ansible_os_family: RedHat`; to add one, add it to `agent_supported_platforms` and run `tests/run-matrix.sh` first.

## Structure

```text
roles/agent_packages/   OS tooling: repositories, packages, downloaded binaries, verification
roles/ado_agent/        agent user, download, registration, systemd service
playbooks/setup-agent.yml
integration/core-infra/ files for adding this to NeST.TransactHub.DevOps-Core-Infra
tests/                  mocked-fact tests, container matrix, fixtures
```

`agent_packages` dispatches on `ansible_os_family` (`Debian` / `RedHat`), as Core Infra's `mssql` and `jumpservers` roles do. Package names are data in `roles/agent_packages/vars/main.yml` (`__agent_catalog`), not branches. Only repositories and the install module differ by family.

## Prerequisites

Controller: `ansible-core` 2.16 (`pip install -r requirements.txt`), SSH access to the target, and `ansible-galaxy collection install -r requirements.yml`.

Target: root or passwordless `sudo`, systemd, Python 3, outbound HTTPS to the distribution mirrors, `packages.microsoft.com`, `download.docker.com` (if Docker), `deb.nodesource.com` / `rpm.nodesource.com`, `dl.k8s.io`, `get.helm.sh`, `github.com`, `aka.ms` and `download.agent.dev.azure.com`.

An Azure DevOps PAT able to register agents in the pool, and the pool must already exist.

> **Firewalls:** both NodeSource signing keys end in `.key`. Some firewalls block that file type — the network this was developed on returns a "Blocked download" page. If your VMs are behind such a policy, mirror the key and set `agent_nodesource_key_url` / `agent_nodesource_rpm_key_url`.

## Run

**Before the first run, settle the agent version** — see [Server compatibility](#server-compatibility). Preflight tells you what the server ships and stops on a major-version mismatch.

```bash
# 1. the PAT — from Ansible Vault (see Secrets) or the controller's environment; never -e, never a file
export ADO_PAT='your-pat-value'

# 2. provision one agent: /var/agents/agent1, named as given
ansible-playbook playbooks/setup-agent.yml \
  -e 'agent_vm_ip=10.10.1.25' -e 'ssh_user=devopsadmin' \
  -e 'ado_org_url=<URL>' \
  -e 'ado_agent_pool=TransactHub-Pool' \
  -e 'ado_agent_name=transacthub-agent-04' \
  -e 'ado_agent_version=3.x.y'          # whichever major the server ships — see Server compatibility
```

Add `--private-key ~/.ssh/agent_vm_key` for key auth, or `--ask-vault-pass` if the PAT is in Vault.

Several agents on one host (`/var/agents/agent1`, `agent2`, `agent3`, each its own service):

```bash
ansible-playbook playbooks/setup-agent.yml ... -e '{"ado_agent_numbers": [1, 2, 3]}'
# named transacthub-agent-04-1, -2, -3; to keep an existing name for agent 1:
#   -e '{"ado_agent_numbers": [1, 2], "ado_agent_names": {"1": "transacthub-agent-04"}}'
```

```bash
ansible-playbook playbooks/setup-agent.yml ... --tags preflight   # check the platform, variables and SERVER (reachable? PAT? pool? agent version?); change nothing
ansible-playbook playbooks/setup-agent.yml ... --tags packages    # tooling only: needs no PAT, pool or server
ansible-playbook playbooks/setup-agent.yml ... --tags agent       # agent only
ansible-playbook playbooks/setup-agent.yml ... --check            # dry run
```

## How this maps to the manual procedure

| # | Manual step | Where | Status |
|---|---|---|---|
| 1 | Create `/var/agents/agent1` | `ado_agents_dir` + `ado_agent_numbers` → `/var/agents/agent<N>`; `ado_agent_root` for one agent in a chosen directory | **Tested** (systemd containers) |
| 2 | Obtain the agent package (configurable version and source) | `ado_agent_version`, `ado_agent_download_url`, or `ado_agent_package_src` for a file on the controller; optional `ado_agent_sha256`; fetched once per host and reused by every agent | Cached/copy paths **tested**; the real download **worked from some containers and was answered 403 by this network's firewall from others** |
| 3 | Extract; ownership and permissions | `unarchive` as the agent user, directory `0755`, credential files forced to `0600` | **Tested** |
| 4 | `./config.sh` non-interactively: URL, PAT auth, pool, agent name, work dir | all parameters configurable; token via the environment, never argv; failures print the agent's own error with the PAT removed | Invocation, PAT handling and failure output **tested** with a stand-in for the registration binary and with the real binary against an unreachable host. **Registration against a real server is untested** |
| 5 | PAT from Vault / secret mechanism; never hardcoded, printed or logged | `vault_ado_pat` or `ADO_PAT`; `no_log`; 0400 staging file deleted afterwards | **Tested**: the PAT is in no output at `-vvv`, and in no process list during registration |
| 6 | `svc.sh install`, `start`, `status` | `agent.yml`, keyed on `.service`; then waits for the unit to be active and prints the journal if it is not | **Tested** with the real `svc.sh`, unit and systemd on Ubuntu 22.04, Debian 12, AlmaLinux 9 (the agent binary was the stand-in). SELinux enforcing was **not** exercised |
| 7 | Install the `packages.txt` tools on CentOS, RHEL, Ubuntu, Debian | `agent_packages` role | **Tested** on 9 distribution images (see Tests) |
| 8 | Idempotency, permissions, failure handling, diagnostics, numbering, several agents | see Idempotency; `ado_agent_numbers` | **Tested**: `changed=0` on re-run, interrupted-run repair, two agents with separate units |
| 9 | Prerequisites, supported OS, package differences | preflight: platform allow-list; systemd; pool/PAT/server; per-distribution package map | **Tested** (mocked facts, real facts for the refusal path, real images for packages) |
| 10 | Agent version vs the server | preflight reads the agent the server ships and stops on a major mismatch | Logic **tested against a mock**; **not** against your server — see Server compatibility |

## What is installed

Every item of `packages.txt` is accounted for in [tests/fixtures/packages-txt-manifest.yml](tests/fixtures/packages-txt-manifest.yml), with its line numbers and what became of it. The test suite fails if an item marked installed is not resolved.

| packages.txt | Debian / Ubuntu | RHEL / CentOS | Notes |
|---|---|---|---|
| `curl`, `git`, `python3` | same names | same names | plus `jq`, `tar`, `gzip`, `unzip`, `openssl`, `acl`, `python3-pip` (and `python3-venv` on Debian family) — what the original playbook installed |
| `mssql-tools`, `unixodbc-dev` | `mssql-tools`, `unixodbc-dev` | `mssql-tools`, `unixODBC-devel` | Microsoft repo; `unixODBC-devel` is in CRB on 9/10 |
| `dotnet-sdk-8.0`, `aspnetcore-runtime-8.0`, `dotnet-runtime-8.0` | same | same | Ubuntu 22.04+: Ubuntu's feed. Ubuntu 20.04, Debian: Microsoft's. RHEL/CentOS: AppStream |
| `dotnet-ef` 8.0.11 | `--tool-path /opt/dotnet-tools`, linked into `/usr/local/bin` | same | not `--global`: that would install into root's home |
| `nodejs`, `npm` | `nodejs` (NodeSource) | `nodejs` (NodeSource) | npm is bundled; the distro `npm` conflicts |
| `maven` (+ `/opt/maven/bin/mvn` link) | `maven` | `maven` | |
| `openjdk-17-jdk` | `openjdk-17-jdk` | `java-17-openjdk-devel` | **RHEL/CentOS 10: `java-21-openjdk-devel`** |
| Docker (`get.docker.com`) | Docker CE repo | Docker CE repo (`/rhel` or `/centos`) | only when `install_docker: true` |
| `kubectl`, `helm`, `yq`, `azcopy` | binary downloads | binary downloads | pinned, same defaults as Core Infra's `jumpservers.yml` |

### Where this differs from `packages.txt`

- **Node 10 → 22.** `setup_10.x` is end of life and not published for any release in the matrix. Set `agent_nodejs_major` for another LTS.
- **JDK 17 is unavailable on RHEL/CentOS 10**; JDK 21 is installed instead and the run says so. Core Infra's `jumpservers` does the same.
- **Debian 11 and 13 are refused**: 11 is end of life and its security archive returns 404; 13 has no `openjdk-17-jdk`.
- **`mssql-tools` stays 17.x**, as `packages.txt` says, so existing pipeline scripts behave as before. Core Infra's `mssql` role installs `mssql-tools18`, which encrypts by default and needs `-No`/`-C` against self-signed servers. Set `agent_mssql_tools_package: mssql-tools18` once pipelines are checked.
- **`dotnet-install.sh` is not used.** The `dotnet-sdk-8.0` package is the route `packages.txt` lists twice; the script installs an unpinned SDK under `/root`.
- **Helm** comes from the release tarball with its published checksum, not from `get-helm-3 | bash`.
- **`azcopy`** is the `aka.ms` "latest" alias, which cannot be pinned: it installs when absent and never upgrades. Point `agent_azcopy_url` at a versioned release for control.
- **The cron clean-up** is not ported: Core Infra's `disk-guard` build-server profile covers docker prune, `_work` clean-up and journald. Install it separately; for it to see the agent, set `ado_agent_root: /var/agents/<name>`.
- **`NuGet.Config`** is in neither repository and holds a PAT. Set `agent_nuget_config_src` to a file outside the repo (or in Vault) and it is installed `0600` for the agent user.

### Other changes to the original playbook

- **Agent download URL.** `vstsagentpackage.azureedge.net` no longer resolves; the default is now `download.agent.dev.azure.com` (`ado_agent_download_url`).
- **`ado_agent_sha256`** is now accepted as a bare digest, as the old README said; `get_url` had rejected it.
- **Agent runtime dependencies** (`libicu`, `libkrb5`, …) are installed from a per-release map. The agent's own `installdependencies.sh` is not used: it has no `libicu72` and fails on Debian 12.
- **`install_docker`** now installs Docker CE from Docker's repository (previously `docker.io`), as `packages.txt` does. It is still `false` by default.

## Variables

Defaults are in `roles/*/defaults/main.yml`; override in inventory or with `-e`. The original names all still work (`ado_org_url`, `ado_agent_pool`, `ado_agent_name`, `ado_agent_version`, `ado_agent_root`, `required_commands`, `required_services`, `install_docker`, and `apt_packages`, which is honoured as extra Debian-family packages).

| Variable | Default | |
|---|---|---|
| `agent_install_{sqlcmd,kubectl,helm,dotnet,nodejs,maven,java,yq,azcopy}` | `true` | switch a tool off |
| `install_docker` | `false` | Docker CE + docker-group access (root-equivalent) |
| `kubectl_version` / `helm_version` / `yq_version` | `v1.30.4` / `3.19.4` / `4.44.5` | |
| `agent_dotnet_ef_version` | `8.0.11` | |
| `agent_nodejs_major` | `22` | |
| `agent_mssql_tools_package` | `mssql-tools` | or `mssql-tools18` |
| `agent_extra_packages`, `_debian`, `_redhat` | `[]` | additional distro packages |
| `agent_crb_repo` | `crb` (CentOS), `*codeready-builder*` (RHEL) | repo enabled for `unixODBC-devel` |
| `agent_manage_services` | `true` | `false` where there is no systemd |
| `ado_agent_numbers` | `[1]` | one agent per number, in `{{ ado_agents_dir }}/agent<N>` |
| `ado_agents_dir` | `/var/agents` | where `agent<N>` directories go (Core Infra's `disk-guard` cleans `/var/agents/*`) |
| `ado_agent_names` | `{}` | number → name overrides; with several agents the default is `<ado_agent_name>-<N>` |
| `ado_agent_root` | `""` | legacy: one agent in exactly this directory; ignores the two above |
| `ado_agent_work_dir` | `_work` | `--work`, relative to each agent's directory |
| `ado_agent_version` | `4.261.0` | **check against the server** — see Server compatibility |
| `ado_agent_download_url` / `ado_agent_package_src` / `ado_agent_sha256` | AzDO CDN / `""` / unset | where the archive comes from; `_package_src` is a file on the controller |
| `ado_agent_server_check` / `ado_agent_enforce_server_version` | `true` / `true` | the preflight questions to the server; whether a known version mismatch stops the run |
| `ado_agent_extra_config_args` | `[]` | extra `config.sh` arguments, e.g. `["--proxyurl", "http://proxy:3128"]` — never the token |
| `ado_agent_keep_archive` | `false` | keep the downloaded archive in `ado_agent_cache_dir` |

## Server compatibility

The agent's major version has to suit the server, and **the default `ado_agent_version` (4.261.0) is not known to suit yours.** Microsoft documents the 4.x agent (.NET 8) for Azure DevOps Services and current Azure DevOps Server, and gives the 3.x agent as the guidance for Azure DevOps Server 2022 and 2020 ([Linux agent page](https://learn.microsoft.com/azure/devops/pipelines/agents/linux-agent), [v4 agent](https://learn.microsoft.com/azure/devops/pipelines/agents/v4-agent)). Releases older than those may need older again. Your server (`<URL>`) does not reveal its version to an anonymous request, so this was **not** determined here.

What the project does about it:

1. **Preflight asks the server** (`ado_agent_server_check`, on by default): from the VM, with the PAT, it reads the agent the server ships (`/_apis/distributedtask/packages/agent?platform=linux-x64`) and compares its major version with `ado_agent_version`.
2. **A known mismatch stops the run**, naming the version to use. Set `ado_agent_enforce_server_version: false` only after you have confirmed the server supports the version you pinned.
3. If the server does not say, the run reports compatibility as **unverified** and carries on — that is not evidence of a mismatch.

To settle it by hand: in the pool, **Agent pools → your pool → New agent → Linux** shows the version the server offers. Pin that: `-e ado_agent_version=<x.y.z>`. If the VM cannot reach `download.agent.dev.azure.com`, download that archive to the controller and pass `-e ado_agent_package_src=/path/vsts-agent-linux-x64-<x.y.z>.tar.gz` (add `ado_agent_sha256`).

> The preflight's REST calls were exercised against a mock, not a real server (see [Not verified here](#not-verified-here)). If your server answers differently, `--tags preflight` will say it could not read the version; use the manual route above.

## Secrets

The PAT is resolved in this order: the Ansible Vault variable **`vault_ado_pat`** if defined (the `vault_` prefix Core Infra's inventory already uses), otherwise the controller's **`ADO_PAT`** environment variable. It is never written to a file in the repository and:

- **never on a command line.** `config.sh` receives it as `VSTS_AGENT_INPUT_TOKEN`, read inside the `config.sh` process from a `0400` file only the agent user can read, which is deleted afterwards whether registration succeeded or not. (`--token <PAT>` would be visible to every user in `ps`.)
- **never in output.** Every task that handles it has `no_log`; the registration task is allowed to fail quietly and its error is printed with the PAT removed from every line.
- **not in `.credentials` for others.** The agent's credential files are set `0600`, owned by the agent user.

```bash
ansible-vault create group_vars/vault.yml          # contains:  vault_ado_pat: "the-pat"
ansible-playbook playbooks/setup-agent.yml ... --ask-vault-pass
```

`group_vars/vault.yml` is in `.gitignore`. Use the minimum PAT scope: **Agent Pools (Read & manage)**. Do not put the PAT in `-e`, an inventory, or `group_vars/all.yml`.

## Idempotency, failure handling and existing agents

Re-running is safe. Packages and repositories converge; pinned binaries (`kubectl`, `helm`, `yq`, `dotnet-ef`) are replaced only when the installed version differs from the pin. Each step of each agent is guarded by the state it depends on, so a run that stopped part way **resumes where it stopped**:

| State found | What a re-run does |
|---|---|
| nothing | creates the directory, extracts, registers, installs and starts the service |
| registered, no service (interrupted run) | installs and starts the service — the original skipped it forever |
| service installed but stopped | starts it |
| everything in place | changes nothing (`changed=0`) |

If registration fails, the run prints the agent's own error (PAT removed), removes the staged PAT, installs no service, and says to fix the cause and re-run. If the service does not become active within `ado_agent_service_retries` × `ado_agent_service_delay` seconds, the run fails with the last journal lines.

An already-configured directory is never reconfigured: the run **fails** if it holds a different agent name, pool or server. It does not upgrade an existing agent or reconcile a changed pool; follow your organization's agent removal procedure rather than deleting `.agent`. `--replace` applies only to first configuration. If `svc.sh install` stopped part way and left a unit file but no `.service` file, run `./svc.sh uninstall` in that directory first.

**Migrating from the earlier version:** the default directory is now `/var/agents/agent<N>`, not `/opt/azure-pipelines-agent`. If an agent is found at the old location, preflight refuses to start a second one; set `ado_agent_root: /opt/azure-pipelines-agent` to keep managing it there (that provisions one agent in exactly that directory, as before).

## Verification

The run fails if a required command is missing or the agent service status check fails. Afterwards:

1. Organization settings → Agent pools → your pool → Agents: the agent should be **Online**.
2. Run a small pipeline on that pool that exercises the tools it needs.
3. On the VM: `systemctl list-units 'vsts.agent*'`; logs under `_diag` in the agent root.

Other operational notes: keep SSH host-key checking on, use a unique agent name per VM, and validate in a non-production pool first. Docker socket access is root-equivalent; enable `install_docker` only for trusted workloads.

## Integrating into Core Infra

Nothing in this folder touches Core Infra. To add it by hand:

1. Copy `roles/agent_packages` and `roles/ado_agent` to `ansible/roles/`.
2. Copy `integration/core-infra/playbooks/agentservers.yml` to `ansible/playbooks/`.
3. Add the `agentservers` group from `integration/core-infra/inventory-agentservers.example.yml` to `ansible/inventory.yml`. Use a key or Vault — do not copy the plain-text `ansible_ssh_pass` pattern.
4. Optionally add `playbooks/agentservers.yml` to `run.sh`, after "Jump Servers (Linux)", as the other playbooks are.
5. Run `ansible-playbook -i inventory.yml playbooks/agentservers.yml --tags preflight`, then without `--tags`.

Things to know when both sets of roles run on one host:

- The Microsoft APT repository uses the same keyring, file name and line as `roles/mssql`, so it is registered once. On RHEL/CentOS both write `msprod.repo`; this role adds `exclude=dotnet*` to it (Microsoft's RHEL 9 feed also publishes `dotnet-sdk-8.0`, which would mix with AppStream's). If `roles/mssql` runs afterwards it overwrites the file without the exclude; the next run of this role restores it.
- `roles/jumpservers` hard-codes `download.docker.com/linux/ubuntu` for all Debian-family hosts and `/linux/centos` for all RedHat hosts, and `roles/mssql` and `roles/jumpservers` use `packages.microsoft.com/ubuntu/…` for Debian. These roles use the correct distribution path. Core Infra's behaviour on Debian and RHEL hosts is unverified here.
- `ansible/group_vars/all.yml` is empty in Core Infra, so these roles carry all their defaults.

## Tests

```bash
# 1. no containers, no hosts (needs ansible-core, python3; yamllint and ansible-lint if present)
tests/run-mocked.sh

# 2. real distribution images in throwaway containers (needs Docker)
docker build -f tests/docker/Dockerfile.controller -t agent-prov-ctl tests/docker
tests/run-matrix.sh                                  # packages, on 9 distribution images
AGENT_TARBALL=/path/vsts-agent-linux-x64-4.261.0.tar.gz tests/run-service-test.sh   # the agent role, on real systemd
```

`tests/run-mocked.sh` runs: syntax checks; yamllint; ansible-lint; `test_resolution.yml` (real role files against mocked facts: 9 supported and 17 unsupported platforms, every `packages.txt` item); `test_instances.yml` (agent numbering, names, directories: 7 valid and 11 invalid cases); `test_server_check.yml` (the server preflight against `mock_tfs.py`, 9 cases) — run at `-vvv` and followed by a search of the whole output for the mock's fake PATs, plain and base64.

`tests/run-matrix.sh` has three phases per target (see its header): `resolve` registers the real repositories and dry-runs the install; `agent` installs the runtime dependencies and starts `Agent.Listener --version`; `full` installs everything, runs again and requires `changed=0`, then runs each tool. RHEL is tested on AlmaLinux with the distribution fact overridden.

`tests/run-service-test.sh` runs the `ado_agent` role against **real systemd** (Ubuntu 22.04, Debian 12, AlmaLinux 9) through nine scenarios: two agents, interrupted-run repair, idempotency, registration failure, service crash, old-directory guard, existing-agent guard, the real agent against an unreachable server, and a tooling-only run. **Only `bin/Agent.Listener` is a test double** (it writes what a successful registration leaves behind); `config.sh`, `svc.sh`, the unit, systemd and the process list are real. Behind a TLS-inspecting proxy set `EXTRA_CA`; see each script's header for the other variables.

## Not verified here

- **Registration against a real Azure DevOps Server / TFS.** It needs a real PAT and a pool; the tests use a stand-in for `bin/Agent.Listener` plus the real binary against an unreachable host. Whether the agent leaves its credential files with the modes the role then enforces is therefore also unobserved.
- **The server preflight against a real server.** Exercised against `tests/mock_tfs.py` only. In particular the `packages/agent` endpoint's shape on your server version is assumed from documentation; if it answers differently the check reports "unverified" rather than failing. The server's version could not be read anonymously.
- **Agent 3.x.** Nothing was run with a 3.x agent; only 4.261.0 was exercised.
- **The agent download through your firewall** — it was refused with 403 from some containers here.
- **SELinux enforcing** on RHEL/CentOS (`svc.sh` calls `chcon` itself; read from the 4.261.0 template, not run).
- **RHEL itself:** subscription repositories, RHUI, and the real CodeReady Builder repo id. AlmaLinux stands in.
- The NodeSource signing key (blocked on the development network); the repository layout and package name are checked, the signature is not.
- Ubuntu newer than 24.04 and Debian newer than 12.

## Troubleshooting

- **"… is not supported"** — preflight refused the platform; the message lists what is supported.
- **`No match for argument: unixODBC-devel`** (RHEL) — CRB is not enabled; set `agent_crb_repo` to the repository id from `dnf repolist --all`.
- **NodeSource key download fails or returns HTML** — firewall; mirror the key and set `agent_nodesource_key_url`.
- **APT/DNF failure** — check DNS, proxy and mirror access, then re-run with `--tags preflight`.
- **Preflight: "could not be reached" / "PAT was rejected" / "lacks the Agent Pools scope" / "no agent pool named"** — the server check separates these; fix what it names. A 404 usually means the URL needs its collection, e.g. `https://host:8082/tfs/DefaultCollection`.
- **Preflight: "does not match what the server ships"** — pin the agent version the message names (see Server compatibility).
- **Registration failed** — the run prints `config.sh`'s own output with the PAT removed; the agent's log is under `<agent dir>/_diag/`. Fix the cause and re-run; it resumes.
- **Agent will not start** — the run prints the journal; otherwise `journalctl -u 'vsts.agent*'` and `_diag` under the agent directory.
- **Pipeline cannot find a tool** — add its package to `agent_extra_packages`, and its command to `required_commands`.
