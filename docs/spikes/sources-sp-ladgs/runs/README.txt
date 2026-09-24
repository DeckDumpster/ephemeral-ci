# Raw artefacts from the sp-ladgs vCPU measurements
# retrieved: 2026-09-24, from Proxmox VM 9016 (spike-sp-ladgs-cpu) via the QEMU
#            guest agent (agent/exec), harness DeckDumpster/spira @ dd345ae0.
#
# One set per run. Tags encode the vCPU count; a trailing "b" is the repeat.
#   cpu08, cpu08b   8 vCPU  / maxpar 8
#   cpu16, cpu16b  16 vCPU  / maxpar 16
#   cpu32, cpu32b  32 vCPU  / maxpar 32
# Memory was held at 16 GiB for every run so maxpar tracked nproc (see maxpar-probe.txt).
#
# batch-<tag>.log        testenv-batch.sh's own output: the maxpar line, every suite's
#                        result and duration, cgroup peak, and "batch: wall Ns".
# cpu-<tag>.samples      /proc/stat aggregate line + loadavg, sampled every 5s for the
#                        whole run. Fields after "cpu": user nice system idle iowait irq
#                        softirq steal. Analyse with: analyse-samples.py <file> <ncpu>
#                        [<from-epoch> <to-epoch>] -- the window arguments restrict it to
#                        the suite phase, which is what the write-up quotes.
# result-<tag>.txt       the driver's own summary (measure-corpus2.sh).
# result-cpu08.reconstructed.txt
#                        cpu08's driver died before writing its summary (this session
#                        overwrote the script in place while it ran). Reconstructed by hand
#                        from the two files above; the header explains what happened.
# suite-times-<tag>.tsv  per-suite timing ledger rows for that run only, filtered from
#                        .runtime/spira/suite-times.log by run_id. Columns:
#                        run_id branch suite rc wall_secs bd_calls bd_ms mode
#                        The __batch__ row carries end-to-end wall. Analyse with
#                        analyse-scaling.py <file> <ncpu> <maxpar> <measured-wall>
# node-side-cpu32.samples
#                        hypervisor-side load during the first 32 vCPU run, read from the
#                        Proxmox API. The guest-side steal figure is the load-bearing one;
#                        this is corroboration.
