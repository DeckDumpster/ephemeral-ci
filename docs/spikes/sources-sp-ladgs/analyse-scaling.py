#!/usr/bin/env python3
"""Analyse a per-suite timing ledger to explain a measured wall clock, and to
predict where adding vCPUs stops paying.

The model. 461 independent suites are a bag of tasks, each single-threaded (one
podman exec) apart from the one exclusive suite. Running them P at a time, wall
clock cannot go below either
    W / P        -- total work divided by the slots, if packing were perfect
    L            -- the longest single suite, which no amount of parallelism splits
so the floor is max(W/P, L). Comparing that floor to the measured wall clock
gives the packing efficiency; comparing the two terms to each other says which
of the two ceilings a given P is actually up against.
"""
import sys, collections

def load(path):
    rows=[]; batch=None
    for line in open(path):
        line=line.rstrip("\n")
        if not line.strip() or line.startswith("#"): continue
        f=line.split("\t")
        if len(f)<5: continue
        suite, rc, wall = f[2], f[3], f[4]
        try: wall=float(wall)
        except ValueError: continue
        if suite=="__batch__": batch=wall; continue
        rows.append((suite, rc, wall))
    return rows, batch

def report(path, ncpu, maxpar, measured_wall):
    rows, batch = load(path)
    W = sum(w for _,_,w in rows)
    L = max((w for _,_,w in rows), default=0)
    longest = sorted(rows, key=lambda r:-r[2])[:8]
    P = maxpar
    floor = max(W/P, L)
    print(f"=== {path}")
    print(f"  suites timed            : {len(rows)}")
    print(f"  total work W            : {W:.0f} suite-seconds")
    print(f"  longest single suite L  : {L:.0f} s  ({longest[0][0] if longest else '-'})")
    print(f"  maxpar P                : {P}")
    print(f"  ideal floor max(W/P, L) : {floor:.0f} s   (W/P={W/P:.0f}, L={L:.0f})")
    if measured_wall:
        print(f"  measured suite wall     : {measured_wall:.0f} s")
        print(f"  packing efficiency      : {100*floor/measured_wall:.1f}%  (floor / measured)")
    if batch: print(f"  ledger __batch__ wall   : {batch:.0f} s")
    print(f"  top suites by wall:")
    for s,rc,w in longest:
        print(f"      {w:7.0f}s  {s}")
    print(f"  where the floor changes hands (W held constant at {W:.0f} s):")
    for p in (8,16,24,32,48,64,96):
        wp=W/p; f=max(wp,L)
        which="CPU (W/P)" if wp>L else "longest suite L"
        print(f"      P={p:<3} floor={f:7.0f}s   bound by {which}")
    print()
    return W, L

if __name__=="__main__":
    args=sys.argv[1:]
    while args:
        path=args.pop(0); ncpu=int(args.pop(0)); maxpar=int(args.pop(0))
        mw=args.pop(0); mw=float(mw) if mw!="-" else None
        report(path,ncpu,maxpar,mw)
