"""Q5: fusion rules on real crops.
  (i-a) reference + masked patch from donors, feathered (Gaussian sigma 6 px)
  (i-b) reference + masked patch, 5-level Laplacian pyramid blend
  (ii)  per-pixel soft minimum over the N-frame stack (tau 0.03)
  (iii) per-pixel median over the stack
  (min) per-pixel hard minimum (for comparison)
N = 8 frames: the reference + 7 donors from the greedy cover of the reference glare mask.
"""
import sys

import cv2
import numpy as np

import fslib as L
import fusion as F
from analysis import luma, overlay, up

CASES = [("A", 1), ("B", 1), ("C", 1), ("C", 0), ("A", 0), ("B", 0)]
if len(sys.argv) > 1:
    CASES = [(a[0], int(a[1])) for a in sys.argv[1:]]
N = 8
results = {}


def best_window(score, ww, hh):
    ii = cv2.integral(score.astype(np.float32))
    s = ii[hh:, ww:] - ii[:-hh, ww:] - ii[hh:, :-ww] + ii[:-hh, :-ww]
    y, x = np.unravel_index(np.argmax(s), s.shape)
    return int(x), int(y)


for sname, p in CASES:
    m = F.Model(sname, p)
    an, ref = m.an, m.ref
    W = an.white
    target = m.glare_target()
    donors, cnt = m.greedy_donors(target, N - 1, pool=m.trusted)
    patch, filled, valid = m.patch(target, donors)
    ref_f = an.full_f(ref)
    validf = valid.astype(np.float32)
    out = {}
    out["reference"] = ref_f
    out["(i-a) ref + patch, feather"], mf = F.feather_blend(ref_f, patch, filled, 6.0, validf)
    out["(i-b) ref + patch, Laplacian 5 levels"], _ = F.laplacian_blend(ref_f, patch, filled, 5, validf)
    stack = [ref_f] + [an.full_f(d) for d in donors]
    okst = np.stack([up((~m.unusable[f]).astype(np.float32)) > 0.5 for f in [ref] + donors])
    out["(ii) soft minimum"] = F.soft_min(stack, 0.03, okst)
    out["(iii) median"] = F.median_stack(stack, okst)
    out["hard minimum"] = F.hard_min(stack, okst)
    # ------------------------------------------------------------ regions
    clean_y = luma(out["(i-b) ref + patch, Laplacian 5 levels"])
    tm = F.text_mask(clean_y, W)
    all_ok = okst.all(axis=0)
    Mfull = up(cv2.dilate(target.astype(np.uint8), np.ones((5, 5), np.uint8)).astype(np.float32)) > 0.5
    Mcore = up(filled.astype(np.float32)) > 0.99
    outside = tm & all_ok & ~Mfull
    inside = tm & all_ok & Mcore
    ink_out = outside & (clean_y < 0.6 * W)
    ink_core_in = inside & (cv2.erode((clean_y < 0.42 * W).astype(np.uint8), np.ones((3, 3), np.uint8)) > 0)
    paper_out = all_ok & ~Mfull & (clean_y > 0.9 * W)
    y_ref = luma(ref_f)
    t_ref_out = F.tenengrad(y_ref, outside)
    t_patch_in = F.tenengrad(luma(patch), inside) if inside.sum() > 100 else float("nan")
    rec = dict(frames=[int(ref)] + [int(d) for d in donors], target_fraction=float(target.mean()), filled_fraction=float(filled.sum() / max(target.sum(), 1)), methods={})
    for name, img in out.items():
        y = luma(img)
        r = dict(
            sharp_out=F.tenengrad(y, outside) / t_ref_out,
            sharp_in=(F.tenengrad(y, inside) / t_patch_in) if inside.sum() > 100 else None,
            ink_area_out=float((y[outside] < 0.6 * W).mean() / max((y_ref[outside] < 0.6 * W).mean(), 1e-9)),
            ink_luma_in=float(y[ink_core_in].mean()) if ink_core_in.sum() > 50 else None,
            paper_out=float(y[paper_out].mean() / y_ref[paper_out].mean()),
        )
        rec["methods"][name] = r
    results[f"{sname}{p}"] = rec
    print(f"== {sname} p{p}: frames {rec['frames']}, glare target {rec['target_fraction']*100:.2f}% of page, filled {rec['filled_fraction']*100:.1f}%")
    print(f"   {'method':40s} sharp_out  sharp_in  ink_area_out  ink_luma_in  paper_out")
    for name, r in rec["methods"].items():
        f = lambda v: "   -  " if v is None else f"{v:6.3f}"
        print(f"   {name:40s}  {f(r['sharp_out'])}    {f(r['sharp_in'])}    {f(r['ink_area_out'])}      {f(r['ink_luma_in'])}     {f(r['paper_out'])}")
    sys.stdout.flush()
    # ------------------------------------------------------------ pictures
    ww, hh = 1000, 300
    x0, y0 = best_window((up(target.astype(np.float32)) > 0.5) & tm, ww, hh)
    rows_ = []
    for name, img in out.items():
        r = rec["methods"][name]
        c = np.clip(img[y0 : y0 + hh, x0 : x0 + ww] * 255 + 0.5, 0, 255).astype(np.uint8)
        txt = f"{name} | sharpness outside mask {r['sharp_out']:.2f}, ink area {r['ink_area_out']:.2f}"
        rows_.append(L.label(c, txt, org=(8, 24), scale=0.6))
    mk = overlay(np.clip(ref_f * 255, 0, 255).astype(np.uint8), up(filled.astype(np.float32)), (0, 0, 255), 0.45)
    rows_.insert(1, L.label(mk[y0 : y0 + hh, x0 : x0 + ww], "reference with the replaced mask (red)", org=(8, 24), scale=0.6))
    L.save_jpg(f"{L.OUT}/q5_fusion_rules_glare_crop_fullres_{sname}_p{p}.jpg", L.vstack(rows_), q=93)
    # 3x zoom on text OUTSIDE the mask: blur / stroke thickening of the stack rules
    sx, sy = best_window(outside & (clean_y < 0.6 * W), 260, 90)
    zs = []
    for name, img in out.items():
        c = np.clip(img[sy : sy + 90, sx : sx + 260] * 255 + 0.5, 0, 255).astype(np.uint8)
        c = cv2.resize(c, None, fx=3, fy=3, interpolation=cv2.INTER_NEAREST)
        zs.append(L.label(c, name, org=(6, 20), scale=0.55))
    L.save_jpg(f"{L.OUT}/q5_fusion_rules_text_outside_mask_zoom3x_{sname}_p{p}.jpg", L.vstack([L.hstack(zs[0:2]), L.hstack(zs[2:4]), L.hstack(zs[4:6])]), q=93)
    # overview of the page: reference | (i-b) | soft-min | median
    ov = []
    for name in ("reference", "(i-b) ref + patch, Laplacian 5 levels", "(ii) soft minimum", "(iii) median"):
        c = np.clip(out[name] * 255 + 0.5, 0, 255).astype(np.uint8)
        c = cv2.resize(c, (L.PW // 3, L.PH // 3), interpolation=cv2.INTER_AREA)
        ov.append(L.label(c, name, org=(6, 22), scale=0.55))
    L.save_jpg(f"{L.OUT}/q5_fusion_rules_page_overview_{sname}_p{p}.jpg", L.hstack(ov), q=90, max_w=1600)
L.dump_json("q5_fusion.json", results)
