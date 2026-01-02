#!/usr/bin/env python3
import argparse, os
import pandas as pd
import matplotlib.pyplot as plt
p=argparse.ArgumentParser(); p.add_argument("--csv",required=True); p.add_argument("--outdir",default=None); args=p.parse_args()
out=args.outdir or os.path.join(os.path.dirname(args.csv),"charts"); os.makedirs(out,exist_ok=True)
df=pd.read_csv(args.csv)
for c in ["qd","iops","bw_MBps","lat_p50_us","lat_p90_us","lat_p99_us","lat_p999_us"]:
    if c in df.columns: df[c]=pd.to_numeric(df[c], errors="coerce")
def plot(df, y, label, fname):
    plt.figure()
    for rw in sorted(df["rw"].dropna().unique()):
        sub=df[df["rw"]==rw].sort_values("qd")
        plt.plot(sub["qd"], sub[y], marker="o", label=rw)
    plt.title(f"{label} vs QD")
    plt.xlabel("Queue Depth"); plt.ylabel(label); plt.grid(True, ls="--", alpha=0.4)
    if len(df["rw"].unique())>1: plt.legend()
    plt.tight_layout(); plt.savefig(os.path.join(out, fname), dpi=120); plt.close()
for ios in sorted(df["iosize"].dropna().unique()):
    sel=df[df["iosize"]==ios].copy()
    if "iops" in sel.columns: plot(sel, "iops", f"IOPS ({ios})", f"iops_vs_qd_{ios}.png")
    if "bw_MBps" in sel.columns: plot(sel, "bw_MBps", f"MB/s ({ios})", f"bw_vs_qd_{ios}.png")
print("Charts ->", out)
