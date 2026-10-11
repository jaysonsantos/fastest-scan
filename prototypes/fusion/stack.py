"""Access to registered (aligned) pages. Reads cache/reg_<spread>.pkl written by
q1q2_registration.py and warps frames on demand (one resample from the original frame)."""
import pickle
from collections import OrderedDict

import cv2
import numpy as np

import fslib as L
import register as R
from config import SPREADS

_frames = OrderedDict()


def get_frame(n, keep=6):
    if n in _frames:
        _frames.move_to_end(n)
        return _frames[n]
    f = R.Frame(n)
    _frames[n] = f
    while len(_frames) > keep:
        _frames.popitem(last=False)
    return f


class PageStack:
    def __init__(self, spread, page):
        self.spread, self.page = spread, page
        self.cfg = SPREADS[spread]
        with open(f"{L.CACHE}/reg_{spread}.pkl", "rb") as f:
            reg = pickle.load(f)
        self.reg = {n: v for (p, n), v in reg.items() if p == page}
        self.ref = self.cfg["ref"][page]
        if self.ref not in self.reg:  # the reference is not in the studied frame lists
            Hq = L.quad_homography(L.load_csv()[self.ref]["quads"][page])
            self.reg[self.ref] = dict(H=Hq, grids=[], method="ref", good=True, H_quad=Hq, q_median=0.0, q_p95=0.0)

    def good(self, kind="stable", max_median=None, max_p95=None):
        """Registered frames. Optional gate on the measured residual after the grid stage."""
        lst = self.cfg[kind] if kind in ("stable", "early") else sorted(self.cfg["stable"] + self.cfg["early"])
        out = []
        for n in lst:
            r = self.reg.get(n)
            if r is None or not r["good"]:
                continue
            if max_median is not None and not (r.get("q_median", 0.0) <= max_median):
                continue
            if max_p95 is not None and not (r.get("q_p95", 0.0) <= max_p95):
                continue
            out.append(n)
        return out

    def flow(self, n):
        return R.flow_from_grids(self.reg[n].get("grids"))

    def aligned(self, n, mode="grid", interp=cv2.INTER_CUBIC):
        """mode: 'quad' (corners only), 'h' (refined homography), 'grid' (homography + local grid)."""
        r = self.reg[n]
        fr = get_frame(n)
        if mode == "quad":
            return L.warp(fr.bgr, r["H_quad"], interp=interp)
        fl = self.flow(n) if mode == "grid" else None
        return L.warp(fr.bgr, r["H"], flow=fl, interp=interp)

    def inside(self, n, mode="grid"):
        r = self.reg[n]
        fl = self.flow(n) if mode == "grid" else None
        return L.inside_mask(r["H"], (2160, 3840), flow=fl)


def to_f(img):
    return img.astype(np.float32) / 255.0


def box_down(img, k):
    """k x k box down-sample (k = 2, 4, 8)."""
    h, w = img.shape[:2]
    return cv2.resize(img[: h // k * k, : w // k * k], (w // k, h // k), interpolation=cv2.INTER_AREA)
