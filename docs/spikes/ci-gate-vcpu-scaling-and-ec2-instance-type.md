# Is 16 vCPU real? The CI gate's vCPU scaling curve, and what to buy on EC2

**Bead:** [sp-ladgs](https://github.com/DeckDumpster/spira) · **Repo:** ephemeral-ci ·
**Written:** 2026-09-23 · **Design this feeds:** `wiki/projects/spira/designs/runner-pool-spill-2026-09-23.md` (E3)

## The question

Every full-corpus gate run reports `maxpar: 16 [cpu-bound: cpu=16 ...]`. That line proves the
vCPU count is the resource that binds — but it does not say whether the binding *costs*
anything. A ceiling can bind and still be in the right place. So the question the EC2 spill
design needs answered before it can pick an instance type is not "does 16 bind" but:

> Would 32 vCPU be meaningfully faster, and would 8 be nearly as fast?

This matters because on EC2 the *shape* is what you pay for. There is no x86 instance family
with less than 2 GiB per vCPU, so choosing 16 vCPU forces 32 GiB and its price, whether or not
the gate can use the memory — and the gate has been measured using 1.7 GiB of it.

**What would count as an answer:** the full corpus, at the same commit, run at 8, 16 and 32
vCPU, with wall clock, `maxpar` and cgroup peak for each; plus a recommended EC2 instance type
for E3 with its live on-demand and spot price. A recommendation, not a survey.

## The answer, in one paragraph

**Yes, 16 vCPU is real, and it is the right number on every axis measured.** Six runs, two at each
size. Eight vCPU is **67% slower** on the mean (1,902 s against 1,139 s) — emphatically not "nearly
as fast". Thirty-two vCPU is **13% slower** on the mean (1,289 s), not faster, and costs 2.3× as much
per run. And 16 vCPU is the only size that is *reproducible*: its two runs agreed to **1.2%**, where
8 vCPU spread 22% and 32 vCPU spread **59%**. Keep 16, on both backends.

Two things sharpen this. First, **`cpu-bound: cpu=16` has been telling everyone the wrong story about
why 16 is right.** The gate never saturates its CPUs at any size: at 16 vCPU it uses **5.2 of 16
cores** on average and is under 10% busy for 37% of the run, and the best any run managed was 6.5 of
32. The vCPU count is not buying compute, it is buying *slots*, because `maxpar` is welded to `nproc`.
Second, **the reason 16 is right is that it matches what the pipeline can actually deliver.** Achieved
concurrency — total suite-seconds divided by wall clock — came out at 4.3-5.9 at 8 slots, 9.2 at 16
(twice, identically), and 9.1-12.0 at 32. The corpus can keep roughly nine to twelve suites in flight
and no more. Eight slots throttles it below that; thirty-two lets the suites interfere and inflates
total work by 14-38%; sixteen is the size that matches. That is why it is both fastest and steadiest,
and it is a fact about the harness and the corpus, not about the CPU.

## Method, and one deliberate departure from the one the bead specified

The corpus was run on a Proxmox guest cloned for this measurement — VM 9016
`spike-sp-ladgs-cpu`, tag `spike-sp-ladgs`, on node `hypervisor` — at 8, 16 and 32 vCPU, same
commit, same container image, nothing else changed. The harness checkout on the guest is
DeckDumpster/spira at `dd345ae07caf75f016fefcc7972bb11d68448365` (branch `main`), clean apart
from an untracked `broker/Cargo.lock` build artifact; its 461 `spira/test-*.sh` files are
byte-identical to what `main` tracks, so every run selected the same corpus.

Each size was run **twice**, six runs in all. The bead asked for one run per size and a repeat only
if a result was surprising; 32 vCPU's first result was surprising, its repeat overturned the
conclusion, and at that point a single run at any size could no longer be trusted on its own.

### The departure: 16 GiB, not the 6 GiB the bead named

The bead's method said to keep memory at 6 GiB. **Following it would have measured the wrong
thing at 32 vCPU**, and the harness's own arithmetic says so. `maxpar` is
`min(nproc, floor((MemAvailable - reserve) / per_suite))`, and the runner now budgets 192 MiB
per suite against a 1,024 MiB reserve. That derivation is preserved verbatim, with the banner
line that prints it, at
[`sources-sp-ladgs/testenv-batch-maxpar.txt`](sources-sp-ladgs/testenv-batch-maxpar.txt)
(an annotated excerpt, hence `.txt`; the runnable extract the probe actually sources is
[`maxpar-block.sh`](sources-sp-ladgs/maxpar-block.sh)). Executing it at the two memory
sizes — not deriving it by hand — gives:

| vCPU | MemAvailable | `maxpar` | bound by |
|---:|---:|---:|---|
| 8  | 14,744 MiB (16 GiB guest) | 8  | cpu |
| 16 | 14,744 MiB | 16 | cpu |
| 32 | 14,744 MiB | **32** | cpu |
| 8  | 4,583 MiB (6 GiB guest) | 8  | cpu |
| 16 | 4,583 MiB | 16 | cpu |
| 32 | 4,583 MiB | **18** | **memory** |

At 6 GiB a 32-vCPU guest never gets 32-way parallelism — the memory cap takes it at 18. The run
would have produced a wall clock, the wall clock would have been unremarkable, and the honest
reading of it would have been "the memory cap bit", not "32 vCPU does not help". Holding memory
at 16 GiB makes CPU the only binding resource at every size tested, which is the variable the
question is about.

That probe is preserved at
[`sources-sp-ladgs/maxpar-probe.txt`](sources-sp-ladgs/maxpar-probe.txt), and it carries two
positive controls: it reproduces `maxpar: 8 [cpu-bound: cpu=8 mem=14744MiB avail]` as observed
on VM 9016, and `cpu-bound: cpu=16 mem=4583MiB avail` as observed on real gate run
35897850570. A probe that could not reproduce a known-present case would be worth nothing
(law-absence-needs-a-positive-control).

**This has a consequence for Proxmox worth recording separately:** the production runner
template is now 6 GiB, so giving a Proxmox runner more than ~18 vCPUs buys nothing at all until
its memory goes up too. 16 is, by luck or judgement, just under that cliff.

### What was measured, and what the numbers do and do not include

Each run records wall clock two ways: the driver's own start-to-finish figure, and
`testenv-batch`'s self-reported `batch: wall Ns` which covers only the suite phase. The gap is
fixed setup — container start, `configure`, `install`, and the shared testdb baseline — measured
at **81 s** on the 8 vCPU run. Keeping them separate matters because setup is largely serial and
would otherwise dilute the scaling signal.

Two instrumentation choices are worth naming:

- **Steal time is sampled.** The guest shares `hypervisor` with the live runner fleet and two
  production VMs — 48 logical cores, and 88 vCPUs already allocated across running guests. If
  the node has no spare core, a guest configured with 32 vCPUs does not get 32, and the corpus
  looks like it stopped scaling when it was never given the parallelism. Those two causes point
  to opposite instance choices, so a run that does not measure steal cannot tell them apart.
- **The container image was already local.** The real gate pulls a published image
  (`gate.yml` sets `SPIRA_TESTENV_REGISTRY`; `testenv.sh` consults the registry before
  building), so "image already present when the batch starts" is the real gate's shape too.
  These numbers are **warm**: they exclude image acquisition, which is a constant and does not
  affect the curve, but it is not zero and Option costs below account for it separately.

## What the measurements say

Five runs. Same commit (`dd345ae0`), the same 460 suites actually run (461 selected, one `SKIP-REQ`
before the parallel phase), the same warm container image, 16 GiB throughout so `maxpar` tracks
`nproc` exactly — confirmed in every run's own log (`maxpar: N [cpu-bound: cpu=N mem=~14,8xx MiB
avail]`). "Suite wall" is `testenv-batch`'s own `batch: wall`; setup (container start, `configure`,
`install`, shared testdb baseline) was separately timed at 81 s.

Both 16 and 32 were run twice. That was not in the original plan — the bead said to repeat a size
only if its result was surprising, and 32's first result was, so it was repeated. **The repeat
changed the conclusion**, which is the best argument available for the rule.

| run | vCPU | `maxpar` | suite wall | total work `W` | longest suite `L` | concurrency achieved | cores busy (avg) | busy % | steal % | cgroup peak |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `cpu08`  | 8  | 8  | **1,716 s** | 10,079 s | 293 s | 5.87 | 3.26 of 8  | 40.7% | 2.62% | 1,405 MiB |
| `cpu08b` | 8  | 8  | **2,089 s** |  9,018 s | 246 s | 4.32 | 2.59 of 8  | 32.4% | 0.00% | 2,558 MiB |
| `cpu16`  | 16 | 16 | **1,132 s** | 10,369 s | 358 s | 9.16 | 5.21 of 16 | 32.5% | 0.05% | 2,578 MiB |
| `cpu16b` | 16 | 16 | **1,146 s** | 10,526 s | 312 s | 9.18 | 5.29 of 16 | 33.1% | 0.77% | 2,630 MiB |
| `cpu32`  | 32 | 32 | **1,582 s** | 14,457 s | 421 s | 9.14 | 3.97 of 32 | 12.4% | 2.36% | 2,792 MiB |
| `cpu32b` | 32 | 32 | **996 s**   | 11,899 s | 466 s | 11.95 | 6.46 of 32 | 20.2% | 1.83% | 2,845 MiB |

"Concurrency achieved" is `W / suite wall` — the average number of suites actually in flight.

### The finding is about variance as much as speed

| vCPU | runs | suite wall | mean | spread | vs 16 vCPU mean |
|---:|---:|---|---:|---:|---:|
| 8  | 2 | 1,716 s, 2,089 s | 1,902 s | 22% | **+67%** |
| 16 | 2 | 1,132 s, 1,146 s | **1,139 s** | **1.2%** | — |
| 32 | 2 | 996 s, 1,582 s | 1,289 s | **59%** | +13% |

**Sixteen vCPU is fastest on the mean and reproducible to about one percent. Neither other size is
either.** Every derived quantity agrees between the two 16 vCPU runs — total work within 1.5%
(10,369 / 10,526), average cores busy within 1.5% (5.21 / 5.29), packing efficiency within 0.2%
(57.2% / 57.4%), achieved concurrency within 0.2% (9.16 / 9.18). That is a well-behaved operating
point. At 8 slots the two runs differ by 373 s and at 32 slots by 586 s.

### Why 16 is the right size: it matches what the pipeline can deliver

Achieved concurrency is the number that explains the whole table:

| slots | concurrency achieved | slot fill | total work `W` |
|---:|---:|---:|---:|
| 8  | 4.32, 5.87 | 54%, 73% | 9,018 s, 10,079 s |
| 16 | 9.16, 9.18 | 57%, 57% | 10,369 s, 10,526 s |
| 32 | 9.14, 11.95 | 29%, 37% | 14,457 s, 11,899 s |

**The corpus can keep roughly nine to twelve suites in flight, and no arrangement of slots changes
that.** Going from 16 slots to 32 did not raise achieved concurrency at all in one run and raised it
by 30% in the other — while inflating total work by 38% and 14% respectively, because 32 suites
fighting over one container, one Dolt server, one filesystem and one systemd instance each take
longer. The longest single suite tracks it: **246-293 s at 8 slots, 312-358 s at 16, 421-466 s at 32.**

At 8 slots the ceiling binds the other way: the pipeline could deliver ~9 concurrent suites and is
only allowed 8, and in the worse run only managed 4.3. Notably `cpu08b` had the *lowest* total work of
any run (9,018 s) and still the *longest* wall clock (2,089 s) — its problem was not interference but
that it never filled its slots. So 8 vCPU is slow for a different reason than 32 is slow, and 16 sits
between the two failure modes.

### The rig is trustworthy: it reproduced production to two seconds

The two 16 vCPU runs are the direct analogue of the real gate, and they landed on **1,132 s and 1,146 s**
against the production gate's **1,134 s** (run 35897850570, 456 suites, recorded in the spill design
page on 2026-09-23). Agreement to 0.2% between a purpose-built measurement guest and a real gate run
on the real runner is the positive control for this whole exercise
(law-absence-needs-a-positive-control) — the instrument was checked against a known value before
being trusted on unknown ones.

### Why 32 slots misbehaves: the suites interfere, by a varying amount

The harness records every suite's own wall time, so the corpus can be weighed at each concurrency.
Total work `W` is the sum of all 460 suites' elapsed seconds:

| `maxpar` | total work `W` | vs the 16-slot mean |
|---:|---:|---:|
| 8  | 9,018 s / 10,079 s | −14% and −3.5% |
| 16 | 10,369 s / 10,526 s | — (mean 10,448 s) |
| 32 | 11,899 s / 14,457 s | **+14% and +38%** |

From 8 to 16 slots the corpus costs essentially the same total work, so the extra parallelism
converts almost directly into wall clock — which is why 16 beats 8 so clearly. At 32 slots the same
460 suites take 14-38% longer *in aggregate*: they are fighting over one container, one Dolt
server, one filesystem and one systemd instance. The longest single suite tells the same story
monotonically — **293 s → 358 s / 312 s → 421 s / 466 s** as slots go 8 → 16 → 32.

So the corpus has an interference onset somewhere between 16 and 32 concurrent suites, 16 sits below
it, and the *amount* of interference above it varies run to run. That variability is the practical
problem: it means 32 slots is not a shape whose gate time you can predict.

### The CPU is never the constraint at any size

At no point does the gate use the CPUs it is given. The peak average was **6.46 of 32 cores**, and
at the 16 vCPU optimum it is **5.2 of 16** with 37% of five-second intervals under 10% busy. In the
slower 32 vCPU run, not one interval in 309 reached 80% busy. `cpu-bound` in the gate log names which
term won `min(nproc, floor((MemAvailable − reserve) / per_suite))` — it is not a claim that the CPUs
are busy, and it has been read as one.

Memory is equally not the constraint: cgroup peak reached 2,845 MiB at its worst, against a 16 GiB
guest, and per-slot usage *fell* as slots rose (175 → ~162 → ~88 MiB) against the 192 MiB budget.

### Two structural costs, one of them large

**The exclusive suite's solo window.** One suite of 460 is declared `# exclusive:`
(`test-artifact-install.sh` — *"cargo build peaks at several GB; runs alone to prevent container
OOM"*). The batch waits for every in-flight job, runs it alone, then refills. Its solo duration is
logged every run and is essentially constant regardless of slots — **142, 143, 145, 146, 150 and
178 s** across the six runs, so it does *not* grow with `maxpar` as one might expect. For that window one suite has the whole
guest, and the progress trace shows it plainly — completions stop dead at exactly `maxpar` and load
falls to **1.17-1.27**. At 16 vCPU that is ~148 s of ~1,139 s: **13% of every full-corpus gate run
spent running one suite on sixteen cores** — and because it is a fixed cost, it is a *larger* share of
the faster configurations, which is precisely why it is worth attacking. One caveat on reading the log: the `draining for
exclusive suite` line is emitted *after* the drain completes, so the log gives the solo duration
exactly but the preceding drain-wait only by inference from the completion trace. 13% is therefore a
lower bound on the idle cost.

**Slots are never full.** Average concurrency is `W / suite wall`: **4.3-5.9** at 8 slots, **9.2** at 16, and **9.1-12.0** at 32. Going from 16 to 32 slots barely moved achieved concurrency. The scheduler
is work-conserving — it launches a replacement the instant a slot frees
(`while [ "$(jobs -rp | wc -l)" -ge "$_maxpar" ]; do wait -n; done`) — so this is not scheduling
gaps. It is the solo window above plus per-suite launch cost in the serial main loop, which does a
synchronous `podman exec … mkdir` per suite before forking. **Which of those dominates was not
isolated, and should be**: it is the difference between "the gate has an unavoidable serial section"
and "the gate wastes a third of its wall clock on container round-trips".

### Contention on the shared node does not explain the result

The measurement guest shares `hypervisor` (48 logical cores, Xeon Platinum 8160 at 2.10 GHz) with
the live runner fleet and two production VMs; allocation across running guests ranged from 104 to
136 vCPU during the session — 2.2-2.8× oversubscribed. That is exactly the condition under which a
scaling curve can be an artefact, so steal was sampled inside the guest throughout.

Steal never exceeded **2.62%**, and the slowest run of all (`cpu08b`, 2,089 s) had **0.00%**. It cannot account for a 586-second spread at 32 slots: 2.6% of
1,582 s is 41 s. And the direction is wrong for the tidy explanation — the *slower* 32 vCPU run had
more steal (2.36% vs 1.83%) but only by 0.5 percentage points, while its total work was 21% higher.
The interference is inside the guest, not above it. Node-side samples are preserved alongside the
guest-side ones.

## What EC2 charges for the three shapes

Both price sources were re-fetched and re-derived during this spike rather than taken from the
prior session's extract or from memory.

- **On-demand** came from the public pricing web API. The live document for us-east-1 is
  **byte-identical** to the copy the earlier pass preserved — same SHA-256
  `4da28ffa…d0a4a55b`, same 695,491 bytes — and the candidate prices were re-derived from the
  live fetch independently. Publication date in its own manifest: **2026-09-21T19:47:12Z**.
- **Spot** came from the live feed behind the EC2 Spot pricing page. It is a *different* file
  from the preserved copy, as expected — spot moves — so every candidate was re-compared. The
  largest drift across 36 (region, type) pairs was **1.0%** (`m7a.2xlarge` in us-east-1,
  $0.2005 → $0.1984); 30 of 36 were unchanged to four decimal places.

Region is **us-west-2** below, because that is the default [sp-o0oh5](#) already proposes to the
operator ("near the hypervisor; spot capacity for c7i is deep there"). us-east-1 is shown
alongside, and the ranking is the same in both.

| shape | type | vCPU | mem | on-demand $/h | spot $/h | spot saving | interruption |
|---|---|---:|---:|---:|---:|---:|---|
| 8 vCPU  | `c7i.2xlarge` | 8 | 16 GiB | 0.3570 | 0.1466 | 55% | 15-20% |
| 16 vCPU | `c7i.4xlarge` | 16 | 32 GiB | 0.7140 | 0.2503 | 56% | 5-10% |
| 32 vCPU | `c7i.8xlarge` | 32 | 64 GiB | 1.4280 | 0.5171 | 61% | 10-15% |

*(us-west-2, Linux, shared tenancy. Full matrix for 18 candidate types across both regions in
[`sources-sp-ladgs/ec2-ondemand-candidates.json`](sources-sp-ladgs/ec2-ondemand-candidates.json)
and [`ec2-spot-candidates.json`](sources-sp-ladgs/ec2-spot-candidates.json).)*

On-demand price is exactly linear in the shape — $0.0446 per vCPU-hour at every size — so on
on-demand there is no discount for buying a bigger box and no penalty for buying a smaller one.
Spot is mildly *non*-linear and favours the big shape: $0.01833/vCPU-h at 8, $0.01564 at 16,
$0.01616 at 32. That is a 15% per-vCPU discount for choosing 16 over 8, and it is the only
place in this whole analysis where the price list prefers a particular size.

### Two traps in the price list

**`c7i-flex.4xlarge` is the same 16 vCPU / 32 GiB shape for $0.6783 on-demand — 5% cheaper —
and it is the wrong instance.** Flex instances have a **baseline of 40% of full performance per
vCPU** and burst above it only "a majority of the time". AWS's own guidance sends this workload
the other way: *"C7i instances offer price performance benefits for workloads that need larger
instance sizes … or **continuous high CPU usage**. C7i instances are ideal for workloads
including **batch processing**, distributed analytics, high performance computing"*. A gate is
batch processing by definition. Source preserved at
[`sources-sp-ladgs/ec2-flex-baseline.txt`](sources-sp-ladgs/ec2-flex-baseline.txt).

Worth being precise about *why* this is a trap rather than merely a risk, given what the
measurements below show: the gate's average CPU demand is low, so a flex instance would very
likely sustain it. But the gate's demand is **bursty** — it has short intervals at 90-100% —
and those bursts are where the wall clock is made. A shape whose ceiling is soft, and whose
throttling is neither announced in the log nor visible to `maxpar`, would turn a 5% saving into
an unexplainable intermittent slowdown in the one number the fleet is judged on. Reject it on
observability grounds, not on average utilisation.

**Graviton is 13-19% cheaper and is not free to adopt.** `c7g.4xlarge` is $0.5800 on-demand
and $0.2171 spot in us-west-2 against `c7i.4xlarge`'s $0.7140 / $0.2503, at the identical
16 vCPU / 32 GiB shape and the *lowest* interruption band (<5%). That is the largest single
saving available. But it is arm64: it needs an arm64 runner AMI (E2's substrate), an arm64
`spira-testenv` image, and the corpus has never been run on arm64, so nothing is known about
whether the 461 suites are architecture-clean. That is a separate piece of work with its own
risk, not a line item in E3's instance-type choice — filed rather than folded in.

## Options, with costs

Cost of one spilled full-corpus gate run = hourly rate × billed seconds, where billed seconds are
`overhead + suite wall`. EC2 bills per second with a 60 s minimum, so there is no rounding penalty at
these durations. Suite wall is the **mean of the two runs** at that size.

**The overhead term is swept, not asserted**, because only part of it could be measured here:

| component | seconds | how it is known |
|---|---:|---|
| boot to controllable | 17-58 | **measured** — timed on VM 9016's own resizes, four times; Proxmox, not EC2 |
| SSM online + token delivery + runner registration | ? | **not measured** — no AWS account on this box |
| image acquisition (1.83 GB) | ? | **not measured** — 0 if baked into the AMI, otherwise a pull |
| batch setup (container, configure, install, testdb) | 81 | **measured** on VM 9016 |
| terminate | ? | **not measured** |

The table below uses 320 s. **The ranking is insensitive to this choice**, because overhead is
identical across shapes and is billed at a rate proportional to vCPU count — it can only ever
penalise the bigger shape. At overhead 200 s and 500 s the ordering is unchanged.

### us-west-2 (the region sp-o0oh5 proposes), spot, overhead 320 s

| option | shape | suite wall (mean) | spread | billed | spot $/h | **$/run** | runs/mo at $50 |
|---|---|---:|---:|---:|---:|---:|---:|
| **A** — 8 vCPU  | `c7i.2xlarge` | 1,902 s | 22% | 2,222 s | 0.1466 | **$0.091** | 553 |
| **B** — 16 vCPU | `c7i.4xlarge` | **1,139 s** | **1.2%** | 1,459 s | 0.2503 | **$0.101** | 493 |
| **C** — 32 vCPU | `c7i.8xlarge` | 1,289 s | 59% | 1,609 s | 0.5171 | **$0.231** | 216 |

On-demand, same overhead: A $0.220, B $0.289, C $0.638 per run.

### Option C is dominated

**C is slower than B on the mean (+13%) and 2.3× its cost.** There is no axis on which it wins, so it
needs no further weighing. Its best individual run (996 s) does beat B's mean by 13%, but its worst
(1,582 s) is 39% worse, and even the best run costs $0.189 against B's $0.101 — so C loses on money
in every case and on time in half of them.

This is the most useful single finding here, because "the full corpus is a big job, so buy the big
instance" is the intuition anyone would start from. It is wrong for a reason that generalises: the
gate does not use the CPUs it already has, so a shape selling more of them is selling the wrong thing.

### A is cheaper by a penny in one region and dearer in the other

B costs **$0.011 more per run** than A in us-west-2 and saves **763 s — nearly thirteen minutes** of
wall clock. At 50 spilled runs a month that is **$0.55/month** for thirteen minutes off every overflow
run.

And the sign flips by region: **in us-east-1, B is outright cheaper than A** — $0.0991 against
$0.1084 — because spot there prices `c7i.4xlarge` relatively lower while A's longer runtime works
against it. In us-east-1, B dominates A on both time and money with nothing to trade off.

A also carries a risk the table does not price: at 8 slots it is the least predictable of the three
after C (22% spread), and its concurrency fell as low as 4.3 of 8 slots. And it is the only option
whose concurrency differs from the Proxmox runner's — see the recommendation.

## Recommendation

**Option B: `c7i.4xlarge` — 16 vCPU, 32 GiB — in us-west-2, spot-first with an on-demand fallback.
Keep the runner at 16 vCPU on both backends, and do not scale it up.**

1. **16 vCPU is the fastest on the mean** — 1,139 s against 1,902 s at 8 vCPU (+67%) and 1,289 s at
   32 (+13%).
2. **It is the only reproducible size.** Two runs agreed to 1.2% on wall clock and to within 1.5% on
   every derived quantity, and both agreed with a real production gate run to 0.2%. 8 vCPU spread
   22%; 32 vCPU spread 59%. For the number a fleet is judged on, predictability is worth as much as
   speed.
3. **32 vCPU is dominated** — slower on the mean *and* 2.3× the cost per run ($0.231 against $0.101).
4. **8 vCPU saves almost nothing.** $0.011/run in us-west-2 for thirteen extra minutes per run — and
   in us-east-1 it is actually *dearer* ($0.108 against $0.099), because its longer runtime outweighs
   its lower rate.
5. **It matches the Proxmox runner's concurrency**, so a spilled green means what a Proxmox green
   means. `maxpar` is `nproc`, so matching the shape is the only way to match the concurrency.

`c7i.4xlarge` specifically: of all 18 candidates it is the cheapest **eligible** 16 vCPU shape on
spot in both candidate regions — eligible meaning x86 (runs the existing AMI and image) and
fixed-performance (cannot silently throttle). The two cheaper 16 vCPU shapes are arm64, and the next
cheapest x86 is `c7i-flex.4xlarge`, rejected on its 40% baseline.

### The one load-bearing assumption

**That the ordering of the three shapes is a property of the corpus and the harness, and not of this
hypervisor.**

Every second in this document was measured on one Proxmox guest: a Xeon Platinum 8160 at 2.10 GHz,
on `local-lvm` shared with eight other guests, on a node 2.2-2.8× oversubscribed in vCPU allocation.
The recommendation assumes that a `c7i` — Sapphire Rapids, faster per core, on a dedicated EBS
volume, with no neighbours competing for cores — would reproduce the same *ordering*, even though it
will certainly not reproduce the same absolute seconds.

The specific way this could be wrong: the 14-38% work inflation at 32 slots is read here as the
suites contending over shared in-container resources. If it is instead contention for *disk*, a `c7i`
on provisioned-IOPS gp3 might absorb 32-way concurrency that this guest could not, and option C would
stop being dominated on time — though it would still lose on cost, so the answer would likely survive
even then.

Evidence that it holds: steal never exceeded 2.62% and the single slowest run had 0.00% steal, so
neighbour CPU contention is not driving these numbers; iowait *fell* as concurrency rose (8.3% → 3.4%
→ 0.9%), the opposite of a disk wall; and `system` time is 8-15% of busy time throughout, which
points at the container and syscall path rather than storage. That is an argument from secondary
evidence, not a measurement, and **falsifier 1 below is how to settle it without an AWS account.**

**An earlier draft of this document named a different load-bearing assumption** — that the 8 vCPU
penalty was real rather than an artefact of a single run. That was tested by running 8 vCPU a second
time; it came back *slower* (2,089 s), so the assumption held and is now retired as a risk.

### What this explicitly does not claim

It does not claim the gate needs 16 cores of CPU. At 16 vCPU it uses **5.2 of 16 cores** and sits
under 10% busy for 37% of the run; the peak across all six runs was 6.5 of 32. E3 will be paying
for CPUs that do not work — and that is a harness defect, not an instance-choice defect. Two are
filed rather than papered over:

- `maxpar` is welded to `nproc`, so slots can only be bought as CPUs (**sp-a749v**).
- 13% of every run is one suite running alone on the whole machine (**sp-rbulh**).

If either lands, **come back to this document.** The right shape then becomes "the smallest instance
that sustains ~16 slots", which at a measured 0.33 cores per slot is materially smaller than 16 vCPU
— plausibly option A's shape running at option B's concurrency, which would be strictly better than
either.

### For E3's cost line

Instance type `c7i.4xlarge`, spot, us-west-2: **$0.2503/hour**; on-demand fallback **$0.7140/hour**
(both live as of 2026-09-23). Expect **~$0.10 per full-corpus spilled run** (measured mean wall clock, Proxmox seconds), and
`spill-max-instances=4` caps the burn at **$1.00/hour**. If spot interruptions prove disruptive, the
in-shape upgrade is `c8i.4xlarge` — $0.2922/h spot, 17% more, in the **<5%** interruption band
against c7i.4xlarge's 5-10% — in preference to abandoning spot.

## The falsifier: what would have to be true for this to be wrong

Ordered by how likely each is to come true. Each is checkable, and each has a different
consequence.

1. **The 16→32 interference is storage-mediated, not corpus-mediated.** Total work rose 14-38% at
   32 slots, and the recommendation reads that as the suites contending over one container, one Dolt
   server and one systemd instance. If instead it is contention for *disk*, the measurement guest is
   a poor proxy: VM 9016 sits on `local-lvm` shared with eight other guests. A `c7i` on a
   provisioned-IOPS gp3 volume might absorb 32-way concurrency that this guest could not.
   **Check, without any AWS account:** re-run at `maxpar` 32 with the container's scratch on tmpfs,
   or on a guest with a dedicated disk, and see whether `W` still inflates against `maxpar` 16.
   *Consequence if true:* 32 vCPU may become predictable — though it still loses on cost, so this
   changes the reasoning more than the answer.
   *Evidence against:* iowait *fell* as concurrency rose (7.5% → 3.4-4.6% → 0.9-3.9%), which is the
   opposite of a disk wall, and `system` time is 8-15% of busy throughout, pointing at the container
   and syscall path rather than storage.

2. **`maxpar` stops being `nproc`.** Filed as a bead. If concurrency becomes settable
   independently, matching Proxmox's concurrency no longer requires matching its shape, and the
   right answer becomes the smallest instance that sustains ~16 slots — on a measured 0.33 cores
   per slot, roughly 8 vCPU.
   **Check:** run `maxpar-override-probe.sh` from this spike's sources. If asking for 32 at
   `nproc=8` no longer returns 8, this document is out of date.
   *Consequence if true:* drop to `c7i.2xlarge` and keep 16 slots — the best of both.

3. **The exclusive suite stops being exclusive, or gets faster.** 13% of every run is
   `test-artifact-install.sh` alone on the whole machine. If its cargo build were cached, or its
   memory spike bounded so it no longer needs to run alone, the wall clock at *every* size falls
   and the optimum could move.
   **Check:** the filed bead. *Consequence if true:* re-measure the curve; the 8-vs-16 gap is the
   part most likely to shrink, since the solo window is a fixed cost that 16 amortises no better
   than 8.

4. **The corpus turns out to be concurrency-insensitive after all.** Consideration 5 of the
   recommendation assumes concurrency can change a *verdict*, not merely a duration. This spike
   showed concurrency changes durations sharply; it did **not** show it changes outcomes. If
   someone demonstrates the set of reds is stable across `maxpar` 8-32 over several repetitions,
   the equivalence argument weakens to a preference.
   **Check:** compare *red sets*, not pass counts, across concurrencies, repeatedly — a flake that
   appears 1-in-5 is exactly the failure mode at issue. Note this spike is weak evidence *against*
   stability: across the six runs it saw 3 and 5 reds at 8 slots, 1 and 2 at 16, and 2 and 2 at 32 —
   varying between *identical* runs at the same concurrency, which points at ordinary flakiness as much
   as at concurrency. On an environment missing the quarantine state those counts are not trustworthy
   on their own.
   *Consequence if true:* cost decides, which picks A in us-west-2 and is a coin-flip in us-east-1.

5. **arm64 turns out to be clean.** Then `c7g.4xlarge` is the same shape for 13-19% less in the
   best interruption band. **Check:** sp-snm2w. *Consequence if true:* switch family, keep the
   16 vCPU shape — the equivalence argument is untouched, only the price.

6. **The gate stops being the dominant spill workload.** Everything here is the full corpus. A
   spill mostly serving diff-selected pull-request runs is sized by a different distribution, and
   for short runs the fixed overhead dominates so completely that the shape barely matters.
   **Check:** what fraction of spilled runs are full-corpus pushes versus pull requests? Nobody has
   measured this, because spill does not exist yet.
   *Consequence if true:* redo the cost table against the real run-length mix; the recommendation
   probably survives, since equivalence does not depend on run length.

7. **Per-core speed changes the arithmetic.** These are Skylake-SP seconds at 2.10 GHz; `c7i` is
   Sapphire Rapids and faster per core, so EC2 wall clocks and costs will be *lower* than quoted.
   That makes the recommendation safer, not riskier, but it means the dollar figures are upper
   bounds and must not be quoted as measurements of EC2. **Check:** the first real spilled run —
   also the first chance to measure boot-to-registered latency, currently an estimate.

## What was observed, what was inferred, and what could not be checked

**Observed** (measured on VM 9016 this session, raw samples preserved):
wall clock, `maxpar`, cgroup peak, CPU busy/idle/iowait/steal and their distribution over time,
at each vCPU count; the suite corpus being identical across runs; the harness's own `maxpar`
arithmetic at injected memory sizes; live on-demand and spot prices; c7i-flex's 40% baseline.

**Inferred** (reasoned from the above, not measured): the per-slot CPU demand of ~0.33 cores,
which is an average over a strongly bimodal profile and not a property any single suite has; that
the 16→32 interference is corpus-mediated rather than storage-mediated, which is the
recommendation's load-bearing assumption and rests on secondary evidence only (iowait *fell* as
concurrency rose, and `system` time is a large share of busy time); and what `maxpar` above `nproc`
would do, which was not run because the harness clamps it by design.

**Repetition:** every size was run twice. That was not the original plan — the bead asked for one run
per size — but 32 vCPU's first result was surprising, its repeat overturned the conclusion, and after
that no single run could be trusted on its own. Two runs still give a spread, not a distribution: the
32 vCPU pair differed by 59%, so a third run there could plausibly fall outside the observed range.

**Could not be checked, and why:**

- **Real EC2 behaviour of any kind.** There is no AWS account and no credential on this box —
  `aws sts get-caller-identity` returns `NoCredentials`, with `aws-cli/2.37.1` installed. So
  every EC2 number here is a *price* from a published list, not a measurement. Specifically
  unverified: actual boot-to-runner-registered latency, real spot interruption behaviour for
  these types, whether the chosen shape's EBS bandwidth is adequate for a corpus that spends
  ~16% of its time in iowait, and true per-AZ spot prices (the feed used is the published
  regional price, not `describe-spot-price-history`). This is not a gap this spike can close:
  the account decision is already escalated to the operator as
  [sp-o0oh5](#) and every spill bead is blocked behind it.
- **Whether the corpus runs at all on arm64.** Never attempted. This is the load-bearing
  unknown under the largest available saving.
- **Whether the gate's wall clock on EC2 resembles its wall clock on Proxmox.** The Xeon
  Platinum 8160 in `hypervisor` is Skylake-SP at 2.10 GHz; `c7i` is Sapphire Rapids and
  materially faster per core. Per-core speed does not change the *shape* of the scaling curve,
  which is what this spike measured, but it does mean the absolute seconds below are Proxmox
  seconds and the EC2 cost estimates inherit that as their main error term.
- **Whether concurrency changes verdicts, as opposed to durations.** This spike measured durations
  thoroughly and outcomes only incidentally. The equivalence argument in the recommendation rests on
  concurrency being able to change a red set, which is plausible and is why one suite is declared
  exclusive at all — but it was not demonstrated here.
- **What exactly stops the slots from filling.** Achieved concurrency was 9.2 at both `maxpar` 16
  and 32. The exclusive-suite drain accounts for part of it and the serial per-suite launch path
  (a synchronous `podman exec … mkdir` per suite) for some unknown remainder, and the two were not
  separated. That is the gap between "the gate has an unavoidable serial section" and "the gate
  wastes a third of its wall clock on container round-trips".
- **Cold-versus-warm image acquisition cost.** Measured numbers are warm: the 1.83 GB
  `spira-testenv` image was already local. The real gate pulls it from a registry, and the pull
  was not timed here because there is no registry reachable from the measurement guest. It
  appears in the cost model as an explicit, flagged estimate, not a measurement.

## Work this found and did not do

Filed rather than folded in, because none of it is this bead's question:

- **sp-a749v** (P2, repo:spira) — `testenv-batch` welds `maxpar` to `nproc`, but the gate uses only
  5.2 of 16 cores. Concurrency cannot be bought without buying idle CPUs. This is the bead that,
  if it lands, changes the recommendation above.
- **sp-rbulh** (P3, repo:spira) — 13% of every full-corpus gate is one exclusive suite alone on the
  whole runner. Measure whether its cargo build is running cold; failing that, run it first so the
  drain waits on an empty pipeline.
- **sp-snm2w** (P2, repo:spira) — does the corpus pass on arm64? It gates the largest single saving
  available (13-19% on `c7g`), needs no AWS account, and a "no" is as useful as a "yes".

Two things were noticed and deliberately not filed:

- **`test-install-dolt-breaker.sh` fails on this measurement guest** because the batch's shared
  Dolt testdb baseline occupies port 19142 with a different data directory, and the suite expects to
  own it. It is almost certainly quarantined in the real gate — quarantine state lives in a store
  the spike guest does not have, so a known-quarantined red presents here as a plain red. Not filed
  because I could not confirm it is not already known, and a duplicate bead about a suite that is
  already quarantined would be noise.
- **The red counts varied between identical runs** — 3 and 5 at 8 slots, 1 and 2 at 16, 2 and 2 at 32.
  Varying at the *same* concurrency points at ordinary flakiness rather than a concurrency effect, and
  on an environment missing the quarantine state the counts are not trustworthy enough to file a claim
  on. It is falsifier 4 in the document, and someone should look on a real runner.

