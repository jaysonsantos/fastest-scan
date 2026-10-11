"""Q2 (part): chain start on EVERY frame (step 1), coarse levels only (1/8 and 1/4 resolution),
on the two segments where the quad start and the 3..4-frame chain fail (camera zoom in B,
page clipped by the frame in C). Truth = stored registration (quad or ORB start + refinement)."""
import pickle
import time

import numpy as np

import fslib as L
import register as R
from config import SPREADS
from stack import get_frame

rows = L.load_csv()
COARSE = [(3, 24, 12, 12, 2), (2, 32, 20, 6, 1)]
SEGMENTS = [("B", 840, 921), ("C", 1108, 1160), ("C", 1108, 1064), ("A", 541, 470)]
out = {}


def corner_diff(Ha, Hb):
    pts = np.array([[x, y] for x in (100, 600, 1100) for y in (150, 850, 1300)], float)
    pa = L.apply_h(np.linalg.inv(Ha) @ Hb, pts)
    return float(np.sqrt(((pa - pts) ** 2).sum(1)).max())


for sname, a, b in SEGMENTS:
    cfg = SPREADS[sname]
    reg = pickle.load(open(f"{L.CACHE}/reg_{sname}.pkl", "rb"))
    step = 1 if b > a else -1
    for p in (0, 1):
        refn = cfg["ref"][p]
        Href = L.quad_homography(rows[refn]["quads"][p])
        lv = R.ref_levels_from(get_frame(refn), Href)
        # start: the stored registration of frame a (or the reference itself)
        prev = reg[(p, a)]["H"] if (p, a) in reg and reg[(p, a)]["H"] is not None else Href
        n_cmp = n_ok = lost = 0
        worst, tt, nfr = 0.0, 0.0, 0
        fails = []
        for n in range(a + step, b + step, step):
            fr = get_frame(n)
            t0 = time.time()
            log = []
            H, ok = R.fit_homography(lv, fr, prev, schedule=COARSE, log=log)
            tt += time.time() - t0
            nfr += 1
            e = log[-1]
            tracked = (not e.get("fail")) and e["n_inl"] >= 20 and e["n_inl"] >= 0.5 * e["n_ok"]
            if tracked:
                prev = H
            else:
                lost += 1
            truth = reg.get((p, n))
            if truth is not None and truth.get("good"):
                n_cmp += 1
                d = corner_diff(H, truth["H"]) if tracked else 1e9
                if d < 6.0:  # within the +-8 px of the half-resolution refinement level
                    n_ok += 1
                    worst = max(worst, d)
                else:
                    fails.append(n)
        key = f"{sname} p{p} {a}->{b}"
        out[key] = dict(frames=nfr, lost=lost, compared=n_cmp, within_6px=n_ok, worst_px=worst, fails=fails, ms_per_frame=1000 * tt / max(nfr, 1))
        print(f"{key}: tracked {nfr - lost}/{nfr} frames; at the {n_cmp} frames with a stored registration: {n_ok} within 6 px (worst {worst:.1f} px); fails {fails}; {1000 * tt / max(nfr, 1):.0f} ms/frame", flush=True)
L.dump_json("q2_chain_step1.json", out)
