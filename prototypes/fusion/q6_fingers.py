"""Q6: finger detection and repair. Also writes the final fused pages (glare + fingers).

Detector: non-paper (luma < 0.72 white) after a morphological opening, connected to the page
border (flood fill), confirmed per pixel by disagreement with >= 2 other aligned frames that are
not candidates there; then closing + dilation.
Repair: reference + patch from donors (frames where the pixel is not covered), Laplacian blend.
"""
import sys

import cv2
import numpy as np

import fslib as L
import fusion as F
from analysis import luma, overlay, to_f, up
from config import SPREADS

CASES = [("A", 0), ("A", 1), ("B", 0), ("B", 1), ("C", 0), ("C", 1)]
if len(sys.argv) > 1:
    CASES = [(a[0], int(a[1])) for a in sys.argv[1:]]
MARGIN = 6  # reduced px (24 full-res px) around the fingers of a donor frame
results, finals, refs_u8 = {}, {}, {}
u8 = lambda img: np.clip(img * 255 + 0.5, 0, 255).astype(np.uint8)

for sname, p in CASES:
    m = F.Model(sname, p, cand_dilate=MARGIN)
    an, ref, cfg = m.an, m.ref, m.cfg
    ref_f = an.full_f(ref)
    refs_u8[(sname, p)] = u8(ref_f)
    inside_page = an.ins[ref]
    target = m.cov[ref].copy()
    stable = [f for f in an.frames if f in cfg["stable"]]
    early = [f for f in an.frames if f in cfg["early"]]
    rec = dict(covered_fraction_of_page=float(target.mean()), candidates_fraction=float(an.cand[ref].mean()), stable=len(stable), early=len(early))
    # upper bound of the repair for a safety margin around the donor fingers (no shadow rule)
    rec["bound_by_margin_px"] = {}
    for mg in (0, 3, 6, 10, 14):
        kk = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * mg + 1, 2 * mg + 1))
        anyc = np.zeros(target.shape, bool)
        for f in an.frames:
            if f != ref:
                anyc |= ~(cv2.dilate(an.cand[f].astype(np.uint8), kk) > 0) & an.ins[f]
        rec["bound_by_margin_px"][mg * 4] = float((anyc & target).sum() / max(target.sum(), 1))
    for name, pool in (("stable_only", stable), ("stable_and_early", stable + early)):
        donors, cnt = m.greedy_donors(target, 6, pool=pool, for_glare=False)
        rec[name] = dict(donors=[int(d) for d in donors], repaired=float(((cnt >= 1) & target).sum() / max(target.sum(), 1)), two=float(((cnt >= 2) & target).sum() / max(target.sum(), 1)))
    donors, cnt = m.greedy_donors(target, 6, pool=stable + early, for_glare=False)
    # ---------------------------------------------- registration needed under the fingers
    # donor-to-donor consistency inside the hole, homography only vs homography + grid
    if len(donors) >= 2:
        d1, d2 = donors[0], donors[1]
        near = cv2.dilate(target.astype(np.uint8), np.ones((51, 51), np.uint8)) > 0  # hole + 100 px
        both = up((near & m.clean(d1, False) & m.clean(d2, False)).astype(np.float32)) > 0.5
        cons = {}
        for mode in ("h", "grid"):
            g1 = luma(to_f(an.st.aligned(d1, mode=mode)))
            g2 = luma(to_f(an.st.aligned(d2, mode=mode)))
            d, ok, _, _ = L.measure(g1, g2, block=32, step=16, search=8, offset=3, mask=both, min_zncc=0.8, min_ratio=0.15)
            cons[mode] = L.residual_stats(d, ok)
        rec["donor_to_donor_in_hole"] = dict(pair=[int(d1), int(d2)], **cons)
    # ---------------------------------------------- repair with both registration modes
    patch_g, filled, valid = m.patch(target, donors, for_glare=False)
    imgs_h = {f: to_f(an.st.aligned(f, mode="h")) * an.gain[f] * cv2.resize(an.gmap[f], (L.PW, L.PH), interpolation=cv2.INTER_LINEAR) for f in donors}
    patch_h, _, _ = m.patch(target, donors, for_glare=False, images=imgs_h)
    rep_g, _ = F.laplacian_blend(ref_f, patch_g, filled, 5, valid.astype(np.float32))
    rep_h, _ = F.laplacian_blend(ref_f, patch_h, filled, 5, valid.astype(np.float32))
    rep_feather, _ = F.feather_blend(ref_f, patch_g, filled, 6.0, valid.astype(np.float32))
    # ---------------------------------------------- final: fingers + glare
    gt = m.glare_target()
    tall = target | gt
    dg, _ = m.greedy_donors(tall, 7, pool=[f for f in m.trusted], for_glare=True)
    rest = [d for d in donors if d not in dg]
    order = dg + rest
    remaining = tall.copy()
    for f in dg:
        remaining &= ~m.clean(f, True)
    patch1, filled1, valid1 = m.patch(tall & ~remaining, dg, for_glare=True)
    patch2, filled2, valid2 = m.patch(remaining & target, order, for_glare=False)
    patch_all = np.where(valid1[..., None], patch1, patch2)
    filled_all = filled1 | filled2
    final, _ = F.laplacian_blend(ref_f, patch_all, filled_all, 5, (valid1 | valid2).astype(np.float32))
    finals[(sname, p)] = u8(final)
    rec["final"] = dict(donors=[int(d) for d in order], glare_target=float(gt.mean()), unrepaired_covered=float((target & ~filled_all & inside_page).sum() / max(target.sum(), 1)), unrepaired_glare=float((gt & ~filled_all).sum() / max(gt.sum(), 1)))
    results[f"{sname}{p}"] = rec
    print(f"== {sname} p{p}: covered (confirmed) {rec['covered_fraction_of_page']*100:.1f}% of page, candidates {rec['candidates_fraction']*100:.1f}%")
    print("   upper bound of the repair by safety margin around donor fingers (full-res px):", {k: f"{v*100:.0f}%" for k, v in rec["bound_by_margin_px"].items()})
    for name in ("stable_only", "stable_and_early"):
        r = rec[name]
        print(f"   {name:17s}: repaired {r['repaired']*100:.1f}% (>=2 donors {r['two']*100:.1f}%) donors {r['donors']}")
    if "donor_to_donor_in_hole" in rec:
        c = rec["donor_to_donor_in_hole"]
        print(f"   donor-to-donor residual in and around the hole (+100 px) {c['pair']}: homography only median {c['h']['median']:.2f} p95 {c['h']['p95']:.2f} (n={c['h']['n']}); with grid median {c['grid']['median']:.2f} p95 {c['grid']['p95']:.2f} (n={c['grid']['n']})")
    print(f"   final: donors {rec['final']['donors']}, covered left {rec['final']['unrepaired_covered']*100:.1f}%, glare left {rec['final']['unrepaired_glare']*100:.1f}%")
    sys.stdout.flush()
    # ---------------------------------------------- pictures
    L.save_jpg(f"{L.OUT}/final_fused_page_fullres_{sname}_p{p}.jpg", finals[(sname, p)], q=93)
    if sname == "A":
        # detector steps at reduced resolution
        y = luma(an.low[ref])
        nonpaper = (y < 0.72 * an.white) | ~an.ins[ref]
        base = cv2.resize(u8(ref_f), (L.PW // 3, L.PH // 3), interpolation=cv2.INTER_AREA)
        rs = lambda mk: cv2.resize(mk.astype(np.float32), (L.PW // 3, L.PH // 3), interpolation=cv2.INTER_LINEAR)
        tiles = [
            L.label(base, f"reference {ref}", scale=0.6),
            L.label(overlay(base, rs(nonpaper), (0, 160, 255)), "1 non-paper (luma < 0.72 white)", scale=0.6),
            L.label(overlay(base, rs(an.cand[ref]), (255, 128, 0)), "2 opened + connected to border", scale=0.6),
            L.label(overlay(base, rs(m.cov[ref]), (0, 0, 255)), "3 confirmed by other frames, dilated", scale=0.6),
            L.label(cv2.resize(u8(rep_g), (L.PW // 3, L.PH // 3), interpolation=cv2.INTER_AREA), "repaired", scale=0.6),
        ]
        L.save_jpg(f"{L.OUT}/q6_finger_detector_steps_and_repair_{sname}_p{p}.jpg", L.hstack(tiles), q=90, max_w=1600)
        # full-resolution crop of the bottom of the page
        yy = 1120
        crops = [
            L.label(u8(ref_f)[yy:], f"reference {ref}", scale=0.8),
            L.label(u8(rep_h)[yy:], "repair, donors by homography only", scale=0.8),
            L.label(u8(rep_g)[yy:], "repair, donors by homography + grid (Laplacian blend)", scale=0.8),
            L.label(u8(rep_feather)[yy:], "same, feathered blend", scale=0.8),
        ]
        L.save_jpg(f"{L.OUT}/q6_finger_repair_bottom_crop_fullres_{sname}_p{p}.jpg", L.vstack(crops), q=92)
L.dump_json("q6_fingers.json", results)
# spread overviews: reference on top, fused below
for sname in sorted({s for s, _ in CASES}):
    if (sname, 0) in finals and (sname, 1) in finals:
        top = L.hstack([refs_u8[(sname, 0)], refs_u8[(sname, 1)]], gap=0)
        bot = L.hstack([finals[(sname, 0)], finals[(sname, 1)]], gap=0)
        L.save_jpg(f"{L.OUT}/final_spread_{sname}_reference_top_fused_bottom.jpg", L.vstack([L.label(top, "reference frames (rectified)", scale=1.2), L.label(bot, "fused: reference + patches (glare, fingers)", scale=1.2)]), q=90, max_w=1600)
