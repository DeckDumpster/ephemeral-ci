# ephemeral-ci

Per-run CI runners for every repository in this organization. A job asks for a
runner, gets a Proxmox VM that has never run anything else, and the VM is
destroyed when the job ends.

Two composite actions and the scripts behind them. Adopting it is about fifty
lines of workflow in your repository; nothing is vendored and nothing is copied.

## What a consuming repository looks like

```yaml
name: CI
on:
  pull_request:
    branches: [main]      # or [master] -- match your base branch
  workflow_dispatch:

permissions:
  contents: read

jobs:
  provision:
    runs-on: ubuntu-latest
    outputs:
      vmid:  ${{ steps.vm.outputs.vmid }}
      label: ${{ steps.vm.outputs.label }}
    steps:
      - uses: DeckDumpster/ephemeral-ci/provision@v1
        id: vm
        with:
          ts-oauth-client-id: ${{ secrets.TS_OAUTH_CLIENT_ID }}
          ts-oauth-secret:    ${{ secrets.TS_OAUTH_SECRET }}
          runner-reg-pat:     ${{ secrets.RUNNER_REG_PAT }}
          pve-token-id:       ${{ secrets.PVE_TOKEN_ID }}
          pve-token-secret:   ${{ secrets.PVE_TOKEN_SECRET }}
          pve-api-host:       ${{ vars.PVE_API_HOST }}
          pve-node:           ${{ vars.PVE_NODE }}
          template-vmid:      ${{ vars.TEMPLATE_VMID }}

  test:
    needs: provision
    runs-on: [self-hosted, "${{ needs.provision.outputs.label }}"]
    steps:
      - uses: actions/checkout@v4
      - name: Confirm the job landed on the ephemeral VM
        run: test "$RUNNER_NAME" = "${{ needs.provision.outputs.label }}"
      - run: bash deploy/runner-deps.sh     # yours
      - run: bash deploy/ci.sh              # yours

  teardown:
    needs: [provision, test]
    if: always()
    runs-on: ubuntu-latest
    steps:
      - uses: DeckDumpster/ephemeral-ci/teardown@v1
        with:
          vmid:  ${{ needs.provision.outputs.vmid }}
          label: ${{ needs.provision.outputs.label }}
          consumer-result:    ${{ needs.test.result }}
          runner-reg-pat:     ${{ secrets.RUNNER_REG_PAT }}
          ts-oauth-client-id: ${{ secrets.TS_OAUTH_CLIENT_ID }}
          ts-oauth-secret:    ${{ secrets.TS_OAUTH_SECRET }}
          pve-token-id:       ${{ secrets.PVE_TOKEN_ID }}
          pve-token-secret:   ${{ secrets.PVE_TOKEN_SECRET }}
          pve-api-host:       ${{ vars.PVE_API_HOST }}
          pve-node:           ${{ vars.PVE_NODE }}
```

## The line between here and your repository

| Here | Your repository |
|---|---|
| Cloning and destroying the VM | What runs on it |
| Runner registration and deregistration | `deploy/runner-deps.sh` — the system packages your suite needs |
| The scheduled reaper for orphans | `deploy/ci.sh` — the gate itself |
| Tailnet and Proxmox credentials plumbing | The `test` job's name, which your ruleset requires |

Dependencies stay with the repository that needs them **on purpose**. Baked into
the template they go back to being invisible, and every change to them needs a
manual hypervisor pass; declared in your repo they are reviewed in a pull
request like anything else. The scripts are idempotent, so a template that
already has everything makes that step a few `command -v` calls.

## One-time setup for a new repository

1. **Add it to the runner group.** An org-level runner is eligible for jobs from
   every repository in the organization unless a restricted group says
   otherwise. `ephemeral-ci` is `visibility: selected`:

   ```sh
   gh api -X PUT /orgs/DeckDumpster/actions/runner-groups/3/repositories/<repo-id>
   ```

2. **`RUNNER_REG_PAT` must be visible to it.** An org secret is the right shape:
   set it once and every current and future repository inherits it. The other
   four secrets and three variables are already org-wide.

3. **Point the ruleset at the right check name.** The `test` job reports as
   `test`. If your required check is called something else, rename one of them.

## Things that will waste your afternoon

**The runner group must allow public repositories.** GitHub silently refuses to
schedule a public repository's job onto a self-hosted runner whose group has
`allows_public_repositories=false`. No error, no annotation: the job sits queued
forever beside an idle, correctly-labelled, online runner, which looks exactly
like a label mismatch and is not one.

```sh
gh api -X PATCH /orgs/DeckDumpster/actions/runner-groups/3 \
  -f name=ephemeral-ci -F allows_public_repositories=true
```

**...and the repository must be IN that group.** Same symptom exactly — a job
queued forever beside an idle, online, correctly-labelled runner, with no error
and no annotation — and a different cause, which is what makes it expensive:
`ephemeral-ci` is `visibility: selected`, so a repository missing from its list
cannot use the runner even though the runner registered *into* that group and is
sitting there idle. Someone who reads the paragraph above, checks
`allows_public_repositories`, finds it already `true` and stops has eliminated
the wrong one of the two. Check both, in this order:

```sh
# the runner is in the group and the group allows public repos...
gh api /orgs/DeckDumpster/actions/runner-groups/3/runners --jq '.runners[].name'
# ...AND the repository is on the group's list
gh api /orgs/DeckDumpster/actions/runner-groups/3/repositories --jq '.repositories[].full_name'
```

The fix is step 1 of the one-time setup above, which is easy to skip precisely
because nothing fails until a run is already halfway through: `provision`
succeeds, the VM boots, the runner registers and comes online, and only the
`test` job never starts.

That is safe **only because these runners are per-run**. `provision` needs repo
secrets, a fork pull request does not receive them, so a fork can never cause a
runner to exist — its `test` job would queue against a label that is never
registered and time out. Do not put a long-lived runner in this group.

**`RUNNER_REG_PAT` is organization "Self-hosted runners: Read and write" and
nothing else.** Not repository `Administration: write`. That would also grant
repository deletion, collaborator management and branch-protection changes — far
more than a CI job should hold on a repo whose required status checks are the
thing stopping unreviewed work from landing. Registering at the org level needs
only the runner permission; the restricted group is what confines the runner.

**`gh run rerun <id> --failed` hangs when the runner died mid-job.** If the VM
died after `provision` succeeded, `--failed` does not re-run `provision` — it
was not the step that failed. Only `test` is re-queued, against
`runs-on: [self-hosted, <label>]` for a runner that `teardown` already
destroyed. The job sits queued indefinitely looking exactly like a runner that
has not been picked up yet. A full re-run is refused too: GitHub refuses to
rerun a workflow whose runner connection was lost.

The working recovery is a new run:

```sh
gh workflow run CI --ref <branch>
```

Or close and reopen the pull request.

**`if: always()` on teardown is load-bearing.** A cancelled or failed run
otherwise leaves the VM alive and the hourly reaper becomes the only thing that
cleans up — which is a backstop, not a plan.

**A long-lived runner has undeclared state, and the VM is where you find out.**
Every repository that moves here was passing on a box somebody had been fixing
by hand for months. Nothing recorded those fixes, so the first ephemeral run
surfaces them all at once, and they do not look like missing dependencies —
they look like your code broke. Budget for a round of this, and treat each one
as a line to add to an executable dependency list in the repo, not as a thing
to fix on the VM.

The nastiest are the dependencies that fail *silently*. A missing shared
library stops the process and names itself; a missing **font** renders happily
in a substitute, so a visual-regression suite fails as a pixel diff and reads
as a CSS regression. Resist the urge to re-record the baselines: that bakes the
substitute in and destroys the signal for whoever hits it next. Measure what
changed — if the page chrome around the changed pixels is byte-identical, it is
the environment, not the page. Two that catch people, because a browser resolves
both outside the page's own font stack:

- a metric-compatible **Arial** (`fonts-liberation`) — form controls are drawn
  through the Arial alias, not from the page's CSS, so without it every route
  with an `<input>`, `<select>` or `<button>` moves and every route without one
  does not;
- an **emoji** face (`fonts-noto-color-emoji`) — emoji in your own copy render
  as tofu boxes on a base cloud image.

Assert the property rather than the package (`fc-match`, `fc-list :charset=…`),
so a box that satisfies it another way is not forced onto your choice.

**A cold VM has no caches.** Anything your suite relied on surviving between
runs (a warm build directory, a checkout, a tree-hash cache) is gone every time.
That is usually the right trade — it also removes the shared-state corruption
that a single reused runner quietly permits — but measure before you assume the
cost is small.

## Versioning

Consumers pin `@v1`. The tag moves; breaking changes get a new major. Because a
consumer's `test` job name is part of its branch policy, nothing here will ever
change a job name in a consuming repository — that is why this ships as
composite actions rather than a reusable workflow, which would rename every
required check to `<caller-job> / <called-job>`.

## Layout

```
provision/action.yml   clone, register, wait for the runner to come online
teardown/action.yml    destroy the VM, remove a registration it left behind
scripts/               the Proxmox and guest-side implementation
scripts/test-*.sh      its regression suites, gated by this repo's own CI
docs/DESIGN.md         why each piece is shaped the way it is, and what it cost
docs/TEMPLATE.md       how to build the Proxmox template the clones come from
.github/workflows/reap.yml   hourly orphan sweep
```
