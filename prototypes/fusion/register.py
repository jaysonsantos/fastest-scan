"""Registration of one page of one frame to the reference page (hand-writable primitives only).

Stages
  0. quad       : H_quad (page rectangle -> frame) from the 4 detected corners.
  1. homography : coarse-to-fine ZNCC block matching against the reference page, robust
                  least-squares homography G per level, H <- H @ G.
  2. grid       : sparse grid of local translations at full resolution (ZNCC blocks), outlier
                  rejection, hole fill, 3x3 median, bilinear up-sampling to a flow field.
The final sample position of page pixel x is  frame( H @ (x + flow(x)) ).
"""
import time

import cv2
import numpy as np

import fslib as L

# (pyramid level, block, step, search, iterations)  -- sizes in pixels of that level
SCHEDULE = [
    (3, 24, 12, 12, 2),  # 150x212 page, +-96 full-res px
    (2, 32, 20, 6, 1),  # 300x425 page, +-24 px
    (1, 32, 32, 4, 1),  # 600x850 page, +-8 px
    (0, 48, 64, 4, 1),  # 1200x1700 page, +-4 px
]
MIN_LAM = {3: 4e-5, 2: 4e-5, 1: 3e-5, 0: 2e-5}


class Frame:
    """A decoded frame with a luma pyramid (levels 0..3)."""

    def __init__(self, n, bgr=None):
        self.n = n
        self.bgr = L.load_frame(n) if bgr is None else bgr
        self.g = L.pyramid(L.gray01(self.bgr), 3)

    def page_gray(self, H, level=0, flow=None):
        s = float(2**level)
        return warp_level(self.g[level], H, s, flow)

    def page_bgr(self, H, flow=None, interp=cv2.INTER_CUBIC):
        return L.warp(self.bgr, H, flow=flow, interp=interp)


def warp_level(img_l, H, s, flow=None, w=L.PW, h=L.PH):
    """Sample pyramid level image `img_l` (scale 1/s) to a page of size (w/s, h/s)."""
    ow, oh = int(round(w / s)), int(round(h / s))
    xs, ys = L._grid(ow, oh)
    xs = (xs + 0.5) * s - 0.5
    ys = (ys + 0.5) * s - 0.5
    if flow is not None:
        xs = xs + flow[..., 0]
        ys = ys + flow[..., 1]
    Hf = H.astype(np.float32)
    d = Hf[2, 0] * xs + Hf[2, 1] * ys + Hf[2, 2]
    mx = ((Hf[0, 0] * xs + Hf[0, 1] * ys + Hf[0, 2]) / d + 0.5) / s - 0.5
    my = ((Hf[1, 0] * xs + Hf[1, 1] * ys + Hf[1, 2]) / d + 0.5) / s - 0.5
    return cv2.remap(img_l, mx, my, cv2.INTER_LINEAR, borderMode=cv2.BORDER_CONSTANT, borderValue=0)


def fit_homography(ref_levels, frame, H0, schedule=SCHEDULE, log=None):
    """Coarse-to-fine homography. ref_levels[L] = reference page luma at level L."""
    H = H0.copy()
    okflag = True
    for lvl, block, step, search, iters in schedule:
        s = float(2**lvl)
        ref = ref_levels[lvl]
        for it in range(iters):
            img = frame.page_gray(H, lvl)
            xs, ys = L.block_centres(ref.shape[1], ref.shape[0], step, block, search)
            d, sc, ok = L.block_match(ref, img, xs, ys, block, search, min_lam=MIN_LAM[lvl], min_zncc=0.6, min_ratio=0.05)
            n_ok = int(ok.sum())
            if n_ok < 12:
                okflag = False
                if log is not None:
                    log.append(dict(level=lvl, it=it, n_ok=n_ok, fail=True))
                continue
            gx, gy = np.meshgrid(xs, ys)
            src = np.c_[(gx[ok] + 0.5) * s - 0.5, (gy[ok] + 0.5) * s - 0.5]
            dst = src + d[ok] * s
            G, inl, sigma = L.robust_homography(src, dst, min_sigma=0.1 * s)
            H = H @ G
            H = H / H[2, 2]
            if log is not None:
                mag = np.sqrt((d[ok] ** 2).sum(-1)) * s
                log.append(
                    dict(level=lvl, it=it, n_ok=n_ok, n_inl=int(inl.sum()), sigma=float(sigma), med_d=float(np.median(mag)), p95_d=float(np.percentile(mag, 95)))
                )
    return H, okflag


def fit_grid(ref_g, img_g, spacing=64, block=48, search=4, min_zncc=0.6, max_dev=1.0, mask=None, min_ratio=0.1):
    """Sparse grid of translations. Returns node displacements (filled, filtered), xs, ys, ok mask.
    Nodes with a displacement that differs by > max_dev px from the median of the valid nodes in
    the 3x3 neighbourhood are rejected (fingers, glare, repeated patterns)."""
    xs, ys = L.block_centres(ref_g.shape[1], ref_g.shape[0], spacing, block, search)
    d, sc, ok = L.block_match(ref_g, img_g, xs, ys, block, search, min_zncc=min_zncc, mask=mask, min_ratio=min_ratio)
    # neighbourhood consistency
    ny, nx = ok.shape
    ok2 = ok.copy()
    for j in range(ny):
        for i in range(nx):
            if not ok[j, i]:
                continue
            j0, j1, i0, i1 = max(j - 1, 0), min(j + 2, ny), max(i - 1, 0), min(i + 2, nx)
            nb = d[j0:j1, i0:i1][ok[j0:j1, i0:i1]]
            if len(nb) >= 3:
                med = np.median(nb, axis=0)
                if np.abs(d[j, i] - med).max() > max_dev:
                    ok2[j, i] = False
    filled = L.fill_holes(d, ok2)
    filled = L.median3(filled)
    return filled, xs, ys, ok2


def register(ref_levels, frame, H0, spacing=64, block=48, search=3, with_grid=True, log=None, schedule=SCHEDULE, mask=None, coarse_grid=True):
    """Homography (coarse to fine), then a 2-level grid of local translations:
      level 1 (half resolution): spacing 48, block 32, search +-4 (= 96 / 64 / +-8 full-res px)
      level 0 (full resolution): spacing 64, block 48, search +-3
    grids: list of (node displacement, xs, ys) in full-resolution page px; flow = sum of the grids."""
    t0 = time.time()
    H, okflag = fit_homography(ref_levels, frame, H0, schedule=schedule, log=log)
    t1 = time.time()
    grids, flow = [], None
    if with_grid:
        if coarse_grid:
            img1 = frame.page_gray(H, 1)
            n1, xs1, ys1, _ = fit_grid(ref_levels[1], img1, 48, 32, 4, max_dev=1.0)
            g1 = (n1 * 2.0, xs1 * 2.0 + 0.5, ys1 * 2.0 + 0.5)
            grids.append(g1)
            flow = L.grid_to_flow(*g1)
        img = frame.page_gray(H, 0, flow=flow)
        n0, xs0, ys0, _ = fit_grid(ref_levels[0], img, spacing, block, search, mask=mask)
        grids.append((n0, xs0.astype(np.float64), ys0.astype(np.float64)))
        f0 = L.grid_to_flow(n0, xs0, ys0)
        flow = f0 if flow is None else flow + f0
    t2 = time.time()
    node = None
    if grids:
        # total node displacement on the fine grid (for the non-rigidity statistics)
        xs0, ys0 = grids[-1][1], grids[-1][2]
        node = flow[np.clip(ys0.astype(int), 0, L.PH - 1)][:, np.clip(xs0.astype(int), 0, L.PW - 1)]
    return dict(H=H, ok=okflag, grids=grids, node=node, flow=flow, t_h=t1 - t0, t_grid=t2 - t1)


def flow_from_grids(grids):
    flow = None
    for g in grids or []:
        f = L.grid_to_flow(*g)
        flow = f if flow is None else flow + f
    return flow


def ref_levels_from(frame, H):
    return [frame.page_gray(H, l) for l in range(4)]


def quad_start_error(H_quad, H_final, flow, pts):
    """Displacement (page px) between the quad-only mapping and the final mapping at page points."""
    p = pts.copy().astype(np.float64)
    if flow is not None:
        xi = np.clip(np.round(p[:, 0]).astype(int), 0, L.PW - 1)
        yi = np.clip(np.round(p[:, 1]).astype(int), 0, L.PH - 1)
        p = p + flow[yi, xi]
    fr = L.apply_h(H_final, p)  # true position in the frame
    back = L.apply_h(np.linalg.inv(H_quad), fr)  # where the quad mapping puts that content
    return back - pts
