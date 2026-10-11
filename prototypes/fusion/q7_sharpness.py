"""Q7: per-frame sharpness scores, at full resolution and at quarter resolution.

Scores are means over the upper part of each page quad (rows 6 %..62 %, columns 8 %..92 %),
so the fingers at the bottom edge do not count.
  ten   = mean(Gx^2 + Gy^2)            (Tenengrad, Sobel)
  mind  = min(mean Gx^2, mean Gy^2)    (penalises blur in one direction = motion blur)
  lapv  = variance of the 3x3 Laplacian
Output: cache/sharpness.csv
"""
import os
import sys

import cv2
import numpy as np

import fslib as L

rows = L.load_csv()
frames = sorted(int(f[2:8]) for f in os.listdir(L.FRAMES) if f.endswith(".jpg"))


def sub_quad(q, u0, u1, v0, v1):
    H = L.homography_lstsq(np.array([[0, 0], [1, 0], [1, 1], [0, 1]], float), q)
    return L.apply_h(H, np.array([[u0, v0], [u1, v0], [u1, v1], [u0, v1]], float))


def scores(g, poly):
    x0, y0 = np.floor(poly.min(0)).astype(int) - 2
    x1, y1 = np.ceil(poly.max(0)).astype(int) + 3
    x0, y0 = max(x0, 0), max(y0, 0)
    x1, y1 = min(x1, g.shape[1]), min(y1, g.shape[0])
    if x1 - x0 < 16 or y1 - y0 < 16:
        return None
    c = g[y0:y1, x0:x1]
    m = np.zeros(c.shape, np.uint8)
    cv2.fillConvexPoly(m, np.round(poly - [x0, y0]).astype(np.int32), 1)
    m = m.astype(bool)
    if m.sum() < 200:
        return None
    gx = cv2.Sobel(c, cv2.CV_32F, 1, 0, ksize=3) / 8.0
    gy = cv2.Sobel(c, cv2.CV_32F, 0, 1, ksize=3) / 8.0
    lap = cv2.Laplacian(c, cv2.CV_32F, ksize=1)
    ex, ey = float((gx[m] ** 2).mean()), float((gy[m] ** 2).mean())
    return ex + ey, min(ex, ey), float(lap[m].var())


out = open(os.path.join(L.CACHE, "sharpness.csv"), "w")
out.write("frame,page,ten,mind,lapv,ten_q,mind_q,lapv_q,area\n")
for n in frames:
    r = rows[n]
    if r["detected"] < 1 or r["pages"] < 2:
        continue
    bgr = L.load_frame(n)
    g = L.gray01(bgr)
    gq = cv2.resize(g, (960, 540), interpolation=cv2.INTER_AREA)
    for p in (0, 1):
        q = r["quads"][p]
        poly = sub_quad(q, 0.08, 0.92, 0.06, 0.62)
        s = scores(g, poly)
        sq = scores(gq, (poly + 0.5) / 4.0 - 0.5)
        if s is None or sq is None:
            continue
        area = 0.5 * abs(np.dot(q[:, 0], np.roll(q[:, 1], -1)) - np.dot(q[:, 1], np.roll(q[:, 0], -1)))
        out.write(f"{n},{p},{s[0]:.6e},{s[1]:.6e},{s[2]:.6e},{sq[0]:.6e},{sq[1]:.6e},{sq[2]:.6e},{area:.0f}\n")
    if n % 20 == 0:
        print(n, file=sys.stderr, flush=True)
out.close()
print("written", os.path.join(L.CACHE, "sharpness.csv"))
