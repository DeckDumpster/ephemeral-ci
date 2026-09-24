#!/usr/bin/env python3
"""Turn a cpu-<tag>.samples file into a utilisation profile.

/proc/stat aggregate line fields after "cpu":
  1 user  2 nice  3 system  4 idle  5 iowait  6 irq  7 softirq  8 steal

busy  = user+nice+system+irq+softirq   (the guest actually computing)
wait  = idle+iowait                    (the guest with nothing to run, or blocked on I/O)
steal = the hypervisor owed this guest CPU and did not deliver it
"""
import sys

def parse(path):
    out=[]
    for line in open(path):
        try:
            ts, cpu, load = line.split("|")
            f=[int(x) for x in cpu.split()[1:]]
            out.append((int(ts.strip()), f, load.split()))
        except Exception:
            continue
    return out

def delta(a,b):
    d=[y-x for x,y in zip(a,b)]
    user,nice,system,idle,iowait,irq,softirq,steal = d[0],d[1],d[2],d[3],d[4],d[5],d[6],d[7]
    busy=user+nice+system+irq+softirq
    wait=idle+iowait
    tot=busy+wait+steal
    return busy,wait,steal,tot,iowait,system,user

def main(path, ncpu, t_from=None, t_to=None):
    s=parse(path)
    if t_from: s=[x for x in s if x[0]>=t_from]
    if t_to:   s=[x for x in s if x[0]<=t_to]
    if len(s)<2: print("not enough samples"); return
    busy,wait,steal,tot,iowait,system,user = delta(s[0][1], s[-1][1])
    span=s[-1][0]-s[0][0]
    print(f"=== {path}   ({len(s)} samples, {span}s span, ncpu={ncpu})")
    if tot==0: print("no jiffies"); return
    print(f"  busy (computing)      : {100*busy/tot:5.1f}%   -> {ncpu*busy/tot:5.2f} of {ncpu} cores in use on average")
    print(f"     of which user      : {100*user/tot:5.1f}%")
    print(f"     of which system    : {100*system/tot:5.1f}%")
    print(f"  idle + iowait         : {100*wait/tot:5.1f}%")
    print(f"     of which iowait    : {100*iowait/tot:5.1f}%")
    print(f"  steal (hypervisor)    : {100*steal/tot:5.2f}%")
    # per-interval distribution of busy%
    buckets={}
    for i in range(1,len(s)):
        b,w,st,t,_,_,_ = delta(s[i-1][1], s[i][1])
        if t<=0: continue
        p=100*b/t
        k=min(int(p//10)*10, 90)
        buckets[k]=buckets.get(k,0)+1
    print("  distribution of 5s intervals by busy%:")
    for k in sorted(buckets):
        bar="#"*max(1,buckets[k]*40//max(buckets.values()))
        print(f"      {k:>3}-{k+9:<3}% {buckets[k]:>4} intervals {bar}")
    sat=sum(v for k,v in buckets.items() if k>=80)
    print(f"  intervals at >=80% busy: {sat} of {sum(buckets.values())} ({100*sat/max(1,sum(buckets.values())):.1f}%)")

if __name__=="__main__":
    a=sys.argv
    main(a[1], int(a[2]), int(a[3]) if len(a)>3 else None, int(a[4]) if len(a)>4 else None)
