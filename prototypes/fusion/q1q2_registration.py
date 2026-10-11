"""Q1 + Q2: registration accuracy per stage, grid parameter sweep, non-rigidity, convergence
from the quad start, ORB + RANSAC baseline, chain start for frames with a bad quad.

Writes cache/reg_<spread>.pkl (registration of every studied frame) and out/q1q2_*.json.
"""
import pickle
import sys
import time

import cv2
import numpy as np

import fslib as L
import register as R
from config import SPREADS

rows = L.load_csv()
VAL_MASK = np.zeros((L.PH, L.PW), bool)
VAL_MASK[: int(L.PH * 0.78)] = True  # validation blocks only above the finger zone


def val(ref_g, img_g):
    d, ok, xs, ys = L.measure(ref_g, img_g, block=48, step=60, search=6, offset=17, mask=VAL_MASK, min_zncc=0.9, min_ratio=0.25)
    return d, ok


def orb_homography(ref_u8, frame_u8, nfeat=4000):
    """Heavy baseline: ORB + ratio test + RANSAC. Returns H (page -> frame), inliers, matches."""
    orb = cv2.ORB_create(nfeatures=nfeat, scaleFactor=1.2, nlevels=8)
    k1, d1 = orb.detectAndCompute(ref_u8, None)
    orb2 = cv2.ORB_create(nfeatures=nfeat * 3, scaleFactor=1.2, nlevels=8)
    k2, d2 = orb2.detectAndCompute(frame_u8, None)
    if d1 is None or d2 is None:
        return None, 0, 0
    bf = cv2.BFMatcher(cv2.NORM_HAMMING)
    mm = bf.knnMatch(d1, d2, k=2)
    good = [m for m, n in (x for x in mm if len(x) == 2) if m.distance < 0.8 * n.distance]
    if len(good) < 12:
        return None, 0, len(good)
    a = np.float32([k1[m.queryIdx].pt for m in good])
    b = np.float32([k2[m.trainIdx].pt for m in good])
    H, inl = cv2.findHomography(a, b, cv2.RANSAC, 3.0, maxIters=3000)
    if H is None:
        return None, 0, len(good)
    return H, int(inl.sum()), len(good)


def corner_diff(Ha, Hb):
    """Max distance (page px) between two page->frame mappings, measured at 9 page points."""
    pts = np.array([[x, y] for x in (100, 600, 1100) for y in (150, 850, 1300)], float)
    pa = L.apply_h(np.linalg.inv(Ha) @ Hb, pts)
    return float(np.sqrt(((pa - pts) ** 2).sum(1)).max())


def good_fit(log):
    e = log[-1]
    return (not e.get("fail")) and e["level"] == 0 and e["n_inl"] >= 25 and e["sigma"] <= 2.5 and e["n_inl"] >= 0.5 * e["n_ok"]


REFINE_ONLY = [(1, 32, 32, 6, 1), (0, 48, 64, 4, 1)]
SCHEDULES = {
    "L3x2,L2,L1,L0": R.SCHEDULE,
    "L3x1,L1,L0": [(3, 24, 12, 12, 1), (1, 32, 32, 4, 1), (0, 48, 64, 4, 1)],
    "L2(+-32),L1,L0": [(2, 32, 20, 8, 2), (1, 32, 32, 4, 1), (0, 48, 64, 4, 1)],
    "L1(+-16),L0": [(1, 32, 32, 8, 2), (0, 48, 64, 4, 1)],
    "L0(+-8) only": [(0, 48, 64, 8, 2)],
}
GRID_SWEEP = [(32, 32), (32, 48), (64, 32), (64, 48), (64, 64), (96, 48), (96, 64), (128, 64), (128, 96), (200, 96), (300, 96)]

only = sys.argv[1:] or list(SPREADS)
for sname in only:
    cfg = SPREADS[sname]
    t_all = time.time()
    refs = {}
    for p in (0, 1):
        fr = R.Frame(cfg["ref"][p])
        Href = L.quad_homography(rows[cfg["ref"][p]]["quads"][p])
        lv = R.ref_levels_from(fr, Href)
        refs[p] = dict(levels=lv, H=Href, u8=np.clip(lv[0] * 255, 0, 255).astype(np.uint8))
    reg = {}  # (page, frame) -> dict
    stats = dict(stable=[], early=[], sweep={}, sched={k: [] for k in SCHEDULES}, orb=[], timing={})
    tim = L.Timer()
    frames = cfg["stable"] + cfg["early"][::-1]  # early frames from late to early (for the chain)
    prev_H = {0: None, 1: None}
    sweep_frames = set(cfg["stable"][1::3])
    for n in frames:
        kind = "stable" if n in cfg["stable"] else "early"
        t0 = time.time()
        fr = R.Frame(n)
        tim.add("decode_jpeg+pyramid", time.time() - t0)
        fu8 = None
        for p in (0, 1):
            ref = refs[p]
            rec = dict(frame=n, page=p, kind=kind)
            if n == cfg["ref"][p]:
                reg[(p, n)] = dict(H=ref["H"], grids=[], method="ref", good=True, H_quad=ref["H"], q_median=0.0, q_p95=0.0)
                if prev_H[p] is None:
                    prev_H[p] = ref["H"]
                continue
            have_quad = rows[n]["detected"] >= 1 and rows[n]["pages"] >= 2
            Hq = L.quad_homography(rows[n]["quads"][p]) if have_quad else None
            # ---- (a) quad start, full schedule
            res_q, log_q, ok_q = None, [], False
            if Hq is not None:
                t0 = time.time()
                res_q = R.register(ref["levels"], fr, Hq, log=log_q)
                tim.add("homography_c2f", res_q["t_h"])
                tim.add("grid_2level", res_q["t_grid"])
                ok_q = good_fit(log_q)
            # ---- (b) heavy baseline: ORB + RANSAC, then the same fine refinement
            t0 = time.time()
            if fu8 is None:
                fu8 = np.clip(fr.g[0] * 255, 0, 255).astype(np.uint8)
            Ho, n_inl, n_m = orb_homography(ref["u8"], fu8)
            tim.add("orb_ransac", time.time() - t0)
            res_o, log_o, ok_o = None, [], False
            if Ho is not None and n_inl >= 15:
                res_o = R.register(ref["levels"], fr, Ho, log=log_o, schedule=REFINE_ONLY)
                ok_o = good_fit(log_o)
            # ---- (c) chain start: the homography of the neighbour frame that is already registered
            res_c, log_c, ok_c = None, [], False
            if kind == "early" and prev_H[p] is not None:
                res_c = R.register(ref["levels"], fr, prev_H[p], log=log_c)
                ok_c = good_fit(log_c)
            # agreement
            rec.update(
                quad_ok=ok_q,
                orb_ok=ok_o,
                chain_ok=ok_c,
                orb_inl=n_inl,
                orb_matches=n_m,
                quad_vs_orb=corner_diff(res_q["H"], res_o["H"]) if (res_q and res_o) else None,
                chain_vs_orb=corner_diff(res_c["H"], res_o["H"]) if (res_c and res_o) else None,
                orb_raw_vs_refined=corner_diff(Ho, res_o["H"]) if res_o else None,
                quad_log=log_q,
                chain_log=log_c,
            )
            # choose the registration to keep
            best, method = None, None
            for cand, okc, m in ((res_q, ok_q, "quad"), (res_c, ok_c, "chain"), (res_o, ok_o, "orb")):
                if cand is not None and okc:
                    best, method = cand, m
                    break
            rec["method"] = method
            if best is None:
                reg[(p, n)] = dict(H=None, method=None, good=False, H_quad=Hq)
                stats[kind].append(rec)
                print(sname, n, p, kind, "NO REGISTRATION", "orb_inl", n_inl, flush=True)
                continue
            if kind == "early" or prev_H[p] is None:
                prev_H[p] = best["H"]
            # ---- residuals per stage (validation blocks, upper 78 % of the page)
            g_h = fr.page_gray(best["H"], 0)
            d1, ok1 = val(ref["levels"][0], g_h)
            g_f = fr.page_gray(best["H"], 0, flow=best["flow"])
            d2, ok2 = val(ref["levels"][0], g_f)
            s1, s2 = L.residual_stats(d1, ok1), L.residual_stats(d2, ok2)
            # quad-only error from the final mapping, at the validation block centres
            xs, ys = L.block_centres(L.PW, L.PH, 60, 48, 6, 17)
            gx, gy = np.meshgrid(xs, ys)
            pts = np.c_[gx[ok2], gy[ok2]].astype(float)
            if Hq is not None and len(pts):
                e0 = R.quad_start_error(Hq, best["H"], best["flow"], pts)
                m0 = np.sqrt((e0**2).sum(1))
                s0 = dict(n=len(m0), median=float(np.median(m0)), p95=float(np.percentile(m0, 95)), max=float(m0.max()))
            else:
                s0 = dict(n=0, median=None, p95=None, max=None)
            # non-rigid part = node displacements after the homography
            nm = np.sqrt((best["node"] ** 2).sum(-1))
            rec.update(
                res_quad=s0,
                res_h=s1,
                res_grid=s2,
                nonrigid=dict(median=float(np.median(nm)), p95=float(np.percentile(nm, 95)), max=float(nm.max())),
            )
            reg[(p, n)] = dict(H=best["H"], grids=best["grids"], method=method, good=True, H_quad=Hq, q_median=s2["median"], q_p95=s2["p95"], q_n=s2["n"])
            stats[kind].append(rec)
            print(
                f"{sname} {n} p{p} {kind:6s} {method:5s} quad={s0['median'] if s0['median'] is None else round(s0['median'],1)} "
                f"H={s1['median']:.2f}/{s1['p95']:.2f} grid={s2['median']:.2f}/{s2['p95']:.2f} n={s2['n']} "
                f"nonrigid={rec['nonrigid']['p95']:.2f} q/o/c={int(ok_q)}{int(ok_o)}{int(ok_c)} "
                f"q-o={rec['quad_vs_orb']} c-o={rec['chain_vs_orb']} orb_inl={n_inl}",
                flush=True,
            )
            # ---- schedule variants from the quad start (stable frames only)
            if kind == "stable" and Hq is not None:
                for name, sch in SCHEDULES.items():
                    lg = []
                    Hs, _ = R.fit_homography(ref["levels"], fr, Hq, schedule=sch, log=lg)
                    stats["sched"][name].append(dict(frame=n, page=p, ok=bool(good_fit(lg)), diff=corner_diff(Hs, best["H"]), start=s0["median"]))
            # ---- grid sweep on a subset
            if n in sweep_frames:
                for sp, bl in GRID_SWEEP:
                    t0 = time.time()
                    node, xs_, ys_, okn = R.fit_grid(ref["levels"][0], g_h, sp, bl, 4)
                    fl = L.grid_to_flow(node, xs_, ys_)
                    tim.add(f"grid_{sp}_{bl}", time.time() - t0)
                    g2 = fr.page_gray(best["H"], 0, flow=fl)
                    d, okv = val(ref["levels"][0], g2)
                    m = np.sqrt((d[okv] ** 2).sum(-1))
                    stats["sweep"].setdefault(f"{sp}/{bl}", []).extend(m.tolist())
                m = np.sqrt((d1[ok1] ** 2).sum(-1))
                stats["sweep"].setdefault("homography only", []).extend(m.tolist())
                m = np.sqrt((d2[ok2] ** 2).sum(-1))
                stats["sweep"].setdefault("2-level: 96/64 half-res + 64/48", []).extend(m.tolist())
    stats["timing"] = tim.summary()
    # summarise the sweep
    stats["sweep"] = {k: dict(n=len(v), median=float(np.median(v)), p95=float(np.percentile(v, 95))) for k, v in stats["sweep"].items()}
    with open(f"{L.CACHE}/reg_{sname}.pkl", "wb") as f:
        pickle.dump(reg, f)
    L.dump_json(f"q1q2_stats_{sname}.json", stats)
    print(sname, "done in %.0f s" % (time.time() - t_all), flush=True)
    print(" sweep (spacing/block): ", {k: (round(v["median"], 3), round(v["p95"], 3)) for k, v in stats["sweep"].items()})
    print(" timing ms:", {k: round(v[0], 1) for k, v in stats["timing"].items()})
    for name, lst in stats["sched"].items():
        conv = [x for x in lst if x["ok"] and x["diff"] < 2.0]
        print(f" schedule {name}: converged {len(conv)}/{len(lst)}")
