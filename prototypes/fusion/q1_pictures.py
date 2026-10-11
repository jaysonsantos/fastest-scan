"""Q1 pictures: (1) red/cyan overlay of reference and frame after each registration stage
(colour fringes = misalignment), (2) the non-rigid part (local flow after the homography)."""
import cv2
import numpy as np

import fslib as L
import fusion as F
from analysis import luma, to_f
from stack import PageStack

CASES = [("A", 0, 508), ("A", 0, 498), ("A", 1, 502), ("B", 1, 908), ("C", 0, 1082), ("C", 1, 1150)]


def anaglyph(a, b):
    """a (reference) in red, b in green + blue."""
    a8, b8 = np.clip(a * 255, 0, 255).astype(np.uint8), np.clip(b * 255, 0, 255).astype(np.uint8)
    return np.dstack([b8, b8, a8])


for sname, p, n in CASES:
    st = PageStack(sname, p)
    if n not in st.reg or not st.reg[n]["good"]:
        print("skip", sname, p, n)
        continue
    ref_y = luma(to_f(st.aligned(st.ref)))
    tm = F.text_mask(ref_y, float(np.percentile(ref_y, 80)))
    tm[int(L.PH * 0.7) :] = False
    ii = cv2.integral(tm.astype(np.float32))
    ww, hh = 520, 150
    s = ii[hh:, ww:] - ii[:-hh, ww:] - ii[hh:, :-ww] + ii[:-hh, :-ww]
    y0, x0 = np.unravel_index(np.argmax(s), s.shape)
    tiles = []
    for mode, name in (("quad", "corners only"), ("h", "refined homography"), ("grid", "homography + local grid")):
        if mode == "quad" and st.reg[n].get("H_quad") is None:
            continue
        y = luma(to_f(st.aligned(n, mode=mode)))
        c = anaglyph(ref_y[y0 : y0 + hh, x0 : x0 + ww], y[y0 : y0 + hh, x0 : x0 + ww])
        c = cv2.resize(c, None, fx=2, fy=2, interpolation=cv2.INTER_CUBIC)
        tiles.append(L.label(c, f"{name} (red = reference {st.ref}, cyan = frame {n})", org=(6, 22), scale=0.6, color=(0, 0, 0)))
    L.save_jpg(f"{L.OUT}/q1_registration_stages_red_cyan_zoom2x_{sname}_p{p}_frame{n}.jpg", L.vstack(tiles), q=93)
    # non-rigid part
    flow = st.flow(n)
    img = cv2.resize(st.aligned(n), (L.PW // 2, L.PH // 2), interpolation=cv2.INTER_AREA)
    img = (img.astype(np.float32) * 0.6 + 100).clip(0, 255).astype(np.uint8)
    mag = np.sqrt((flow**2).sum(-1))
    for yy in range(40, L.PH, 80):
        for xx in range(40, L.PW, 80):
            d = flow[yy, xx]
            m = float(np.hypot(*d))
            col = (0, 160, 0) if m < 0.5 else ((0, 140, 255) if m < 1.5 else (0, 0, 255))
            cv2.arrowedLine(img, (xx // 2, yy // 2), (int(xx / 2 + d[0] * 15), int(yy / 2 + d[1] * 15)), col, 2, cv2.LINE_AA, tipLength=0.3)
    img = L.label(img, f"{sname} p{p} frame {n}: local flow after homography, arrows x30", org=(6, 22), scale=0.55)
    img = L.label(img, f"median {np.median(mag):.2f} px, p95 {np.percentile(mag, 95):.2f}, max {mag.max():.1f} (green < 0.5, orange < 1.5, red >= 1.5)", org=(6, 44), scale=0.5)
    L.save_jpg(f"{L.OUT}/q1_nonrigid_flow_{sname}_p{p}_frame{n}.jpg", img, q=88)
    print("done", sname, p, n, "flow median %.2f p95 %.2f max %.2f" % (np.median(mag), np.percentile(mag, 95), mag.max()))
