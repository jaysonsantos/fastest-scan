"""Summary tables for Q1 / Q2 from out/q1q2_stats_<spread>.json."""
import json

import numpy as np

import fslib as L
from config import SPREADS


def med(v):
    v = [x for x in v if x is not None and np.isfinite(x)]
    return float(np.median(v)) if v else float("nan")


def mx(v):
    v = [x for x in v if x is not None and np.isfinite(x)]
    return float(np.max(v)) if v else float("nan")


summary = {}
for s in SPREADS:
    st = json.load(open(f"{L.OUT}/q1q2_stats_{s}.json"))
    for kind in ("stable", "early"):
        for p in (0, 1):
            rr = [r for r in st[kind] if r["page"] == p]
            reg = [r for r in rr if r.get("method")]
            row = dict(
                frames=len(rr),
                registered=len(reg),
                quad_start_ok=sum(r["quad_ok"] for r in rr),
                orb_ok=sum(r["orb_ok"] for r in rr),
                chain_ok=sum(r["chain_ok"] for r in rr),
                quad_agrees_with_orb_lt1px=sum(1 for r in rr if r["quad_ok"] and r["orb_ok"] and r["quad_vs_orb"] is not None and r["quad_vs_orb"] < 1.0),
                both_ok=sum(1 for r in rr if r["quad_ok"] and r["orb_ok"]),
                quad_median=med([r["res_quad"]["median"] for r in reg]),
                quad_p95=med([r["res_quad"]["p95"] for r in reg]),
                quad_worst_median=mx([r["res_quad"]["median"] for r in reg]),
                h_median=med([r["res_h"]["median"] for r in reg]),
                h_p95=med([r["res_h"]["p95"] for r in reg]),
                grid_median=med([r["res_grid"]["median"] for r in reg]),
                grid_p95=med([r["res_grid"]["p95"] for r in reg]),
                grid_worst_median=mx([r["res_grid"]["median"] for r in reg]),
                nonrigid_median=med([r["nonrigid"]["median"] for r in reg]),
                nonrigid_p95=med([r["nonrigid"]["p95"] for r in reg]),
                nonrigid_max=mx([r["nonrigid"]["max"] for r in reg]),
            )
            summary[f"{s} p{p} {kind}"] = row
            print(
                f"{s} p{p} {kind:6s}: frames {row['frames']:2d} reg {row['registered']:2d} | start ok: quad {row['quad_start_ok']:2d} orb {row['orb_ok']:2d} chain {row['chain_ok']:2d} "
                f"| quad==orb(<1px) {row['quad_agrees_with_orb_lt1px']}/{row['both_ok']} | residual px (median of frames: median/p95): quad {row['quad_median']:.1f}/{row['quad_p95']:.1f} (worst {row['quad_worst_median']:.0f}) "
                f"-> H {row['h_median']:.2f}/{row['h_p95']:.2f} -> grid {row['grid_median']:.2f}/{row['grid_p95']:.2f} (worst {row['grid_worst_median']:.2f}) | non-rigid node shift median {row['nonrigid_median']:.2f} p95 {row['nonrigid_p95']:.2f} max {row['nonrigid_max']:.1f}"
            )
    print("   schedules:", {k: f"{sum(1 for x in v if x['ok'] and x['diff'] < 2.0)}/{len(v)}" for k, v in st["sched"].items()})
    print("   grid sweep spacing/block -> median/p95:", {k: f"{v['median']:.3f}/{v['p95']:.2f}" for k, v in st["sweep"].items()})
    print("   timing ms:", {k: round(v[0]) for k, v in st["timing"].items()})
    summary[f"{s} sched"] = {k: f"{sum(1 for x in v if x['ok'] and x['diff'] < 2.0)}/{len(v)}" for k, v in st["sched"].items()}
    summary[f"{s} sweep"] = st["sweep"]
    summary[f"{s} timing_ms"] = {k: v[0] for k, v in st["timing"].items()}
L.dump_json("q1q2_summary.json", summary)
