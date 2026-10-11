"""Fusion building blocks (hand-writable): masks, donor selection, patch composition,
feathered and Laplacian-pyramid blending, soft minimum, median."""
import cv2
import numpy as np

import fslib as L
from analysis import K, Analysis, luma, sharp_frames, up
from config import SPREADS

T0, T1 = 0.06, 0.06  # stroke glare confidence: clamp((d - T0) / T1), d on a 0..1 scale
CONF_ON = 0.3
TRUST_MEDIAN, TRUST_P95 = 0.40, 1.50  # px, gate for frames that may enter the glare baseline


class Model:
    """Everything the fusion needs for one page."""

    def __init__(self, spread, page, frames=None, cand_dilate=10):
        cfg = SPREADS[spread]
        if frames is None:
            frames = sharp_frames(spread, page, sorted(cfg["stable"] + cfg["early"]))
        an = Analysis(spread, page, frames)
        self.an, self.cfg, self.ref = an, cfg, an.ref
        reg = an.st.reg
        self.trusted = [f for f in an.frames if reg[f].get("q_median", 0) <= TRUST_MEDIAN and reg[f].get("q_p95", 0) <= TRUST_P95]
        an.build_covered()
        an.build_exclusion(cand_dilate=cand_dilate)
        # untrusted frames do not enter the baseline
        excl = {f: (an.excl[f] if f in self.trusted else np.ones_like(an.excl[f])) for f in an.frames}
        self.excl_b = excl
        self.base, _, self.nv = an.baseline(0.7, exclude=excl)
        self.conf = {f: an.glare_stroke(self.base, f, 0.7, T0, T1) for f in an.frames}
        k3 = np.ones((3, 3), np.uint8)
        self.glare = {f: cv2.dilate((self.conf[f] > CONF_ON).astype(np.uint8), k3) > 0 for f in an.frames}
        self.cov = an.cov
        # donor pixels must be away from fingers (cand_d) and their shadow (excl)
        self.unusable = {f: an.excl[f] for f in an.frames}

    def glare_target(self, grow=3):
        ker = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * grow + 1, 2 * grow + 1))
        return (cv2.dilate((self.conf[self.ref] > CONF_ON).astype(np.uint8), ker) > 0) & ~self.cov[self.ref]

    def clean(self, f, for_glare=True):
        """Reduced-resolution mask of pixels of frame f that may serve as donor pixels."""
        c = ~self.unusable[f]
        if for_glare:
            c &= ~self.glare[f]
        return c

    def greedy_donors(self, target, n, pool=None, for_glare=True):
        pool = [f for f in (pool or self.an.frames) if f != self.ref]
        chosen, cnt = [], np.zeros(target.shape, np.int32)
        for _ in range(n):
            best, bg = None, 0
            for f in pool:
                if f in chosen:
                    continue
                g = int((self.clean(f, for_glare) & target & (cnt < 1)).sum()) * 4 + int((self.clean(f, for_glare) & target & (cnt == 1)).sum())
                if g > bg:
                    best, bg = f, g
            if best is None:
                break
            chosen.append(best)
            cnt += self.clean(best, for_glare).astype(np.int32)
        return chosen, cnt

    def patch(self, target, donors, for_glare=True, sigma_label=1.5, images=None):
        """Priority-ordered single donor per pixel with feathered label maps.
        Returns the patch image (full resolution, float BGR), the filled mask (reduced)."""
        remaining = target.copy()
        labels = []
        for f in donors:
            use = remaining & self.clean(f, for_glare)
            labels.append(use)
            remaining &= ~use
        filled = target & ~remaining
        acc = np.zeros((L.PH, L.PW, 3), np.float32)
        wsum = np.zeros((L.PH, L.PW), np.float32)
        for f, lab in zip(donors, labels):
            if not lab.any():
                continue
            # the label may bleed only into pixels where this donor is usable
            w = cv2.GaussianBlur(lab.astype(np.float32), (0, 0), sigma_label) * self.clean(f, for_glare)
            w = up(w)
            acc += (images[f] if images is not None and f in images else self.an.full_f(f)) * w[..., None]
            wsum += w
        patch = acc / np.maximum(wsum, 1e-6)[..., None]
        return patch, filled, wsum > 1e-3


def feather_blend(ref_f, patch, mask_low, sigma=6.0, valid=None):
    m = cv2.GaussianBlur(up(mask_low.astype(np.float32)), (0, 0), sigma)
    if valid is not None:
        m = m * valid
    return ref_f * (1 - m[..., None]) + patch * m[..., None], m


def _down(img):
    return cv2.resize(cv2.GaussianBlur(img, (5, 5), 1.0), (img.shape[1] // 2, img.shape[0] // 2), interpolation=cv2.INTER_NEAREST)


def _up(img, shape):
    return cv2.GaussianBlur(cv2.resize(img, (shape[1], shape[0]), interpolation=cv2.INTER_LINEAR), (5, 5), 1.0)


def laplacian_blend(ref_f, patch, mask_low, levels=5, valid=None):
    """Burt-Adelson blend. The mask is binary at full resolution; each level blends with the
    Gaussian pyramid of the mask. Pixels of the patch that are not valid are taken from ref."""
    m = (up(mask_low.astype(np.float32)) > 0.5).astype(np.float32)
    if valid is not None:
        m = m * valid
        patch = np.where(valid[..., None] > 0, patch, ref_f)
    h, w = ref_f.shape[:2]
    hp, wp = (h + (1 << levels) - 1) >> levels << levels, (w + (1 << levels) - 1) >> levels << levels
    pad = lambda a: cv2.copyMakeBorder(a, 0, hp - h, 0, wp - w, cv2.BORDER_REFLECT)
    a, b, mm = pad(ref_f), pad(patch), pad(m)
    ga, gb, gm = [a], [b], [mm]
    for _ in range(levels):
        ga.append(_down(ga[-1]))
        gb.append(_down(gb[-1]))
        gm.append(_down(gm[-1]))
    out = ga[-1] * (1 - gm[-1][..., None]) + gb[-1] * gm[-1][..., None]
    for l in range(levels - 1, -1, -1):
        la = ga[l] - _up(ga[l + 1], ga[l].shape)
        lb = gb[l] - _up(gb[l + 1], gb[l].shape)
        out = _up(out, ga[l].shape) + la * (1 - gm[l][..., None]) + lb * gm[l][..., None]
    return out[:h, :w], m


def soft_min(stack, tau=0.03, valid=None):
    """Per-pixel soft minimum on luma: weights exp(-(y - y_min) / tau)."""
    ys = np.stack([luma(s) for s in stack])
    if valid is not None:
        ys = np.where(valid, ys, np.inf)
    ymin = ys.min(axis=0)
    fin = np.isfinite(ys)
    w = np.where(fin, np.exp(-(np.where(fin, ys, 0.0) - np.where(np.isfinite(ymin), ymin, 0.0)) / tau), 0.0)
    acc = np.zeros_like(stack[0])
    for s, wi in zip(stack, w):
        acc += s * wi[..., None]
    ws = w.sum(0)
    return np.where(ws[..., None] > 0, acc / np.maximum(ws, 1e-6)[..., None], stack[0])


def hard_min(stack, valid=None):
    ys = np.stack([luma(s) for s in stack])
    if valid is not None:
        ys = np.where(valid, ys, np.inf)
        ys[0] = np.where(np.isfinite(ys).any(axis=0), ys[0], 0.0)  # nothing valid: keep the reference
    idx = ys.argmin(axis=0)
    out = np.zeros_like(stack[0])
    for i, s in enumerate(stack):
        out[idx == i] = s[idx == i]
    return out


def median_stack(stack, valid=None):
    st = np.stack(stack)
    if valid is None:
        return np.median(st, axis=0)
    st = np.where(valid[..., None], st, np.nan)
    import warnings

    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        med = np.nanmedian(st, axis=0)
    return np.where(np.isfinite(med), med, stack[0])


def tenengrad(y, mask):
    gx = cv2.Sobel(y, cv2.CV_32F, 1, 0, ksize=3) / 8.0
    gy = cv2.Sobel(y, cv2.CV_32F, 0, 1, ksize=3) / 8.0
    return float((gx * gx + gy * gy)[mask].mean())


def text_mask(y, white, win=25):
    """Pixels near thin dark strokes: local contrast high, but not inside large dark areas."""
    dark = (y < 0.6 * white).astype(np.uint8)
    big = cv2.morphologyEx(dark, cv2.MORPH_OPEN, np.ones((15, 15), np.uint8))
    strokes = cv2.dilate((dark & ~big.astype(bool)).astype(np.uint8), np.ones((win, win), np.uint8)) > 0
    return strokes & ~(cv2.dilate(big, np.ones((31, 31), np.uint8)) > 0)
