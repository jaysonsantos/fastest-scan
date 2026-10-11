"""Q7: crops for the judgement by eye of the sharpness scores + rank agreement numbers."""
import csv

import cv2
import numpy as np

import fslib as L
import fusion as F
from analysis import luma, to_f
from config import SPREADS
from stack import PageStack

sc = {}
with open(f"{L.CACHE}/sharpness.csv") as f:
    for r in csv.DictReader(f):
        sc[(int(r["frame"]), int(r["page"]))] = {k: float(r[k]) for k in ("ten", "mind", "lapv", "ten_q", "mind_q", "lapv_q")}


def spearman(a, b):
    ra, rb = np.argsort(np.argsort(a)), np.argsort(np.argsort(b))
    return float(np.corrcoef(ra, rb)[0, 1])


out = {}
for sname, cfg in SPREADS.items():
    for p in (0, 1):
        st = PageStack(sname, p)
        frames = [n for n in st.good("all") if (n, p) in sc]
        S = {k: np.array([sc[(n, p)][k] for n in frames]) for k in ("ten", "mind", "lapv", "ten_q", "mind_q", "lapv_q")}
        top = {k: frames[int(np.argmax(v))] for k, v in S.items()}
        rec = dict(n=len(frames), top=top, spearman_ten_mind=spearman(S["ten"], S["mind"]), spearman_ten_lapv=spearman(S["ten"], S["lapv"]), spearman_mind_lapv=spearman(S["mind"], S["lapv"]), spearman_full_vs_quarter_ten=spearman(S["ten"], S["ten_q"]), spearman_full_vs_quarter_mind=spearman(S["mind"], S["mind_q"]))
        out[f"{sname}{p}"] = rec
        print(f"{sname} p{p}: n={len(frames)} top-1: ten {top['ten']}, mind {top['mind']}, lapv {top['lapv']} | quarter-res: ten {top['ten_q']}, mind {top['mind_q']}, lapv {top['lapv_q']} | Spearman ten~mind {rec['spearman_ten_mind']:.2f}, ten~lapv {rec['spearman_ten_lapv']:.2f}, full~quarter (ten) {rec['spearman_full_vs_quarter_ten']:.2f}, (mind) {rec['spearman_full_vs_quarter_mind']:.2f}", flush=True)
        # crop: text window in the upper 60 % of the reference page
        ref_y = luma(to_f(st.aligned(st.ref)))
        tm = F.text_mask(ref_y, float(np.percentile(ref_y, 80)))
        tm[int(L.PH * 0.6) :] = False
        ii = cv2.integral(tm.astype(np.float32))
        ww, hh = 400, 110
        s = ii[hh:, ww:] - ii[:-hh, ww:] - ii[hh:, :-ww] + ii[:-hh, :-ww]
        y0, x0 = np.unravel_index(np.argmax(s), s.shape)
        order = np.argsort(-S["mind"])
        picks = [("mind #1", frames[order[0]]), ("mind #2", frames[order[1]]), ("mind #3", frames[order[2]]), ("mind median", frames[order[len(order) // 2]]), ("mind worst", frames[order[-1]])]
        for k in ("ten", "lapv", "ten_q"):
            if top[k] not in [f for _, f in picks]:
                picks.insert(3, (f"{k} #1", top[k]))
        tiles = []
        for name, n in picks:
            c = st.aligned(n, mode="h")[y0 : y0 + hh, x0 : x0 + ww]
            c = cv2.resize(c, None, fx=2, fy=2, interpolation=cv2.INTER_CUBIC)
            rk = {k: int(np.where(np.argsort(-S[k]) == frames.index(n))[0][0]) + 1 for k in ("ten", "mind", "lapv")}
            tiles.append(L.label(c, f"{name}: frame {n} | rank ten {rk['ten']}, mind {rk['mind']}, lapv {rk['lapv']} of {len(frames)}", org=(6, 20), scale=0.55))
        L.save_jpg(f"{L.OUT}/q7_sharpness_ranked_crops_zoom2x_{sname}_p{p}.jpg", L.vstack(tiles), q=92)
L.dump_json("q7_sharpness.json", out)
