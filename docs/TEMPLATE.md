# Proxmox VM template build sheet — ephemeral CI runner

This document describes exactly what the Proxmox VM template must contain so
that every ephemeral runner cloned from it can execute `bash deploy/ci.sh` to
completion without further provisioning. Build the template by hand in a
Proxmox console, validate it with the checklist at the bottom, then convert
it to a template. **Do not register the GitHub Actions runner inside the
template.** Registration is per-token and per-run; a template with a
pre-registered runner clones into N VMs all claiming to be the same agent.

---

## The non-root user with lingering — the part everybody gets wrong

`deploy/ci.sh` exports `XDG_RUNTIME_DIR=/run/user/$(id -u)` and drives
everything downstream as rootless Podman through `systemctl --user`.
`deploy/setup.sh:231` checks `loginctl show-user "$USER" -p Linger` and
prints a warning if lingering is not set; `deploy/setup.sh:106` writes
Quadlet units to `$HOME/.config/containers/systemd/`, which systemd only
picks up inside a live user session.

**What this means for the template:**

1. The runner must run as an ordinary non-root user (call it `runner`).
2. Lingering must be enabled for that user:
   ```bash
   sudo loginctl enable-linger runner
   ```
   Confirm with `loginctl show-user runner -p Linger` → `Linger=yes`.
3. A real user D-Bus session must be present when the runner agent starts.
   The standard way with systemd is `systemctl --user …` from within a
   lingering session, which `XDG_RUNTIME_DIR` must point into correctly.

A root runner, or a user without lingering enabled, fails deep inside
`deploy/setup.sh` with a `systemctl --user` error that looks nothing like
"linger not set." Lingering is the first thing to check when CI fails
before it reaches the image-build step.

---

## Proxmox VM configuration — run from the hypervisor

These steps configure the template's Proxmox config and must be done from the
hypervisor, not inside the guest. Run them before sealing. Clones inherit the
VM config from the template, so every runner gets these settings without
additional `qm set` calls.

### Cloud-init drive — required for token injection

`provision.sh` injects the registration token at clone time by writing a
cloud-init user-data snippet and attaching it to the cloned VM. This only
works if the **template** has a cloud-init drive in its config; without one
there is nowhere for Proxmox to attach the injected data, and the cloned VM
boots with no token, `start-runner.sh` exits 1, and the runner never
registers.

The existing `ide2: none,media=cdrom` placeholder is not a cloud-init drive.
Replace it on the template before sealing:

```bash
# Replace 'local-lvm' with the storage pool your template disk uses
# (check with: qm config <TEMPLATE_VMID>).
qm set <TEMPLATE_VMID> --ide2 local-lvm:cloudinit
```

Clones inherit the drive slot from the template. `provision.sh` then calls
`qm set <CLONE_VMID> --cicustom "user=local:snippets/gh-runner-<VMID>.yaml"`
after the clone to attach the per-run user-data.

Confirm:

```bash
qm config <TEMPLATE_VMID> | grep -q '^ide2:.*cloudinit' \
    && echo "PASS: cloud-init drive present" \
    || echo "FAIL: run 'qm set <TEMPLATE_VMID> --ide2 <storage>:cloudinit'"
```

### Serial console — required for headless diagnosis

Without a serial console, `qm terminal <VMID>` returns
`unable to find a serial interface`. When a runner VM fails to register or
hangs at boot, the serial console is the only way to read the boot log without
pulling the VGA framebuffer through the QEMU monitor.

Add the serial device to the template:

```bash
qm set <TEMPLATE_VMID> --serial0 socket
```

And enable `ttyS0` in the guest kernel command line (run inside the guest
before sealing):

```bash
sudo sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet console=ttyS0"/' /etc/default/grub
sudo update-grub
```

Confirm from the hypervisor:

```bash
qm config <TEMPLATE_VMID> | grep -q '^serial0: socket' \
    && echo "PASS: serial console present" \
    || echo "FAIL: run 'qm set <TEMPLATE_VMID> --serial0 socket'"
```

To verify it works, run `qm terminal <CLONE_VMID>` against a booted clone —
it should open a shell, not print `unable to find a serial interface`.

### QEMU guest agent channel — agent: 1

```bash
qm set <TEMPLATE_VMID> --agent 1
```

This is the **host-side half** of the QEMU guest agent channel. It exposes
the virtio-serial device the guest-side `qemu-guest-agent` service talks over.
Without it the agent can be installed and running inside the guest and still
never answer, because the channel does not exist. `provision.sh`'s readiness
loop blocks on `qm guest cmd ping`; without the channel it burns its full
`AGENT_TIMEOUT` (default 120 s) and exits 1 after the VM has already been
cloned and started.

Confirm:

```bash
qm config <TEMPLATE_VMID> | grep -q '^agent: 1' \
    && echo "PASS: agent: 1 set" \
    || echo "FAIL: run 'qm set <TEMPLATE_VMID> --agent 1'"
```

---

## Packages and tooling

Install all of these before converting to a template. The rationale for each
follows; do not trim the list without re-reading the script it came from.

### Podman (rootless-capable)

```bash
sudo apt install -y podman uidmap slirp4netns fuse-overlayfs
```

Rootless Podman requires:
- `uidmap` / `newuidmap` — subordinate UID/GID mapping. Without it,
  `podman run` fails with "newuidmap not found".
- `slirp4netns` or `pasta` — rootless networking. Podman 4.x defaults to
  `pasta` when available; either works. On Debian/Ubuntu: `slirp4netns` is
  the safe choice and is in the default repos.
- `fuse-overlayfs` — rootless overlay storage driver. Without it Podman
  falls back to `vfs` (extremely slow; a ~983 MB builder stage takes
  minutes where overlay takes seconds).

After installing, set up `/etc/subuid` and `/etc/subgid` for the runner user
if they are not already present:
```bash
sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 runner
```
Confirm with `podman unshare cat /proc/self/uid_map` as the runner user.

**Minimum Podman version: 4.4.** Quadlet `.container` file support was added
in Podman 4.4. Older versions silently ignore `.container` files —
`systemctl --user start mtgc-<instance>` succeeds but starts nothing, and
every subsequent `podman port` call returns empty. On Ubuntu 22.04 the repo
version is 3.4; install from the Kubic OBS repo or the
`ppa:projectatomic/ppa` PPA to get ≥ 4.4.

**Minimum systemd version: 239.** User-mode systemd generators (the
mechanism Quadlet uses) were introduced in systemd 239. Ubuntu 22.04 ships
systemd 249 (fine); Ubuntu 20.04 ships 245 (fine). Confirm with
`systemctl --version`.

### uv

```bash
curl -LsSf https://astral.sh/uv/install.sh | sh
```

`deploy/ci.sh` calls `uv sync` and `uv run pytest …` without installing uv
itself. Install as the runner user so `~/.local/bin/uv` is on `PATH`.
Confirm with `uv --version`.

### Playwright / Chromium system libraries

`deploy/ci.sh` runs:
```bash
uv run shot-scraper install
```
This downloads the Chromium binary but **not** its shared-library
dependencies. Those must be present in the OS image. Install them before
baking the template:

```bash
sudo apt install -y \
    libnss3 libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 \
    libxkbcommon0 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 \
    libgbm1 libasound2 libpango-1.0-0 libpangocairo-1.0-0
```

Without these, `shot-scraper install` succeeds but the first Playwright
launch fails with `error while loading shared libraries: libnss3.so`.
That failure happens mid-suite, long after everything looks fine.

### git, curl, jq

```bash
sudo apt install -y git curl jq
```

`deploy/ci.sh` and several deploy scripts call `curl` and `jq` directly.
`git` is required by the GitHub Actions runner and for `uv` operations that
inspect the repo.

### qemu-guest-agent — enable and start it (guest-side half)

```bash
sudo apt install -y qemu-guest-agent
sudo systemctl enable --now qemu-guest-agent
```

The Proxmox `provision.sh` script waits for the guest agent to answer before
returning. A template without the agent enabled makes every provisioning call
time out. **Enable and start it inside the template — not just install it —
so the service comes up on every clone without further configuration.**

Confirm with `systemctl is-active qemu-guest-agent` → `active`.

The host-side half — `agent: 1` in the Proxmox VM config — is set in the
"Proxmox VM configuration" section above. Both halves must be present: the
package makes the agent run inside the guest; the VM config exposes the
virtio-serial channel the agent communicates over.

### GitHub Actions runner — unpack, do not register

Download the runner tarball and unpack it for the runner user. **Stop
before `./config.sh`.** Registration binds to a token that expires and to a
runner name that must be unique; a pre-registered template clones into N
runners all presenting the same identity, and GitHub refuses all but the
first.

```bash
sudo -u runner mkdir -p /home/runner/actions-runner
cd /home/runner/actions-runner
# Replace <VERSION> with the latest from github.com/actions/runner/releases
sudo -u runner curl -LO https://github.com/actions/runner/releases/download/v<VERSION>/actions-runner-linux-x64-<VERSION>.tar.gz
sudo -u runner tar xzf ./actions-runner-linux-x64-<VERSION>.tar.gz
sudo -u runner rm ./actions-runner-linux-x64-<VERSION>.tar.gz
```

Confirm:

```bash
test -s /home/runner/actions-runner/run.sh \
    && echo "PASS: runner tarball unpacked" \
    || echo "FAIL: run.sh not found — unpack the tarball"
test ! -f /home/runner/actions-runner/.runner \
    && echo "PASS: runner not pre-registered" \
    || echo "FAIL: runner is registered — re-image from an unregistered copy"
```

Registration happens at boot on each clone, via `/home/runner/start-runner.sh`.
`provision.sh` delivers both that script and the token into the booted guest
through the qemu guest agent; by the time any job code runs, the token is spent.

### /home/runner/start-runner.sh — delivered, not baked

**Do not bake this script into the template.** It lives in the repository at
`scripts/guest/start-runner.sh` and `provision.sh` writes it
into the guest on every run, immediately before writing
`/run/gh-runner-init` — the path unit fires on that second write, so the
script is always in place first.

That is deliberate. Baking it in means every change to the registration logic
costs a clone, an edit and a reseal of the template; shipping it from the
repository makes the script version-controlled, reviewable in a PR, and free
to change. The template carries only what genuinely cannot be delivered at
run time: the unpacked runner, `qemu-guest-agent`, and the path unit.

The snippet below is retained as a reference for what the guest ends up
running. The authoritative copy is the file in the repository.

It replaces any earlier version of this file. The template's prior version
hard-coded a long-lived org-scoped PAT:

```
PAT="github_pat_YOUR_TOKEN_HERE"     # long-lived, org-scoped, baked into the image
```

**The runner executes the code it is testing.** Any CI job can read that
file. The fix keeps the shape — a script that runs at boot, registers
ephemerally, and starts the runner — but removes the credential: the
hypervisor mints a short-lived registration token and injects it at clone
time via cloud-init. By the time any job code runs, the token is spent and
the file it arrived in has been deleted.

```bash
sudo tee /home/runner/start-runner.sh > /dev/null << 'SCRIPT'
#!/usr/bin/env bash
#
# Ephemeral GitHub Actions runner — self-registration and startup.
# Called by start-runner.service at boot after cloud-init has written
# /run/gh-runner-init via write_files (owner runner:runner, mode 0600).
#
# The registration token is short-lived (~1 h) and repo-scoped; it is
# injected at clone time by provision.sh so it is never baked into the
# image. The file is deleted immediately after sourcing — before config.sh
# runs — so no job code can read it.
set -euo pipefail

RUNNER_DIR=/home/runner/actions-runner
INIT_ENV=/run/gh-runner-init

if [ ! -f "$INIT_ENV" ]; then
    echo "start-runner: $INIT_ENV not found — cloud-init did not inject runner config" >&2
    # Stay up so the reaper's age window can collect this VM.
    # Do NOT power off — that destroys the evidence.
    exit 1
fi

# Source before deleting so the values are in memory, not on disk.
# shellcheck source=/dev/null
source "$INIT_ENV"
rm -f "$INIT_ENV"

: "${RUNNER_TOKEN:?start-runner: RUNNER_TOKEN not set in gh-runner-init}"
: "${RUNNER_LABEL:?start-runner: RUNNER_LABEL not set in gh-runner-init}"
: "${RUNNER_URL:?start-runner: RUNNER_URL not set in gh-runner-init}"

cd "$RUNNER_DIR"

# --ephemeral is not optional: without it a completed run leaves a
# permanently-offline runner entry in the repo, and subsequent jobs targeting
# this runner's labels queue against a runner that no longer exists.
# --url scopes the runner to the repository, not the organisation; an
# org-scoped runner is eligible for jobs from every repository in the org.
if ! ./config.sh \
        --unattended \
        --ephemeral \
        --labels "$RUNNER_LABEL" \
        --url "$RUNNER_URL" \
        --token "$RUNNER_TOKEN"; then
    echo "start-runner: config.sh failed — staying up for reaper collection" >&2
    # Do NOT power off — that destroys the evidence.
    exit 1
fi

# Run the job, then let the service exit. teardown.sh destroys the VM after
# the workflow step completes.
exec ./run.sh
SCRIPT
sudo chown runner:runner /home/runner/start-runner.sh
sudo chmod 755 /home/runner/start-runner.sh
```

Enable the service that calls it at boot (create
`/etc/systemd/system/start-runner.service` if it does not already exist):

```bash
sudo tee /etc/systemd/system/start-runner.service > /dev/null << 'UNIT'
[Unit]
Description=GitHub Actions ephemeral runner
After=network-online.target cloud-init.service
Requires=network-online.target

[Service]
User=runner
WorkingDirectory=/home/runner/actions-runner
ExecStart=/home/runner/start-runner.sh
Restart=no
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT
sudo systemctl daemon-reload
sudo systemctl enable start-runner.service
```

Confirm:

```bash
test -s /home/runner/start-runner.sh \
    && echo "PASS: start-runner.sh present" \
    || echo "FAIL: write /home/runner/start-runner.sh (see build step above)"
test -x /home/runner/start-runner.sh \
    && echo "PASS: start-runner.sh executable" \
    || echo "FAIL: sudo chmod 755 /home/runner/start-runner.sh"
systemctl is-enabled start-runner.service \
    && echo "PASS: start-runner.service enabled" \
    || echo "FAIL: sudo systemctl enable start-runner.service"
```

---

## Disk size

`deploy/ci.sh` calls `deploy/diskcheck.sh --floor` before any build work.
The default floor is `MTGC_DISK_FLOOR_GB=10`, and the check fails the run
rather than letting it proceed to a silent mid-build crash.

On top of that floor, a full CI run writes:

| What                                             | Approximate size |
|--------------------------------------------------|-----------------|
| OS (Debian/Ubuntu minimal)                       | 5 GB            |
| GitHub Actions runner                            | 1 GB            |
| Python packages (`uv sync` + dev deps)           | 2 GB            |
| `uv` cache (`~/.cache/uv`)                       | 1 GB            |
| Playwright / Chromium browser                    | 500 MB          |
| Container image builds — builder stage (×2)      | 2 GB            |
| Container image builds — runtime stage (×2)      | 1.5 GB          |
| Test data volume + WAL                           | 500 MB          |
| Podman image/layer bookkeeping                   | 500 MB          |
| Mandatory headroom floor                         | 10 GB           |
| **Total**                                        | **~24 GB**      |

The factor-of-two on image builds is because `deploy/store-isolation-gate.sh`
runs a **complete** `deploy/setup.sh --test` (including a full image build)
into a probe store before the real CI run does the same into the default
store. Both builds run before the isolation gate tears its probe store down.

The builder stage alone is ~983 MB (noted in `deploy/store-isolation-gate.sh`).
`--full 0` in Proxmox creates a **linked clone**, so the clone is thin at
creation time but the guest still sees — and can fill — the template's full
disk. Set the template disk to **40 GB** to leave comfortable headroom for
concurrent runs, image-layer accumulation, and the 10 GB mandatory floor.

---

## Container store — what to configure (and what the isolation gate needs)

`deploy/ci.sh` sources `deploy/store-lib.sh` and calls
`mtgc_store_load_config`, which reads `~/.config/mtgc/store.env`. On the
shared deployment box, `MTGC_STORE_ROOT` redirects non-prod container builds
off the disk prod runs from. **On a single-tenant ephemeral VM there is no
prod to protect**, so leaving `store.env` unconfigured is correct — the
default Podman store under `$HOME` is the only store, and CI writes to it.

**Does `deploy/store-isolation-gate.sh` pass without `store.env`?**

Yes. When `MTGC_STORE_ROOT` is unset and `store.env` is absent, the gate
selects `${TMPDIR:-/tmp}/mtgc-store-gate-$$` as its probe store. It passes
the probe path explicitly to `deploy/setup.sh` via `MTGC_STORE_ROOT="$PROBE"`,
so `setup.sh` writes the generated Quadlet's `GlobalArgs=` to point at that
probe directory. The gate's positive assertions confirm:
- the Quadlet names the probe store (not the default store),
- the image exists in the probe store, and
- the probe store grew by at least 256 MB.

The gate's negative assertions confirm nothing landed in
`$HOME/.local/share/containers` (the default store under test).

If probe and default store share the same filesystem (common on a VM with one
disk), the gate prints a note but does **not** fail — it proves the stores
are separate *directories*, which is sufficient on a single-tenant machine
where the only concern is correctness, not disk isolation.

**Do not create `store.env` in the template.** A template with a pre-baked
`MTGC_STORE_ROOT` pointing at a path that doesn't exist on the clone's disk
will break `setup.sh` with a path validation error the moment a runner starts.

---

## Networking

The ephemeral VM needs outbound internet access only:
- **GitHub** (`github.com`, `api.github.com`, `*.actions.githubusercontent.com`)
  for the runner agent, checking out code, and downloading release tarballs.
- **Container registries** (`ghcr.io`, `registry-1.docker.io`) for base
  images (`python:3.12-slim`, `ghcr.io/astral-sh/uv:latest`).
- **PyPI / uv** for `uv sync` and `uv run shot-scraper install`.

The Proxmox hypervisor's guest agent channel is used by `provision.sh` to
reach the VM; that works over the hypervisor bus, not the network, so no
Tailscale or tailnet membership is required for the guest. **Leave Tailscale
out of the template.** Every ephemeral device that joins the tailnet must be
cleaned up, and these VMs are created and destroyed automatically.

If your Proxmox host is already on the tailnet and the VM is on a Proxmox
bridge with NAT, the VM gets outbound internet through the host's NAT — no
additional configuration needed. Confirm with `curl -s https://github.com`
from inside the template before converting it.

---

## Verification checklist

The checklist has two parts. **Host-side checks** (H1–H5) run from the
Proxmox hypervisor; H1–H3 run against the template config (VM does not
need to be booted); H4–H5 require a **booted clone** (templates cannot boot).
**Guest-side checks** (1–12) run inside the template VM as the `runner` user.
Both parts must pass before you convert. Each step proves the thing the next
one depends on. The last step is the real workload — a template validated by
"packages installed without error" is a template that fails on its first real
CI run.

Run all host-side checks **against a VM built only from this document** — not
one that was patched by hand while debugging. Both gaps that prompted this
document (missing `agent: 1`, missing `actions-runner/run.sh`) were build
steps absent from an earlier version of this document; no checklist run on a
patched machine could have found them.

### From the Proxmox hypervisor

```bash
# H1. Cloud-init drive is present (required for token injection at clone time).
#     Replace 101 with your actual template VMID.
qm config 101 | grep -q '^ide2:.*cloudinit' \
    && echo "PASS: cloud-init drive present" \
    || echo "FAIL: run 'qm set 101 --ide2 <storage>:cloudinit'"

# H2. agent: 1 is set (host-side half of the QEMU guest agent channel).
#     Without this, the virtio-serial channel is never exposed to the guest and
#     provision.sh's readiness poll burns its full timeout and exits 1.
qm config 101 | grep -q '^agent: 1' \
    && echo "PASS: agent: 1 set" \
    || echo "FAIL: run 'qm set 101 --agent 1'"

# H3. Serial console is present (required for qm terminal to work).
qm config 101 | grep -q '^serial0: socket' \
    && echo "PASS: serial console present" \
    || echo "FAIL: run 'qm set 101 --serial0 socket' and add console=ttyS0 to guest kernel cmdline"

# H4–H5 require a booted clone. Clone the template, start it, wait ~60s for
# boot, then run:
#
# H4. QEMU guest agent channel is open — proves BOTH halves: agent: 1 in the
#     VM config (host side) AND qemu-guest-agent running inside the guest.
#     Step 8 below only proves the service is active; it cannot prove the
#     virtio-serial channel exists.
qm guest cmd <CLONE_VMID> ping \
    && echo "PASS: guest agent channel open" \
    || echo "FAIL: re-check 'qm set 101 --agent 1' and that qemu-guest-agent is running"

# H5. Serial console opens (proves console=ttyS0 is on the kernel cmdline).
#     This opens an interactive session; press Ctrl+O to exit.
qm terminal <CLONE_VMID>
```

### Inside the template VM (as the `runner` user)

```bash
# 1. Linger is on
loginctl show-user runner -p Linger | grep -q 'Linger=yes' \
    && echo "PASS: linger" \
    || echo "FAIL: run sudo loginctl enable-linger runner"

# 2. XDG_RUNTIME_DIR exists and the user session is alive
ls /run/user/$(id -u) \
    && echo "PASS: runtime dir" \
    || echo "FAIL: /run/user/$(id -u) missing — log in or start a session"

# 3. Podman version is ≥ 4.4 (Quadlet support)
podman version --format '{{.Version}}' | awk -F. '$1>4 || ($1==4 && $2>=4) { print "PASS: podman", $0; exit } { print "FAIL: podman", $0, "— need >= 4.4" }'

# 4. Rootless networking works
podman run --rm docker.io/library/alpine echo "PASS: rootless container" \
    || echo "FAIL: rootless Podman — check slirp4netns/pasta and subuid mapping"

# 5. fuse-overlayfs is the storage driver (not vfs)
podman info --format '{{.Store.GraphDriverName}}' | grep -qE 'overlay' \
    && echo "PASS: overlay storage driver" \
    || echo "FAIL: not using overlay — check fuse-overlayfs install"

# 6. systemd user session picks up Quadlet (.container files)
mkdir -p ~/.config/containers/systemd
cat > ~/.config/containers/systemd/probe.container <<'EOF'
[Container]
Image=docker.io/library/alpine
Exec=sleep 10
EOF
systemctl --user daemon-reload
systemctl --user is-enabled probe.service >/dev/null 2>&1 \
    && echo "PASS: Quadlet generator active" \
    || echo "FAIL: Quadlet not active — podman < 4.4 or systemd < 239"
rm ~/.config/containers/systemd/probe.container
systemctl --user daemon-reload

# 7. uv is on PATH
uv --version \
    && echo "PASS: uv" \
    || echo "FAIL: uv not found — install with the install script"

# 8. qemu-guest-agent service is running (guest-side half; H4 above proves
#    the channel itself)
systemctl is-active qemu-guest-agent \
    && echo "PASS: qemu-guest-agent" \
    || echo "FAIL: sudo systemctl enable --now qemu-guest-agent"

# 9. GitHub runner is unpacked at the correct path (not registered).
#    start-runner.sh hardcodes RUNNER_DIR=/home/runner/actions-runner.
#    The file whose absence powered the VM off 18 seconds into every boot:
test -s /home/runner/actions-runner/run.sh \
    && echo "PASS: runner tarball unpacked" \
    || echo "FAIL: unpack the tarball to /home/runner/actions-runner (see build step above)"
test ! -f /home/runner/actions-runner/.runner \
    && echo "PASS: runner not pre-registered" \
    || echo "FAIL: runner is registered — re-image from an unregistered copy"

# 10. start-runner.sh is in place, executable, and the service is enabled.
test -s /home/runner/start-runner.sh \
    && echo "PASS: start-runner.sh present" \
    || echo "FAIL: write /home/runner/start-runner.sh (see build step above)"
test -x /home/runner/start-runner.sh \
    && echo "PASS: start-runner.sh executable" \
    || echo "FAIL: sudo chmod 755 /home/runner/start-runner.sh"
systemctl is-enabled start-runner.service \
    && echo "PASS: start-runner.service enabled" \
    || echo "FAIL: sudo systemctl enable start-runner.service"

# 11. Outbound internet reaches the registry
curl -sfo /dev/null https://ghcr.io/v2/ \
    && echo "PASS: outbound HTTPS to ghcr.io" \
    || echo "FAIL: no outbound internet — check NAT/bridge"

# 12. The real workload — clone the repo and run deploy/ci.sh end to end.
#     This takes 15–25 minutes. It builds two container images, runs three
#     test tiers (unit, integration, UI), and tears everything down.
#     Use a name that will not collide with any real instance.
cd /tmp
git clone https://github.com/DeckDumpster/deckdumpster repo-ci-tmpl
cd repo-ci-tmpl
INSTANCE=ci-tmpl bash deploy/ci.sh \
    && echo "PASS: full CI run" \
    || echo "FAIL: see output above"
cd /tmp
rm -rf repo-ci-tmpl
```

All steps must pass before you convert the VM to a template. If step 12
fails, do not convert — the clones will fail on the same thing, and the error
will look like a code failure rather than a missing prerequisite.

---

## Converting to a template

After all verification steps pass, in the Proxmox console:

1. Shut the VM down cleanly (`sudo poweroff`).
2. Right-click the VM → **Convert to template**.

Clones created with **Linked Clone** (`--full 0`) share the template's base
disk and are created in seconds. Each clone boots as a fresh VM, reads the
token `provision.sh` injected via cloud-init, and self-registers via
`start-runner.sh` before the runner agent picks up its job.

## /tmp must not be a tmpfs

Ubuntu mounts `/tmp` as a tmpfs sized at half of RAM. On an 8G runner that is
3.7G, and a CI suite that stages a container build or a cargo link through it
runs out of room long before the disk does.

The failure does not look like a disk failure. It reaches the suite as
`ld terminated with signal 7 [Bus error]`, or as a disk-floor refusal naming
`/tmp` on a machine whose root filesystem has 79G free:

```
ERROR: only 4G free on /tmp (floor 10G).
tmpfs  3.7G  400K  3.7G  1% /tmp
```

Both consuming repositories have hit this on their first ephemeral run, because
both were developed against a long-lived box with a disk-backed `/tmp` and
nothing in either repository said they depended on that.

Give the template a disk-backed `/tmp`:

```bash
sudo systemctl mask tmp.mount
# verify on the next boot -- "tmpfs" here means it is still a RAM disk
stat -f -c %T /tmp
```

Each repository also guards its own `TMPDIR` in `deploy/ci.sh`, which is what
makes a developer's systemd laptop work too. The guard is not a substitute for
fixing the template: it relocates `TMPDIR`, and anything that hardcodes `/tmp`
rather than honouring it is still on the RAM disk.

## unattended-upgrades must not be running

A per-run VM boots, systemd starts `unattended-upgrades`, and the job's
dependency install starts — in that order, seconds apart. Whoever reaches
`/var/lib/dpkg/lock-frontend` second loses:

```
E: Could not get lock /var/lib/dpkg/lock-frontend. It is held by process 1392 (unattended-upgr)
E: Unable to acquire the dpkg frontend lock (/var/lib/dpkg/lock-frontend), is another process using it?
```

and every package the run needed is simply absent — a compiler, podman, the
browser libraries — so the job dies before the suite is ever reached.

**It is a race, which is the expensive part.** It fails perhaps one run in
several, the same dependency list having installed cleanly on the runs either
side of it, so it reads as a broken list rather than a timing bug. The first
thing anyone does is re-run, and the re-run works.

A machine that lives thirty minutes and is then destroyed has nothing to gain
from unattended upgrades — the template is where its patch level is decided, not
the boot after it:

```bash
sudo systemctl disable --now unattended-upgrades.service
sudo systemctl mask unattended-upgrades.service
sudo apt-get purge -y unattended-upgrades   # or leave it masked
# verify on the next boot -- nothing should hold the lock
sudo fuser -v /var/lib/dpkg/lock-frontend
```

A consuming repository should ALSO pass a lock timeout on every apt call, so it
waits for the holder rather than failing:

```sh
apt-get install -y -o DPkg::Lock::Timeout=600 <packages>
```

Belt and braces on purpose: the option covers a developer's laptop that happens
to be mid-upgrade and any template that has drifted, and masking the service
means a healthy run never waits at all. Waiting on the lock beats a retry loop,
which only sleeps and races the same holder again.
