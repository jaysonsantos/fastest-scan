"""Shared analysis steps for Q4..Q6: gain compensation, covered (finger) masks, low-percentile
baseline, glare confidence. All on K-times reduced aligned pages (K = 4 by default)."""
import cv2
import numpy as np

import fslib as L
from stack import PageStack, box_down, to_f

YW = np.array([0.114, 0.587, 0.299], np.float32)
K = 4  # analysis scale: page 300 x 425


def luma(img):
    return img @ YW


def channel_gains(ref_s, img_s, ins_s):
    """One gain per channel: exp(median(log(ref / img))) on paper-like pixels."""
    ry, ay = luma(ref_s), luma(img_s)
    v = ins_s & (ry > 0.3) & (ry < 0.94) & (ay > 0.3) & (ay < 0.94) & (np.abs(ry / np.maximum(ay, 1e-3) - 1) < 0.3)
    if v.sum() < 200:
        return np.ones(3, np.float32)
    return np.array([np.exp(np.median(np.log(ref_s[..., c][v] / img_s[..., c][v]))) for c in range(3)], np.float32)


def tile_gain(ref_s, img_s, valid, tile=16, lo=0.75, hi=1.33):
    """Per-channel gain on tiles (median of ref / img over paper pixels), hole fill, 3x3 median,
    bilinear up-sampling. Returns an (h, w, 3) gain map."""
    h, w = valid.shape
    ny, nx = int(np.ceil(h / tile)), int(np.ceil(w / tile))
    g = np.ones((ny, nx, 3), np.float32)
    ok = np.zeros((ny, nx), bool)
    for j in range(ny):
        for i in range(nx):
            sl = (slice(j * tile, (j + 1) * tile), slice(i * tile, (i + 1) * tile))
            v = valid[sl]
            if v.sum() >= 0.25 * v.size:
                g[j, i] = np.median(ref_s[sl][v] / np.maximum(img_s[sl][v], 1e-3), axis=0)
                ok[j, i] = True
    if not ok.any():
        return np.ones((h, w, 3), np.float32)
    g = L.fill_holes(g, ok)
    g = np.clip(L.median3(g), lo, hi)
    g = cv2.GaussianBlur(g, (0, 0), 0.8, borderType=cv2.BORDER_REPLICATE)
    # tile centres -> pixels (bilinear)
    fx = np.clip((np.arange(w) + 0.5) / tile - 0.5, 0, nx - 1).astype(np.float32)
    fy = np.clip((np.arange(h) + 0.5) / tile - 0.5, 0, ny - 1).astype(np.float32)
    mx, my = np.meshgrid(fx, fy)
    return cv2.remap(g, mx, my, cv2.INTER_LINEAR, borderMode=cv2.BORDER_REPLICATE)


class Analysis:
    """Aligned stack of one page: full-resolution uint8 pages + reduced float pages."""

    def __init__(self, spread, page, frames, mode="grid", k=K, compensate=True, local_gain=True):
        self.st = PageStack(spread, page)
        self.ref = self.st.ref
        self.k = k
        self.frames = [n for n in frames if n in self.st.reg and self.st.reg[n]["good"]]
        if self.ref not in self.frames:
            self.frames = [self.ref] + self.frames
        self.full, self.low, self.ins, self.gain, self.gmap = {}, {}, {}, {}, {}
        for n in self.frames:
            a = self.st.aligned(n, mode=mode)
            self.full[n] = a
            self.low[n] = box_down(to_f(a), k)
            self.ins[n] = box_down(self.st.inside(n, mode="grid" if mode == "grid" else "h").astype(np.float32), k) > 0.99
        y = luma(self.low[self.ref])
        self.white = float(np.percentile(y, 80))  # paper level of the reference
        pm = y > 0.9 * self.white
        r0 = self.low[self.ref]
        self.paper_chroma = float(np.median(((r0[..., 2] - r0[..., 0]) / (r0[..., 2] + r0[..., 0] + 1e-6))[pm]))
        # 1. one gain per channel and frame
        for n in self.frames:
            g = channel_gains(self.low[self.ref], self.low[n], self.ins[n]) if compensate else np.ones(3, np.float32)
            self.gain[n] = g
            self.low[n] = self.low[n] * g
        # 2. smooth local gain map from paper pixels (64 px tiles at full resolution)
        if local_gain and compensate:
            cand = {n: cv2.dilate(self.candidates(n).astype(np.uint8), np.ones((9, 9), np.uint8)) > 0 for n in self.frames}
            ry = luma(self.low[self.ref])
            for n in self.frames:
                ay = luma(self.low[n])
                v = self.ins[n] & ~cand[n] & ~cand[self.ref] & (ry > 0.85 * self.white) & (ay > 0.85 * self.white)
                self.gmap[n] = tile_gain(self.low[self.ref], self.low[n], v) if n != self.ref else np.ones_like(self.low[n])
                self.low[n] = self.low[n] * self.gmap[n]
        else:
            for n in self.frames:
                self.gmap[n] = np.ones_like(self.low[n])

    def full_f(self, n):
        g = cv2.resize(self.gmap[n], (L.PW, L.PH), interpolation=cv2.INTER_LINEAR) if n != self.ref else 1.0
        return to_f(self.full[n]) * self.gain[n] * g

    # ------------------------------------------------------------------ covered regions
    def candidates(self, n, thr=0.72, open_r=12, chroma_thr=0.07):
        """Non-paper region connected to the outside of the page (flood fill from the border).
        Opening with radius open_r (reduced px; 12 = 48 full-res px) removes text, rules and header
        bars (dark print narrower than ~100 px) first; a finger is 170..250 px wide."""
        y = luma(self.low[n])
        im = self.low[n]
        chroma = (im[..., 2] - im[..., 0]) / (im[..., 2] + im[..., 0] + 1e-6)  # (R - B) / (R + B)
        # dark, or clearly redder than paper (skin in the light, finger nails)
        nonpaper = ((y < thr * self.white) | (chroma > self.paper_chroma + chroma_thr) | ~self.ins[n]).astype(np.uint8)
        ker = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * open_r + 1, 2 * open_r + 1))
        op = cv2.morphologyEx(nonpaper, cv2.MORPH_OPEN, ker)
        op[~self.ins[n]] = 1
        num, lab = cv2.connectedComponents(op, connectivity=8)
        border = np.unique(np.concatenate([lab[0], lab[-1], lab[:, 0], lab[:, -1]]))
        border = border[border != 0]
        return np.isin(lab, border)

    def build_covered(self, dilate_r=5, diff_thr=0.12, min_votes=2):
        """cand[n]: candidates (no confirmation), used to exclude donor pixels (after dilation).
        cov[n]: candidates confirmed by disagreement with >= min_votes other frames that are not
        candidates at that pixel; closed and dilated."""
        self.cand = {n: self.candidates(n) for n in self.frames}
        ker = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * dilate_r + 1, 2 * dilate_r + 1))
        self.cand_d = {n: cv2.dilate(self.cand[n].astype(np.uint8), ker) > 0 for n in self.frames}
        yb = {n: cv2.GaussianBlur(luma(self.low[n]), (0, 0), 1.5) for n in self.frames}
        self.cov = {}
        for n in self.frames:
            votes = np.zeros(yb[n].shape, np.int32)
            for m in self.frames:
                if m == n:
                    continue
                votes += ((np.abs(yb[m] - yb[n]) > diff_thr) & ~self.cand[m]).astype(np.int32)
            need = min(min_votes, max(1, len(self.frames) - 1))
            c = (self.cand[n] & (votes >= need)).astype(np.uint8)
            c = cv2.morphologyEx(c, cv2.MORPH_CLOSE, ker)
            self.cov[n] = (cv2.dilate(c, ker) > 0) | ~self.ins[n]
        return self.cov

    def build_exclusion(self, cand_dilate=10, win=5, rel=0.90):
        """excl[n]: samples that must not enter the glare baseline and must not be donor pixels.
          - candidates (fingers), dilated by cand_dilate reduced px (soft shadow at the finger);
          - shadow: the local paper level of the frame (grey dilation of the luma over
            (2*win+1)^2 reduced px, then blur) is below rel * P, where P is the k-th lowest local
            paper level over the frames (k = 3rd lowest, or 15 % of the frames) and P is
            paper-like (> 0.85 white). So at most the k darkest frames are dropped per pixel, and
            a dark print that most frames show under glare is NOT taken for a shadow."""
        ker = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * cand_dilate + 1, 2 * cand_dilate + 1))
        kw = np.ones((2 * win + 1, 2 * win + 1), np.uint8)
        lp = {}
        for n in self.frames:
            v = cv2.dilate(luma(self.low[n]), kw)
            lp[n] = cv2.GaussianBlur(v, (0, 0), 2.0)
        st = np.stack([np.where(self.cand_d[n], np.inf, lp[n]) for n in self.frames])
        srt = np.sort(st, axis=0)
        nv = np.isfinite(srt).sum(0)
        k = max(2, int(round(0.15 * len(self.frames))))
        idx = np.clip(np.minimum(k, nv - 1), 0, len(self.frames) - 1)
        P = np.take_along_axis(srt, idx[None], 0)[0]
        P = np.where(np.isfinite(P), P, 0.0)
        self.paper_level = P
        self.excl = {}
        for n in self.frames:
            shadow = (P > 0.85 * self.white) & (lp[n] < rel * P)
            shadow = cv2.dilate(shadow.astype(np.uint8), np.ones((5, 5), np.uint8)) > 0
            self.excl[n] = (cv2.dilate(self.cand[n].astype(np.uint8), ker) > 0) | shadow | ~self.ins[n]
        return self.excl

    # ------------------------------------------------------------------ glare
    def minch(self, n, sigma):
        m = self.low[n].min(axis=2)
        return cv2.GaussianBlur(m, (0, 0), sigma) if sigma > 0 else m

    def baseline(self, sigma, pct=None, exclude=None, rank=1):
        """Low order statistic over the stack of the blurred min channel; covered samples excluded.
        Default: the second-lowest valid sample (rank 1). With pct: index round(pct * (n - 1))."""
        st = np.stack([self.minch(n, sigma) for n in self.frames])
        if exclude is not None:
            ex = np.stack([exclude[n] for n in self.frames])
            st = np.where(ex, np.inf, st)
        srt = np.sort(st, axis=0)
        nv = np.isfinite(srt).sum(0)
        if pct is None:
            idx = np.clip(np.full(nv.shape, rank), 0, np.maximum(nv - 1, 0))
        else:
            idx = np.clip(np.maximum(1, np.round(pct * (nv - 1)).astype(int)), 0, np.maximum(nv - 1, 0))
        base = np.take_along_axis(srt, idx[None], 0)[0]
        base[nv == 0] = np.nan
        # median of the valid samples
        med_idx = np.clip((nv - 1) // 2, 0, len(self.frames) - 1)
        med = np.take_along_axis(srt, med_idx[None], 0)[0]
        return base, med, nv

    def glare_blur(self, base, n, sigma=3.0, t0=0.04, t1=0.04):
        """Variant (a) of the research note: blurred min channel against the baseline."""
        c = np.clip((self.minch(n, sigma) - base - t0) / t1, 0, 1)
        c[self.low[n].max(axis=2) >= 0.98] = 1.0
        return np.nan_to_num(c)

    def glare_stroke(self, base_fine, n, sigma_pre=0.7, t0=0.10, t1=0.10, grow=2, sigma_post=1.5):
        """Variant (b): little blur, then grey dilation, so that thin washed-out strokes count.
        base_fine must come from baseline(sigma_pre)."""
        d = self.minch(n, sigma_pre) - base_fine
        c = np.clip((np.nan_to_num(d) - t0) / t1, 0, 1)
        ker = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * grow + 1, 2 * grow + 1))
        c = cv2.dilate(c, ker)
        c = cv2.GaussianBlur(c, (0, 0), sigma_post)
        c[self.low[n].max(axis=2) >= 0.98] = 1.0
        return np.clip(c * 1.5, 0, 1)


def sharp_frames(spread, page, frames, rel=0.6):
    """Drop blurred frames: score min(mean Gx^2, mean Gy^2) < rel * median of the given frames."""
    import csv

    sc = {}
    with open(f"{L.CACHE}/sharpness.csv") as f:
        for r in csv.DictReader(f):
            if int(r["page"]) == page:
                sc[int(r["frame"])] = float(r["mind"])
    have = [n for n in frames if n in sc]
    if not have:
        return list(frames)
    med = np.median([sc[n] for n in have])
    return [n for n in frames if sc.get(n, med) >= rel * med]


def up(mask_low, k=K, w=L.PW, h=L.PH):
    """Bilinear up-sampling of a reduced-resolution map to the full page."""
    return cv2.resize(mask_low.astype(np.float32), (w, h), interpolation=cv2.INTER_LINEAR)


def overlay(img_u8, mask, color=(0, 0, 255), alpha=0.45):
    out = img_u8.astype(np.float32)
    m = np.clip(mask, 0, 1)[..., None] * alpha
    return np.clip(out * (1 - m) + np.array(color, np.float32) * m, 0, 255).astype(np.uint8)
