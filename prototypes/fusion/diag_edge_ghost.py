"""Diagnostic for the doubled bullets at the bottom-left of spread C, left page, in the fused
result: is the local registration wrong there because the page flex exceeds the search range of
the grid (+-8 px at half resolution)? Compares the stored 2-level grid with a 3-level grid that
starts at quarter resolution (+-16 px)."""
import pickle

import numpy as np

import fslib as L
import register as R
from config import SPREADS
from stack import get_frame

rows = L.load_csv()
sname, p = "C", 0
cfg = SPREADS[sname]
reg = pickle.load(open(f"{L.CACHE}/reg_{sname}.pkl", "rb"))
refn = cfg["ref"][p]
lv = R.ref_levels_from(get_frame(refn), L.quad_homography(rows[refn]["quads"][p]))
region = np.zeros((L.PH, L.PW), bool)
region[1100:, :450] = True
tot = {"2-level (stored)": [], "3-level (+ quarter res, +-16 px)": []}
for n in (1080, 1082, 1084, 1086, 1088, 1096, 1138, 1141):
    r = reg.get((p, n))
    if r is None or not r["good"]:
        continue
    fr = get_frame(n)
    H = r["H"]
    f2 = R.flow_from_grids(r["grids"])
    # 3 levels: quarter, half, full
    n2, xs2, ys2, _ = R.fit_grid(lv[2], fr.page_gray(H, 2), 24, 24, 4, max_dev=1.0)
    fa = L.grid_to_flow(n2 * 4.0, xs2 * 4.0 + 1.5, ys2 * 4.0 + 1.5)
    n1, xs1, ys1, _ = R.fit_grid(lv[1], fr.page_gray(H, 1, flow=fa[0::2, 0::2]), 48, 32, 4, max_dev=1.0)  # flow sampled on the half-res grid, values stay in full-res px
    fb = fa + L.grid_to_flow(n1 * 2.0, xs1 * 2.0 + 0.5, ys1 * 2.0 + 0.5)
    n0, xs0, ys0, _ = R.fit_grid(lv[0], fr.page_gray(H, 0, flow=fb), 64, 48, 3)
    f3 = fb + L.grid_to_flow(n0, xs0, ys0)
    out = []
    for name, fl in (("2-level (stored)", f2), ("3-level (+ quarter res, +-16 px)", f3)):
        d, ok, _, _ = L.measure(lv[0], fr.page_gray(H, 0, flow=fl), block=48, step=40, search=12, offset=9, mask=region, min_zncc=0.7, min_ratio=0.15)
        m = np.sqrt((d[ok] ** 2).sum(-1))
        if len(m) < 5:  # the hand covers the region in this frame
            out.append(f"{name}: only {len(m)} valid blocks")
            continue
        tot[name].extend(m.tolist())
        mag = np.sqrt((fl[region] ** 2).sum(-1))
        out.append(f"{name}: residual median {np.median(m):.2f} p95 {np.percentile(m, 95):.2f} max {m.max():.1f} (n={len(m)}), flow max {mag.max():.1f} px")
    print(n, " | ".join(out), flush=True)
res = {}
for k, v in tot.items():
    res[k] = dict(n=len(v), median=float(np.median(v)), p95=float(np.percentile(v, 95)), share_over_1px=float(np.mean(np.array(v) > 1.0)))
    print(f"ALL {k}: median {res[k]['median']:.2f} px, p95 {res[k]['p95']:.2f} px, blocks with residual > 1 px: {res[k]['share_over_1px']*100:.0f}% (n={len(v)})")
L.dump_json("diag_edge_ghost.json", res)
