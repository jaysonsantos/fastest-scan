"""Shared primitives for the multi-frame fusion prototype.

Every function here is a primitive that is simple to write by hand in Zig:
 - 4-point / least-squares homography (normalised DLT, weighted, robust loop)
 - perspective warp with bilinear / bicubic sampling (cv2.remap is only the sampler)
 - 2x box pyramid, Gaussian blur, Sobel
 - block matching by zero-mean normalised cross-correlation (ZNCC) on an integer search
   window plus a parabola sub-pixel fit (cv2.matchTemplate is only the correlator)
 - sparse grid of translations, hole fill, 3x3 median, bilinear up-sample to a flow field

OpenCV-only functions (ORB, findHomography, ECC, Farneback) are NOT in this file.
"""
import os

os.environ.setdefault("OMP_NUM_THREADS", "4")
os.environ.setdefault("OPENBLAS_NUM_THREADS", "4")
os.environ.setdefault("MKL_NUM_THREADS", "4")

import csv
import json
import time

import cv2
import numpy as np

cv2.setNumThreads(4)

ROOT = os.path.dirname(os.path.abspath(__file__))
FRAMES = os.path.join(ROOT, "frames")
OUT = os.path.join(ROOT, "out")
CACHE = os.path.join(ROOT, "cache")
# The table of `fastest-scan --debug-dir .cache/debug`, from the repository root.
CSV_PATH = os.path.join(ROOT, "..", "..", ".cache", "debug", "analysis.csv")
PW, PH = 1200, 1700  # rectified page size (full resolution)

os.makedirs(OUT, exist_ok=True)
os.makedirs(CACHE, exist_ok=True)


# ----------------------------------------------------------------------------- data
def load_csv():
    rows = {}
    with open(CSV_PATH) as f:
        for r in csv.DictReader(f):
            n = int(r["frame"])
            d = {k: float(v) for k, v in r.items()}
            quads = []
            for p in (0, 1):
                q = np.array(
                    [[d[f"p{p}_{c}_x"], d[f"p{p}_{c}_y"]] for c in ("tl", "tr", "br", "bl")],
                    dtype=np.float64,
                )
                quads.append(q * 4.0)  # 960x540 -> 3840x2160
            d["quads"] = quads
            rows[n] = d
    return rows


def load_frame(n):
    p = os.path.join(FRAMES, f"f_{n:06d}.jpg")
    img = cv2.imread(p, cv2.IMREAD_COLOR)
    if img is None:
        raise FileNotFoundError(p)
    return img


def gray01(bgr):
    """Luma in 0..1, float32 (BT.601 weights)."""
    b = bgr.astype(np.float32)
    return (0.114 * b[..., 0] + 0.587 * b[..., 1] + 0.299 * b[..., 2]) / 255.0


# ----------------------------------------------------------------------- homography
def _normalise(pts):
    c = pts.mean(0)
    s = np.sqrt(2.0) / (np.sqrt(((pts - c) ** 2).sum(1)).mean() + 1e-12)
    T = np.array([[s, 0, -s * c[0]], [0, s, -s * c[1]], [0, 0, 1.0]])
    return (pts - c) * s, T


def homography_lstsq(src, dst, w=None):
    """Normalised DLT. src, dst: (N,2), N >= 4. w: optional weights (N,). Returns H with dst ~ H src."""
    src = np.asarray(src, np.float64)
    dst = np.asarray(dst, np.float64)
    a, Ta = _normalise(src)
    b, Tb = _normalise(dst)
    n = len(a)
    A = np.zeros((2 * n, 9))
    x, y, u, v = a[:, 0], a[:, 1], b[:, 0], b[:, 1]
    A[0::2, 0], A[0::2, 1], A[0::2, 2] = -x, -y, -1
    A[0::2, 6], A[0::2, 7], A[0::2, 8] = u * x, u * y, u
    A[1::2, 3], A[1::2, 4], A[1::2, 5] = -x, -y, -1
    A[1::2, 6], A[1::2, 7], A[1::2, 8] = v * x, v * y, v
    if w is not None:
        ww = np.repeat(np.sqrt(np.asarray(w, np.float64)), 2)
        A = A * ww[:, None]
    # smallest eigenvector of A^T A (a 9x9 symmetric eigen problem; Jacobi by hand in Zig)
    _, _, vt = np.linalg.svd(A.T @ A)
    Hn = vt[-1].reshape(3, 3)
    H = np.linalg.inv(Tb) @ Hn @ Ta
    return H / H[2, 2]


def apply_h(H, pts):
    pts = np.asarray(pts, np.float64)
    p = np.c_[pts, np.ones(len(pts))] @ H.T
    return p[:, :2] / p[:, 2:3]


def robust_homography(src, dst, iters=6, k=2.5, min_sigma=0.15):
    """Iteratively re-weighted least squares with a hard cut at k * sigma (sigma from MAD).
    Returns H, inlier mask, sigma."""
    src = np.asarray(src, np.float64)
    dst = np.asarray(dst, np.float64)
    w = np.ones(len(src))
    H = np.eye(3)
    sigma = 0.0
    for _ in range(iters):
        if w.sum() < 4:
            break
        H = homography_lstsq(src, dst, w)
        r = np.sqrt(((apply_h(H, src) - dst) ** 2).sum(1))
        sigma = max(1.4826 * np.median(r[w > 0]), min_sigma)
        w = (r < k * sigma).astype(np.float64)
    return H, w > 0, sigma


def page_rect(w=PW, h=PH):
    return np.array([[0, 0], [w - 1, 0], [w - 1, h - 1], [0, h - 1]], np.float64)


def quad_homography(quad, w=PW, h=PH):
    """Homography from rectified page pixels to full-resolution frame pixels."""
    return homography_lstsq(page_rect(w, h), quad)


# ----------------------------------------------------------------------------- warp
_grid_cache = {}


def _grid(w, h):
    key = (w, h)
    if key not in _grid_cache:
        xs, ys = np.meshgrid(np.arange(w, dtype=np.float32), np.arange(h, dtype=np.float32))
        _grid_cache[key] = (xs, ys)
    return _grid_cache[key]


def warp(frame, H, w=PW, h=PH, flow=None, interp=cv2.INTER_LINEAR, scale=1.0):
    """Sample `frame` at H * (x + flow(x)) for each output pixel x of a w x h page.
    `scale`: output pixel size in page units (2.0 -> half-resolution page of size w/2 x h/2;
    the caller must give a frame that is low-pass filtered accordingly, and an H for that frame)."""
    ow, oh = int(round(w / scale)), int(round(h / scale))
    xs, ys = _grid(ow, oh)
    if scale != 1.0:
        xs = (xs + 0.5) * scale - 0.5
        ys = (ys + 0.5) * scale - 0.5
    if flow is not None:
        xs = xs + flow[..., 0]
        ys = ys + flow[..., 1]
    H = H.astype(np.float32)
    d = H[2, 0] * xs + H[2, 1] * ys + H[2, 2]
    mx = (H[0, 0] * xs + H[0, 1] * ys + H[0, 2]) / d
    my = (H[1, 0] * xs + H[1, 1] * ys + H[1, 2]) / d
    return cv2.remap(frame, mx, my, interp, borderMode=cv2.BORDER_CONSTANT, borderValue=0)


def inside_mask(H, shape, w=PW, h=PH, flow=None, margin=2):
    """True where the sample position is inside the source frame."""
    xs, ys = _grid(w, h)
    if flow is not None:
        xs = xs + flow[..., 0]
        ys = ys + flow[..., 1]
    H = H.astype(np.float32)
    d = H[2, 0] * xs + H[2, 1] * ys + H[2, 2]
    mx = (H[0, 0] * xs + H[0, 1] * ys + H[0, 2]) / d
    my = (H[1, 0] * xs + H[1, 1] * ys + H[1, 2]) / d
    return (mx >= margin) & (my >= margin) & (mx <= shape[1] - 1 - margin) & (my <= shape[0] - 1 - margin)


def down2(img):
    """2x2 box down-sample."""
    h, w = img.shape[:2]
    img = img[: h // 2 * 2, : w // 2 * 2]
    return (img[0::2, 0::2] + img[1::2, 0::2] + img[0::2, 1::2] + img[1::2, 1::2]) * 0.25


def pyramid(img, levels):
    out = [img]
    for _ in range(levels):
        out.append(down2(out[-1]))
    return out


# ------------------------------------------------------------------- block matching
def texture_map(g):
    """Structure tensor sums per pixel (not yet window-summed): Ix^2, Iy^2, IxIy."""
    gx = cv2.Sobel(g, cv2.CV_32F, 1, 0, ksize=3) / 8.0
    gy = cv2.Sobel(g, cv2.CV_32F, 0, 1, ksize=3) / 8.0
    return gx * gx, gy * gy, gx * gy


def block_centres(w, h, step, block, search, offset=0):
    m = block // 2 + search + 1
    xs = np.arange(m + offset, w - m, step)
    ys = np.arange(m + offset, h - m, step)
    return xs, ys


def block_match(ref, img, xs, ys, block, search, min_lam=2e-5, min_zncc=0.5, mask=None, min_ratio=0.0):
    """For each block centred at (x, y) of `ref`, find d so that ref(p) ~ img(p + d).
    Integer ZNCC search in +-search, then a parabola sub-pixel fit per axis.
    Returns d (ny, nx, 2), zncc (ny, nx), ok (ny, nx).
    `min_lam`: minimum small eigenvalue of the mean structure tensor (rejects flat blocks).
    `min_ratio`: minimum ratio small/large eigenvalue (rejects blocks with one edge direction
    only = aperture problem: rules, picture outlines, page edge). `mask`: optional bool image, blocks with < 60 % True
    are rejected."""
    hb = block // 2
    ixx, iyy, ixy = texture_map(ref)
    ny, nx = len(ys), len(xs)
    d = np.zeros((ny, nx, 2), np.float32)
    sc = np.zeros((ny, nx), np.float32)
    ok = np.zeros((ny, nx), bool)
    for j, y in enumerate(ys):
        for i, x in enumerate(xs):
            y0, x0 = y - hb, x - hb
            if mask is not None and mask[y0 : y0 + block, x0 : x0 + block].mean() < 0.6:
                continue
            a = ixx[y0 : y0 + block, x0 : x0 + block].mean()
            b = iyy[y0 : y0 + block, x0 : x0 + block].mean()
            c = ixy[y0 : y0 + block, x0 : x0 + block].mean()
            root = np.sqrt(0.25 * (a - b) ** 2 + c * c)
            lam = 0.5 * (a + b) - root
            if lam < min_lam or lam < min_ratio * (0.5 * (a + b) + root):
                continue
            t = ref[y0 : y0 + block, x0 : x0 + block]
            win = img[y0 - search : y0 + block + search, x0 - search : x0 + block + search]
            r = cv2.matchTemplate(win, t, cv2.TM_CCOEFF_NORMED)
            py, px = np.unravel_index(np.argmax(r), r.shape)
            s = r[py, px]
            sc[j, i] = s
            if s < min_zncc or px == 0 or py == 0 or px == 2 * search or py == 2 * search:
                continue
            # parabola through the three samples around the peak, per axis
            l, c0, rr = r[py, px - 1], s, r[py, px + 1]
            den = l - 2 * c0 + rr
            sx = 0.5 * (l - rr) / den if den < -1e-9 else 0.0
            u, dn = r[py - 1, px], r[py + 1, px]
            den = u - 2 * c0 + dn
            sy = 0.5 * (u - dn) / den if den < -1e-9 else 0.0
            d[j, i] = (px - search + np.clip(sx, -0.5, 0.5), py - search + np.clip(sy, -0.5, 0.5))
            ok[j, i] = True
    return d, sc, ok


def residual_stats(d, ok):
    m = np.sqrt((d[ok] ** 2).sum(-1))
    if len(m) == 0:
        return dict(n=0, median=float("nan"), p95=float("nan"), max=float("nan"))
    return dict(n=int(len(m)), median=float(np.median(m)), p95=float(np.percentile(m, 95)), max=float(m.max()))


def measure(ref_g, img_g, block=48, step=60, search=6, offset=17, mask=None, min_zncc=0.9, min_ratio=0.25):
    """Residual misalignment on textured (text) blocks. `offset` moves the measurement grid away
    from the nodes used for the fit, so the measurement is not on the fitted blocks."""
    xs, ys = block_centres(ref_g.shape[1], ref_g.shape[0], step, block, search, offset)
    d, sc, ok = block_match(ref_g, img_g, xs, ys, block, search, mask=mask, min_zncc=min_zncc, min_ratio=min_ratio)
    return d, ok, xs, ys


# ---------------------------------------------------------------- sparse grid -> flow
def fill_holes(d, ok, iters=200):
    """Fill invalid nodes from valid neighbours (normalised 3x3 averaging = membrane)."""
    d = d.copy()
    w = ok.astype(np.float32)
    if w.sum() == 0:
        return np.zeros_like(d)
    val = d * w[..., None]
    k = np.ones((3, 3), np.float32)
    cur_v, cur_w = val.copy(), w.copy()
    for _ in range(iters):
        if (cur_w > 0).all():
            break
        sv = cv2.filter2D(cur_v, -1, k, borderType=cv2.BORDER_CONSTANT)
        sw = cv2.filter2D(cur_w, -1, k, borderType=cv2.BORDER_CONSTANT)
        newly = (cur_w == 0) & (sw > 0)
        cur_v[newly] = sv[newly] / sw[newly][..., None]
        cur_w[newly] = 1.0
    out = cur_v
    out[ok] = d[ok]
    return out


def median3(d):
    out = np.empty_like(d)
    for c in range(d.shape[-1]):
        p = np.pad(d[..., c], 1, mode="edge")
        st = np.stack([p[i : i + d.shape[0], j : j + d.shape[1]] for i in range(3) for j in range(3)])
        out[..., c] = np.median(st, axis=0)
    return out


def grid_to_flow(d, xs, ys, w=PW, h=PH):
    """Bilinear interpolation of node displacements to every pixel; constant extrapolation."""
    fx = np.interp(np.arange(w), xs, np.arange(len(xs))).astype(np.float32)
    fy = np.interp(np.arange(h), ys, np.arange(len(ys))).astype(np.float32)
    mx, my = np.meshgrid(fx, fy)
    return np.dstack(
        [cv2.remap(d[..., c].astype(np.float32), mx, my, cv2.INTER_LINEAR, borderMode=cv2.BORDER_REPLICATE) for c in (0, 1)]
    )


# -------------------------------------------------------------------------- output
def save_jpg(path, img, q=92, max_w=None):
    if img.dtype != np.uint8:
        img = np.clip(img * 255.0 + 0.5, 0, 255).astype(np.uint8)
    if max_w and img.shape[1] > max_w:
        s = max_w / img.shape[1]
        img = cv2.resize(img, (max_w, int(round(img.shape[0] * s))), interpolation=cv2.INTER_AREA)
    cv2.imwrite(path, img, [cv2.IMWRITE_JPEG_QUALITY, q])


def label(img, text, org=(8, 28), scale=0.8, color=(0, 0, 255)):
    img = np.array(img, copy=True, order="C")
    cv2.putText(img, text, org, cv2.FONT_HERSHEY_SIMPLEX, scale, (255, 255, 255), 4, cv2.LINE_AA)
    cv2.putText(img, text, org, cv2.FONT_HERSHEY_SIMPLEX, scale, color, 2, cv2.LINE_AA)
    return img


def hstack(imgs, gap=6):
    h = max(i.shape[0] for i in imgs)
    out = []
    for i in imgs:
        if i.ndim == 2:
            i = cv2.cvtColor(i, cv2.COLOR_GRAY2BGR)
        if i.shape[0] < h:
            i = np.pad(i, ((0, h - i.shape[0]), (0, 0), (0, 0)), constant_values=255)
        out.append(i)
        out.append(np.full((h, gap, 3), 255, np.uint8))
    return np.hstack(out[:-1])


def vstack(imgs, gap=6):
    w = max(i.shape[1] for i in imgs)
    out = []
    for i in imgs:
        if i.ndim == 2:
            i = cv2.cvtColor(i, cv2.COLOR_GRAY2BGR)
        if i.shape[1] < w:
            i = np.pad(i, ((0, 0), (0, w - i.shape[1]), (0, 0)), constant_values=255)
        out.append(i)
        out.append(np.full((gap, w, 3), 255, np.uint8))
    return np.vstack(out[:-1])


class Timer:
    def __init__(self):
        self.t = {}

    def add(self, k, dt):
        self.t.setdefault(k, []).append(dt)

    def summary(self):
        return {k: (float(np.mean(v)) * 1000.0, len(v)) for k, v in self.t.items()}


def dump_json(name, obj):
    with open(os.path.join(OUT, name), "w") as f:
        json.dump(obj, f, indent=1, default=float)
