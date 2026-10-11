"""Q2 (part): chain start. Each frame starts from the homography of the neighbour frame that is
already registered (walking outwards from the reference), not from its own quad.
Compares with the stored registration (quad start or ORB start) of q1q2_registration.py."""
import pickle

import numpy as np

import fslib as L
import register as R
from config import SPREADS
from stack import get_frame

rows = L.load_csv()
out = {}


def corner_diff(Ha, Hb):
    pts = np.array([[x, y] for x in (100, 600, 1100) for y in (150, 850, 1300)], float)
    pa = L.apply_h(np.linalg.inv(Ha) @ Hb, pts)
    return float(np.sqrt(((pa - pts) ** 2).sum(1)).max())


def good_fit(log):
    e = log[-1]
    return (not e.get("fail")) and e["level"] == 0 and e["n_inl"] >= 25 and e["sigma"] <= 2.5 and e["n_inl"] >= 0.5 * e["n_ok"]


for sname, cfg in SPREADS.items():
    reg = pickle.load(open(f"{L.CACHE}/reg_{sname}.pkl", "rb"))
    frames = sorted(set(cfg["stable"] + cfg["early"]))
    for p in (0, 1):
        refn = cfg["ref"][p]
        Href = L.quad_homography(rows[refn]["quads"][p])
        lv = R.ref_levels_from(get_frame(refn), Href)
        res = {}
        steps = []
        for direction in (1, -1):
            seq = [f for f in frames if (f - refn) * direction > 0]
            seq.sort(key=lambda f: abs(f - refn))
            prev, prev_n, lost = Href, refn, 0
            for n in seq:
                log = []
                H, ok = R.fit_homography(lv, get_frame(n), prev, log=log)
                okc = bool(good_fit(log))
                truth = reg.get((p, n))
                agree = None
                if truth is not None and truth.get("H") is not None:
                    agree = corner_diff(H, truth["H"])
                res[n] = dict(ok=okc, agree=agree, registered=bool(truth and truth.get("good")))
                if okc:
                    steps.append((abs(n - prev_n), corner_diff(prev, H)))
                    prev, prev_n = H, n
        ok_chain = sum(1 for r in res.values() if r["ok"])
        ok_same = sum(1 for r in res.values() if r["ok"] and r["agree"] is not None and r["agree"] < 2.0)
        ok_stored = sum(1 for r in res.values() if r["registered"])
        chain_only = sorted(n for n, r in res.items() if r["ok"] and not r["registered"])
        stored_only = sorted(n for n, r in res.items() if r["registered"] and not r["ok"])
        mv = np.array([s[1] / s[0] for s in steps]) if steps else np.zeros(1)
        out[f"{sname}{p}"] = dict(frames=len(res), chain_ok=ok_chain, chain_agrees=ok_same, stored_ok=ok_stored, chain_only=chain_only, stored_only=stored_only, motion_px_per_frame_median=float(np.median(mv)), motion_px_per_frame_p95=float(np.percentile(mv, 95)), max_step_px=float(max(s[1] for s in steps)) if steps else 0.0)
        o = out[f"{sname}{p}"]
        print(f"{sname} p{p}: chain start converged {ok_chain}/{len(res)} (same solution as stored: {ok_same}); quad/ORB (stored) {ok_stored}/{len(res)}; chain only {chain_only}; stored only {stored_only}; page motion {o['motion_px_per_frame_median']:.1f} px/frame median, {o['motion_px_per_frame_p95']:.1f} p95, largest step {o['max_step_px']:.0f} px", flush=True)
L.dump_json("q2_chain.json", out)
