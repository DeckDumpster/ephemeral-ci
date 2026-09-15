# Ephemeral CI Runner — Proxmox scripts

Three scripts that a GitHub Actions workflow calls directly — reaching the
Proxmox API over the tailnet — to clone a VM template into a one-shot runner
and destroy it afterwards. They live here rather than inline in workflow YAML
so that every API call can be exercised by hand and a red CI run can be
reproduced locally.

## What each script does

### `provision.sh <runner-label> <registration-token> <repo-url>`

Runs anywhere on the tailnet that can reach the Proxmox HTTP API. Clones a VM
template into a new one-shot runner, starts it, waits for the qemu guest agent
to become ready, and delivers the registration credentials by writing
`/run/gh-runner-init` inside the guest via `POST .../agent/file-write`. No
files are written to the hypervisor filesystem.

The registration token is written to a temp file and passed via
`--data-urlencode "content@FILE"` so it never appears in any curl process argv
(visible to `ps aux` on the hypervisor). The temp file is deleted immediately
after the call.

1. Picks a VMID from `/cluster/nextid` and retries on collision.
2. Clones the template (`full=0`, pool `ephemeral-ci`).
3. Writes `<VMID> <label> <epoch>` to the ledger file and prints the VMID on
   **stdout** before any step that can fail post-clone.
4. Starts the VM.
5. Polls `POST .../agent/ping` until the guest agent answers.
6. Writes `RUNNER_LABEL`, `RUNNER_TOKEN`, `RUNNER_URL` and `RUNNER_GROUP` to
   `/run/gh-runner-init` inside the guest via `POST .../agent/file-write`.

The file lands `root:root` in the guest; the path unit must `chown runner:runner
/run/gh-runner-init` before starting `ephemeral-runner.service` (see `TEMPLATE.md`).

The guest's path unit (`ephemeral-runner.path`) watches `/run/gh-runner-init`
and triggers `ephemeral-runner.service`, which reads the file and self-registers.
The registration uses `--ephemeral` and `--labels <runner-label>`.
Without `--ephemeral` the runner stays registered after its job and the repo
accumulates a permanently-offline runner entry per CI run, which still carries
its labels and causes later jobs targeting those labels to queue against a
runner that no longer exists.

### `teardown.sh <vmid>`

Runs on the Proxmox host. Destroys one runner VM via the Proxmox HTTP API
and removes its ledger line. Designed to run under `if: always()` — exits
zero if the VM is already gone so a cancelled run does not report a spurious
failure.

Five guards prevent destroying the wrong thing, applied in order:

- Empty or non-numeric argument → exit non-zero, API is never called.
- VMID equals `TEMPLATE_VMID` → exit non-zero.
- VM does not exist (API returns 404) → clean up stale ledger line and
  exit 0. This runs **before** the ledger guard so a second teardown call
  (after the first removed the ledger line) exits 0 rather than 1. A
  connection error or auth failure is not treated as "already gone" — those
  propagate as failures so a broken API cannot silently claim success.
- VMID not in the ledger → exit non-zero.
- VM name does not match `gh-runner-<vmid>` (read from the API config JSON,
  not from `qm` output) → exit non-zero.

After stopping, teardown polls the stop task's status and confirms the VM
is stopped before issuing DELETE. A guest that ignores ACPI shutdown is
force-stopped rather than passed straight to a destroy that would be
refused.

### `reap.sh [--max-age-hours N] [--dry-run]`

Runs on the Proxmox host. Destroys every VM named `gh-runner-*` older than N
hours (default 4). `if: always()` does not cover a run that GitHub drops, a
cancellation landing between clone and output, or the hypervisor rebooting
mid-run; without a reaper those become orphan VMs discovered as a
storage-full alert weeks later.

Age is read from the ledger (authoritative) and falls back to the creation
timestamp in `qm config` for a VM whose ledger line was lost — the lost-ledger
case is exactly the one that produces orphans, so falling back rather than
skipping is the correct tradeoff.

`--dry-run` prints what it would destroy and touches nothing. Run it first
whenever the ledger looks suspicious.

## Where these scripts run

**Not on the Proxmox host.** They run in GitHub-hosted jobs that join the
tailnet and call the Proxmox HTTP API at `$PVE_API_HOST`. Nothing is installed
on the hypervisor, and nothing there needs updating when these files change —
which is the point: a copy on the host is a second source of truth that drifts
from `main`.

The hypervisor holds exactly two things: the VM template, and the `pveum` role,
pool, user and API token that scope what the workflow can reach.

Earlier revisions of this document described copying the scripts into
`/usr/local/lib/gh-ephemeral-runner` and pinning an SSH key to a
forced-command dispatcher. That design is retired. If you followed it, the
files there are inert — remove them, along with any `authorized_keys` entry
for the runner user.

### Repository secrets and ACL confinement

The workflow holds two Proxmox API credentials as GitHub Actions repository
secrets: `PVE_TOKEN_ID` and `PVE_TOKEN_SECRET`. This is the transport that
replaced the SSH key; there is no longer an SSH keypair, no `authorized_keys`
entry, and no forced-command dispatcher on the hypervisor.

**deckdumpster is a public repository.** A same-repo pull request from any
contributor runs the workflow file as edited in that PR with full access to
repository secrets. Treat `PVE_TOKEN_ID` and `PVE_TOKEN_SECRET` as reachable
by any PR author.

**The containment is the pveum ACL, not the transport.** The token is granted
the `GHRunner` role on exactly three paths:

```
/pool/ephemeral-ci
/storage/local-lvm
/sdn/zones/localnetwork/vmbr0
```

Nothing else on the host is reachable, even if the token leaks. The ACL is
the whole defence — keep that scope in mind when extending the `GHRunner`
role or adding paths. See "Proxmox user permissions" below for the full role
definition and the `pveum acl modify` commands that set this scope.

> **Pending (db-58r2):** once the guest file-write path is proven, drop
> `VM.GuestAgent.Unrestricted` from the `GHRunner` role, leaving
> `VM.GuestAgent.Audit` and `VM.GuestAgent.FileSystemMgmt`. Arbitrary guest
> command execution is not needed to write one file, and this token is
> reachable from a public repo's PR.

### VM template requirements

The template VM (default VMID set by `TEMPLATE_VMID`, see below) must have:

- **`agent: 1` in the Proxmox VM config** (set before sealing with
  `qm set <TEMPLATE_VMID> --agent 1`). This is the host-side half of the QEMU
  guest agent channel; the guest-side half is `qemu-guest-agent` installed and
  running inside the VM. Without this line the channel is never opened and
  `provision.sh`'s agent wait burns its full `AGENT_TIMEOUT` and exits 1.
- **QEMU guest agent installed and enabled** (`apt install qemu-guest-agent`).
- **A `runner` user** that the path unit can chown the token file to.
- **An `ephemeral-runner.path` unit** watching `/run/gh-runner-init` that
  chowns the file to `runner:runner` and starts `ephemeral-runner.service`.
  See `TEMPLATE.md` for the full build step.

## Environment variables

The scripts' built-in default for `TEMPLATE_VMID` is `101`, which is **not**
the live template — set it explicitly. In CI it comes from the organisation
variable `TEMPLATE_VMID`. Leaving it at the default means cloning a stale
image and, worse, leaving the real template unprotected by the id-based
guard.

All three scripts read `TEMPLATE_VMID` (default `101`). The template VMID is
never acted on — it is the thing being cloned. `teardown.sh` and `reap.sh` also
read `PVE_POOL` (default `ephemeral-ci`); see "How a VM is proved to be ours"
below.

### Credentials (all three scripts)

All three scripts share the same credential contract and all source `$CRED_FILE`
before making any API call. An unset variable and a dead API look identical at
the curl layer; sourcing from a file and checking at startup is what names the
missing one before curl is ever called.

| Variable | Required | Default | Purpose |
|---|---|---|---|
| `CRED_FILE` | no | `/etc/gh-ephemeral-runner/token` | File sourced for the API credentials |
| `PVE_NODE` | **yes** | — | Proxmox node name |
| `PVE_TOKEN_ID` | **yes** | — | API token id, e.g. `gh-runner@pve!ephemeral` |
| `PVE_TOKEN_SECRET` | **yes** | — | API token secret UUID |
| `PVE_API_HOST` | no | `localhost` | Proxmox API hostname or IP |
| `PVE_API_PORT` | no | `8006` | Proxmox API port |

A minimal credential file at `/etc/gh-ephemeral-runner/token` (mode `0600`,
owned by `gh-runner`):

```
PVE_NODE=pve
PVE_TOKEN_ID=gh-runner@pve!ephemeral
PVE_TOKEN_SECRET=<uuid from pveum user token add>
```

Set these in the environment the scripts run in. On a Proxmox host running the
scripts directly, export them in the shell or write them to the credential file.
In the GitHub Actions workflow that reaches the host, pass them through the
dispatcher's environment; the exact mechanism is the companion workflow bead's
concern.

### `provision.sh`

| Variable | Default | Purpose |
|---|---|---|
| `CLONE_RETRIES` | `5` | Attempts to find a free VMID before giving up |
| `TASK_TIMEOUT` | `120` | Seconds to wait for a Proxmox UPID task to complete |
| `AGENT_TIMEOUT` | `120` | Seconds to wait for the guest agent to become ready |
| `CRED_FILE` | `/etc/gh-ephemeral-runner/token` | File sourced for the API credentials |

### `teardown.sh`

| Variable | Default | Purpose |
|---|---|---|
| `STOP_TIMEOUT` | `60` | Seconds to wait for orderly stop before force-stopping |
| `STOP_POLL_INTERVAL` | `2` | Seconds between stop-task polls |
| `FORCE_STOP_WAIT` | `5` | Seconds to wait after a force-stop |

### `reap.sh`

| Variable | Default | Purpose |
|---|---|---|
| `GITHUB_TOKEN` | *(required for the busy check)* | GitHub API token |
| `GH_REPO` | *(required for the busy check)* | Repository in `owner/repo` form |

Without `GITHUB_TOKEN` and `GH_REPO`, `reap.sh` runs in a degraded mode: the
busy check is skipped and VM age is the only guard. It says so on stderr.

## How a VM is proved to be ours

There is no ledger. `teardown.sh` and `reap.sh` establish ownership from the
hypervisor, not from a file either of them wrote:

| Check | Source | Refuses when |
|---|---|---|
| name | `GET .../qemu/<vmid>/config` → `.data.name` | not `gh-runner-<vmid>` |
| pool | `GET /pools/<PVE_POOL>` → `.data.members[].vmid` | vmid is not a member |
| template flag | same config → `.data.template` | it is `1`, whatever `TEMPLATE_VMID` says |
| age (`reap.sh` only) | same config → `ctime=` in `.data.meta` | unreadable — the VM is skipped, never destroyed |

`PVE_POOL` defaults to `ephemeral-ci`.

This replaced a ledger file at `/var/lib/gh-ephemeral-runner/active`, which
worked while all three scripts ran on the hypervisor and shared it. It cannot
work now: `provision` and `teardown` are separate jobs on separate ephemeral
runners, so the file `provision.sh` wrote never exists when `teardown.sh`
runs — and `teardown.sh` refused every VM. Every run would have leaked its VM.

Reading the hypervisor is strictly stronger than the ledger was. It cannot go
stale, cannot vanish with a runner, and cannot be forged by anything the
workflow controls. The API token's ACL is already scoped to `ephemeral-ci`, so
the pool check turns an unreachable VM into an explicit refusal with a readable
message rather than a 403 from whichever call happens to run first.

Order matters: name and template are read from the config already fetched, so
they cost nothing and run first. The pool check is the one extra API call and
runs last.

## Scheduled reaper

A scheduled GitHub workflow, not a host cron job — it joins the tailnet the
same way the provision job does and runs `reap.sh` directly.

Reaping something is **not** a success. An orphan means a teardown failed for a
run GitHub already reported green, so the workflow exits non-zero when it
destroys anything, to make that visible.

Do not arm it until `reap.sh`'s template guard is confirmed present: it must
refuse any VM whose config reports `template: 1`, independent of
`TEMPLATE_VMID`. An id is configuration and can be wrong; the template flag is
a fact about the VM.

## Proxmox user permissions

All three scripts use the Proxmox HTTP API with an API token. None of them
shell out to `qm`: `qm` talks to pmxcfs over `/run/pve-cluster/cfs.sock`,
which is gated against non-root users, so a non-root caller gets
`ipcc_send_rec failed` and `Unable to load access control list` on every
command. An API token needs no OS privileges and keeps the `pveum` ACL as a
real enforcement layer — a hole in the dispatcher still cannot reach a VM
outside the pool.

Create the role, pool, user and token on the Proxmox host as root. This
privilege list was verified against `pveum role list` on a PVE 9 host; do not
copy an older list, several entries below are load-bearing:

```bash
pveum role add GHRunner --privs \
    "VM.Allocate,VM.Audit,VM.Clone,VM.Config.CPU,VM.Config.Disk,\
VM.Config.Memory,VM.Config.Network,VM.Config.Options,\
VM.GuestAgent.Audit,VM.PowerMgmt,\
Datastore.AllocateSpace,Datastore.Audit,\
Pool.Audit,Pool.Allocate"

pveum pool add ephemeral-ci
pveum user add gh-runner@pam
pveum user token add gh-runner@pam ephemeral --privsep 1

# Grant the user AND the token. With --privsep 1 a token carries only the
# privileges granted to the token itself, so both sets of grants are required.
for who in "--user gh-runner@pam" "--tokens gh-runner@pam!ephemeral"; do
    pveum acl modify /pool/ephemeral-ci             $who --role GHRunner
    pveum acl modify /storage/local-lvm             $who --role GHRunner
    pveum acl modify /sdn/zones/localnetwork/vmbr0  $who --role PVESDNUser
done

pveum pool modify ephemeral-ci --vms 101   # the template must be in the pool
```

The token secret is printed once by `pveum user token add` and is not
retrievable afterwards.

Four notes on that privilege list:

- `VM.Allocate` creates and destroys a VMID. Without it the clone fails.
- `VM.GuestAgent.Audit` covers the `ping` and `network-get-interfaces` agent
  calls. It does not grant guest command execution, which is correct — nothing
  here needs it.
- `Pool.Allocate` is required because cloning with `--pool` changes pool
  membership. Granted at `/pool/ephemeral-ci` it reaches that pool and no other.
- There is deliberately no `VM.Monitor`. It gates the QEMU monitor, which none
  of these scripts touch, and it is not a valid privilege on current PVE —
  `pveum role add` rejects the entire command with
  `invalid format - invalid privilege 'VM.Monitor'`.

The bridge grant on `/sdn/zones/localnetwork/vmbr0` is **required, not
optional**. PVE 8.2+ gates bridge attachment; without it the clone fails with
HTTP 403 and `Permission check failed (/sdn/zones/localnetwork/vmbr0,
SDN.Use)`. Replace `local-lvm` with whatever storage the template's disk
actually lives on — check with
`qm config 101 | grep -E '^(scsi|virtio|sata)0:'`.

Scoping to `/pool/ephemeral-ci` means the token can only see the template and
live clones; other VMs on the host are unreachable even if the token leaks.
