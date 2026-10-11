"""Q8: which resolution each step needs + rough timings (Python/OpenCV, 4 threads; only relative
numbers matter for the Zig version)."""
import pickle
import time

import cv2
import numpy as np

import fslib as L
import fusion as F
import register as R
from config import SPREADS
from stack import get_frame

rows = L.load_csv()
VAL_MASK = np.zeros((L.PH, L.PW), bool)
VAL_MASK[: int(L.PH * 0.78)] = True
SCHED = {
    "homography stops at 1/4 res (L3,L2)": [(3, 24, 12, 12, 2), (2, 32, 20, 6, 1)],
    "homography stops at 1/2 res (L3,L2,L1)": [(3, 24, 12, 12, 2), (2, 32, 20, 6, 1), (1, 32, 32, 4, 1)],
    "homography to full res (L3..L0)": R.SCHEDULE,
}
res = {k: [] for k in SCHED}
res_grid = {"grid: half-res level only": [], "grid: half-res + full-res": [], "grid: full-res only": []}
tim = L.Timer()
for sname in ("A", "C"):
    cfg = SPREADS[sname]
    reg = pickle.load(open(f"{L.CACHE}/reg_{sname}.pkl", "rb"))
    for p in (0, 1):
        refn = cfg["ref"][p]
        Href = L.quad_homography(rows[refn]["quads"][p])
        lv = R.ref_levels_from(get_frame(refn), Href)
        for n in cfg["stable"][2::4]:
            r = reg.get((p, n))
            if r is None or not r["good"] or n == refn:
                continue
            fr = get_frame(n)
            # start 20 px away from the stored solution (a typical quad error)
            T = np.array([[1, 0, 14.0], [0, 1, -14.0], [0, 0, 1]])
            for name, sch in SCHED.items():
                t0 = time.time()
                H, _ = R.fit_homography(lv, fr, r["H"] @ T, schedule=sch)
                tim.add(name, time.time() - t0)
                d, ok, _, _ = L.measure(lv[0], fr.page_gray(H, 0), mask=VAL_MASK)
                res[name].extend(np.sqrt((d[ok] ** 2).sum(-1)).tolist())
            H = r["H"]
            # grid variants
            t0 = time.time()
            n1, xs1, ys1, _ = R.fit_grid(lv[1], fr.page_gray(H, 1), 48, 32, 4)
            f1 = L.grid_to_flow(n1 * 2.0, xs1 * 2.0 + 0.5, ys1 * 2.0 + 0.5)
            tim.add("grid half-res level", time.time() - t0)
            t0 = time.time()
            n0, xs0, ys0, _ = R.fit_grid(lv[0], fr.page_gray(H, 0, flow=f1), 64, 48, 3)
            f01 = f1 + L.grid_to_flow(n0, xs0, ys0)
            tim.add("grid full-res level", time.time() - t0)
            n0b, xs0b, ys0b, _ = R.fit_grid(lv[0], fr.page_gray(H, 0), 64, 48, 4)
            f0 = L.grid_to_flow(n0b, xs0b, ys0b)
            for name, fl in (("grid: half-res level only", f1), ("grid: half-res + full-res", f01), ("grid: full-res only", f0)):
                d, ok, _, _ = L.measure(lv[0], fr.page_gray(H, 0, flow=fl), mask=VAL_MASK)
                res_grid[name].extend(np.sqrt((d[ok] ** 2).sum(-1)).tolist())
            # warps
            t0 = time.time()
            L.warp(fr.bgr, H, flow=f01, interp=cv2.INTER_LINEAR)
            tim.add("final warp 1200x1700 bilinear", time.time() - t0)
            t0 = time.time()
            a = L.warp(fr.bgr, H, flow=f01, interp=cv2.INTER_CUBIC)
            tim.add("final warp 1200x1700 bicubic", time.time() - t0)
out = {}
for name, v in list(res.items()) + list(res_grid.items()):
    out[name] = dict(n=len(v), median=float(np.median(v)), p95=float(np.percentile(v, 95)))
    print(f"{name:45s} residual median {np.median(v):.3f} px, p95 {np.percentile(v, 95):.3f} px (n={len(v)})")
# analysis + blend timings on one page
t0 = time.time()
m = F.Model("A", 1)
t_model = time.time() - t0
an = m.an
t0 = time.time()
for _ in range(5):
    an.build_covered()
t_cov = (time.time() - t0) / 5
t0 = time.time()
for _ in range(5):
    an.build_exclusion()
    b, _, _ = an.baseline(0.7, exclude=m.excl_b)
    c = {f: an.glare_stroke(b, f, 0.7, F.T0, F.T1) for f in an.frames}
t_gl = (time.time() - t0) / 5
target = m.glare_target()
donors, _ = m.greedy_donors(target, 7, pool=m.trusted)
t0 = time.time()
patch, filled, valid = m.patch(target, donors)
t_patch = time.time() - t0
ref_f = an.full_f(m.ref)
t0 = time.time()
F.laplacian_blend(ref_f, patch, filled, 5, valid.astype(np.float32))
t_lap = time.time() - t0
t0 = time.time()
F.feather_blend(ref_f, patch, filled, 6.0, valid.astype(np.float32))
t_fe = time.time() - t0
timing = {k: v[0] for k, v in tim.summary().items()}
timing.update({
    f"covered masks, {len(an.frames)} frames at 300x425": t_cov * 1000,
    f"exclusion + baseline + glare confidence, {len(an.frames)} frames at 300x425": t_gl * 1000,
    "patch composition (7 donors, full res)": t_patch * 1000,
    "Laplacian blend 5 levels (full res)": t_lap * 1000,
    "feather blend (full res)": t_fe * 1000,
})
for k, v in timing.items():
    print(f"   {k:70s} {v:7.1f} ms")
out["timing_ms"] = timing
L.dump_json("q8_cost.json", out)
