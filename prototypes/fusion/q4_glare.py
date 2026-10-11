"""Q4: glare confidence against a low percentile of the aligned stack.

Variant (a) = research note step 5: Gaussian(sigma 3) of min(R,G,B) at quarter resolution,
              conf = clamp((L - B - t0) / t1).
Variant (b) = "stroke" variant: sigma 0.7, then 5x5 grey dilation, then Gaussian sigma 1.5.

Ground truth proxy at FULL resolution: "lifted ink" pixels = pixels that are ink in the clean
baseline (20th percentile of the full-resolution luma stack < 0.45 * white) and are brighter than
that baseline by > 0.20 * white in the frame. Recall = share of lifted-ink pixels inside the mask
(conf > 0.3). Area = share of the page inside the mask.
"""
import sys

import cv2
import numpy as np

import fslib as L
import fusion as F
from analysis import K, Analysis, luma, overlay, sharp_frames, up
from config import SPREADS

A_T0 = [0.02, 0.03, 0.04, 0.06]
B_T0 = [0.04, 0.06, 0.08, 0.10]
B_T0_USE = 0.06
out = {}
only = sys.argv[1:] or list(SPREADS)


def pick_uniform(frames, ref, n):
    others = [f for f in frames if f != ref]
    idx = np.unique(np.round(np.linspace(0, len(others) - 1, n - 1)).astype(int))
    return [ref] + [others[i] for i in idx]


def pick_greedy(an, conf, cov, ref, n, target, pool):
    """Greedy cover of the reference glare mask `target` by clean, uncovered donor pixels."""
    need1 = target.copy()
    chosen = [ref]
    cnt = np.zeros(target.shape, np.int32)
    for _ in range(n - 1):
        best, bg = None, -1
        for f in pool:
            if f in chosen:
                continue
            clean = (conf[f] < 0.3) & ~cov[f]
            gain = int((clean & target & (cnt < 2)).sum())
            if gain > bg:
                best, bg = f, gain
        if best is None:
            break
        chosen.append(best)
        cnt += ((conf[best] < 0.3) & ~cov[best]).astype(np.int32)
    return chosen


for sname in only:
    cfg = SPREADS[sname]
    for p in (0, 1):
        mdl = F.Model(sname, p)
        an = mdl.an
        ref = an.ref
        W = an.white
        # baseline: second-lowest sample that is not excluded (fingers, shadow, untrusted frame)
        excl = mdl.excl_b
        base_a, med_a, nv = an.baseline(3.0, exclude=excl)
        base_b, _, _ = an.baseline(0.7, exclude=excl)
        base_b_pct, _, _ = an.baseline(0.7, pct=0.2, exclude=excl)
        stable = [f for f in an.frames if f in cfg["stable"] or f == ref]
        trusted = mdl.trusted
        # ---------------- full-resolution truth proxy
        covf = {f: up(an.cov[f].astype(np.float32)) > 0.5 for f in stable}
        ystack = np.stack([luma(an.full_f(f)) for f in stable])
        # second-lowest full-resolution luma over ALL frames of the analysis (early ones too)
        lo1 = np.full((L.PH, L.PW), np.inf, np.float32)
        lo2 = np.full((L.PH, L.PW), np.inf, np.float32)
        for f in an.frames:
            yv = np.where(up(excl[f].astype(np.float32)) > 0.5, np.inf, luma(an.full_f(f)))
            lo2 = np.minimum(lo2, np.maximum(lo1, yv))
            lo1 = np.minimum(lo1, yv)
        bfull = np.where(np.isfinite(lo2), lo2, np.nan)
        del lo1, lo2
        ink = cv2.erode((np.nan_to_num(bfull, nan=1.0) < 0.42 * W).astype(np.uint8), np.ones((3, 3), np.uint8)) > 0
        paper = np.nan_to_num(bfull, nan=0.0) > 0.88 * W
        mid = (np.nan_to_num(bfull, nan=0.0) > 0.45 * W) & (np.nan_to_num(bfull, nan=0.0) < 0.80 * W)
        rec = dict(frames=len(an.frames), stable=len(stable), trusted=len(trusted), white=W)
        # ---------------- noise of (L - B) for variant (a)
        dall = np.concatenate([(an.minch(f, 3.0) - base_a)[~an.cov[f]].ravel() for f in stable])
        dall = dall[np.isfinite(dall)]
        rec["a_diff_percentiles"] = {q: float(np.percentile(dall, q)) for q in (50, 75, 90, 95, 99)}
        clip = np.mean([(an.low[f].max(axis=2) >= 0.98).mean() for f in stable])
        rec["clipped_fraction"] = float(clip)
        # ---------------- thresholds: area and recall
        k7 = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (7, 7))

        def evaluate(conf_fn):
            area, area7, hit, hit7, tot = [], [], 0, 0, 0
            for i, f in enumerate(stable):
                c = conf_fn(f)
                m = (c > 0.3) & ~an.cov[f]
                area.append(float(m.sum() / max((~an.cov[f]).sum(), 1)))
                lifted = ink & ~covf[f] & ((ystack[i] - bfull) > 0.20 * W)
                mf = up(cv2.dilate(m.astype(np.uint8), np.ones((3, 3), np.uint8)).astype(np.float32)) > 0.5
                m7 = cv2.dilate(m.astype(np.uint8), k7) > 0  # the mask that the fusion replaces
                area7.append(float((m7 & ~an.cov[f]).sum() / max((~an.cov[f]).sum(), 1)))
                hit += int((lifted & mf).sum())
                hit7 += int((lifted & (up(m7.astype(np.float32)) > 0.5)).sum())
                tot += int(lifted.sum())
            return dict(area_median=float(np.median(area)), area_max=float(np.max(area)), recall=hit / max(tot, 1), recall_grow3=hit7 / max(tot, 1), area_grow3_median=float(np.median(area7)), lifted_px_per_frame=tot / len(stable))

        rec["variant_a"] = {f"t0={t}": evaluate(lambda f, t=t: an.glare_blur(base_a, f, 3.0, t, 0.04)) for t in A_T0}
        rec["variant_b"] = {f"t0={t}": evaluate(lambda f, t=t: an.glare_stroke(base_b, f, 0.7, t, 0.06)) for t in B_T0}
        # ---------------- ink versus paper inside the glare zone (variant b, t0 = 0.10)
        conf = {f: an.glare_stroke(base_b, f, 0.7, B_T0_USE, 0.06) for f in an.frames}
        conf_a = {f: an.glare_blur(base_a, f) for f in an.frames}
        conf_pct = an.glare_stroke(base_b_pct, ref, 0.7, B_T0_USE, 0.06)
        rec["ref_area_b_second_lowest"] = float(((conf[ref] > 0.3) & ~an.cov[ref]).mean())
        rec["ref_area_b_pct20"] = float(((conf_pct > 0.3) & ~an.cov[ref]).mean())
        rec["ref_area_a_second_lowest"] = float(((conf_a[ref] > 0.3) & ~an.cov[ref]).mean())
        lifts = dict(ink=[], paper=[], mid=[], ink_abs=[], paper_abs=[], ink_base=[], paper_base=[])
        chroma = []
        for i, f in enumerate(stable):
            zone = up(cv2.dilate((conf[f] > 0.3).astype(np.uint8), np.ones((9, 9), np.uint8)).astype(np.float32)) > 0.5
            zone &= ~covf[f]
            if zone.sum() < 2000:
                continue
            d = ystack[i] - bfull
            for name, m in (("ink", ink), ("paper", paper), ("mid", mid)):
                mm = zone & m
                if mm.sum() > 200:
                    lifts[name].append(float(np.nanmean(d[mm])))
            if (zone & ink).sum() > 200 and (zone & paper).sum() > 200:
                lifts["ink_abs"].append(float(ystack[i][zone & ink].mean()))
                lifts["paper_abs"].append(float(ystack[i][zone & paper].mean()))
                lifts["ink_base"].append(float(np.nanmean(bfull[zone & ink])))
                lifts["paper_base"].append(float(np.nanmean(bfull[zone & paper])))
                # strongly lifted ink: top 10 % of ink lift in the zone
                dz = d[zone & ink]
                thr = np.percentile(dz, 90)
                sel = zone & ink & (d >= thr)
                bgr = an.full_f(f)[sel].mean(0)
                chroma.append([float(v) for v in bgr] + [float(ystack[i][sel].mean())])
        rec["lift"] = {k: (float(np.mean(v)) if v else None) for k, v in lifts.items()}
        rec["strong_glare_on_ink_bgr_luma"] = [float(v) for v in np.mean(chroma, 0)] if chroma else None
        rec["paper_bgr"] = [float(v) for v in an.full_f(ref)[paper & ~covf.get(ref, np.zeros_like(paper))].mean(0)] if ref in covf else None
        # ---------------- donors: coverage of the reference glare mask
        ker = np.ones((7, 7), np.uint8)
        target = (cv2.dilate((conf[ref] > 0.3).astype(np.uint8), ker) > 0) & ~an.cov[ref]
        rec["ref_glare_fraction"] = float(target.sum() / max((~an.cov[ref]).sum(), 1))
        cov_res = {}
        for N in (5, 8, 12):
            for strat in ("uniform_stable", "greedy_all"):
                if strat == "uniform_stable":
                    ch = pick_uniform(stable, ref, N)
                else:
                    ch = pick_greedy(an, conf, mdl.unusable, ref, N, target, trusted)
                cnt = np.zeros(target.shape, np.int32)
                for f in ch[1:]:
                    cnt += ((cv2.dilate((conf[f] > 0.3).astype(np.uint8), np.ones((3, 3), np.uint8)) == 0) & ~mdl.unusable[f]).astype(np.int32)
                cov_res[f"N={N} {strat}"] = dict(
                    frames=[int(x) for x in ch],
                    one=float(((cnt >= 1) & target).sum() / max(target.sum(), 1)),
                    two=float(((cnt >= 2) & target).sum() / max(target.sum(), 1)),
                )
        rec["donor_coverage"] = cov_res
        out[f"{sname}{p}"] = rec
        print(f"== {sname} p{p}: frames {len(an.frames)} (stable {len(stable)}, trusted {len(trusted)}), white {W:.3f}, clipped {clip:.5f}")
        print("   (L-B) percentiles, variant a:", {k: round(v, 4) for k, v in rec["a_diff_percentiles"].items()})
        for v in ("variant_a", "variant_b"):
            print("   " + v + ": " + "; ".join(f"{k}: area {r['area_median']*100:.1f}% (max {r['area_max']*100:.1f}%), recall {r['recall']*100:.0f}% | replaced mask (grown 12 px): area {r['area_grow3_median']*100:.1f}%, recall {r['recall_grow3']*100:.0f}%" for k, r in rec[v].items()))
        print("   lift in glare zone (luma 0..1):", {k: (None if v is None else round(v, 3)) for k, v in rec["lift"].items()})
        print("   strong glare on ink, mean B,G,R,Y:", rec["strong_glare_on_ink_bgr_luma"], " paper B,G,R:", rec["paper_bgr"])
        print(f"   reference glare mask: {rec['ref_glare_fraction']*100:.1f}% of the page; ref area b/2nd-lowest {rec['ref_area_b_second_lowest']*100:.2f}%, b/pct20 {rec['ref_area_b_pct20']*100:.2f}%, a/2nd-lowest {rec['ref_area_a_second_lowest']*100:.2f}%")
        for k, r in cov_res.items():
            print(f"   {k}: >=1 clean donor {r['one']*100:.1f}%, >=2 {r['two']*100:.1f}%  frames {r['frames']}")
        sys.stdout.flush()
        # ---------------- pictures
        show = [ref] + [f for f in pick_uniform(stable, ref, 4)[1:]]
        tiles = []
        for f in show:
            img = an.full[f]
            o = overlay(img, up(conf[f]), (0, 0, 255), 0.5)
            o = overlay(o, up(an.cov[f].astype(np.float32)), (255, 128, 0), 0.5)
            o = cv2.resize(o, (L.PW // 3, L.PH // 3), interpolation=cv2.INTER_AREA)
            tiles.append(L.label(o, f"{f}{' (ref)' if f == ref else ''}", scale=0.7))
        L.save_jpg(f"{L.OUT}/q4_glare_mask_red_covered_blue_{sname}_p{p}.jpg", L.hstack(tiles), q=88, max_w=1600)
        if p == 1:
            # full-resolution crop: frame | variant a mask | variant b mask | clean baseline donor
            y0, x0, hh, ww = (80, 60, 330, 1100) if sname != "C" else (60, 60, 330, 1100)
            crop = lambda im: im[y0 : y0 + hh, x0 : x0 + ww]
            imgs = [
                L.label(crop(an.full[ref]), f"frame {ref}", scale=0.7),
                L.label(crop(overlay(an.full[ref], up((conf_a[ref] > 0.3).astype(np.float32)))), "variant a: blur sigma 3, t0 0.04 (research note)", scale=0.7),
                L.label(crop(overlay(an.full[ref], up((conf[ref] > 0.3).astype(np.float32)))), "variant b: stroke, t0 0.06, baseline = second-lowest", scale=0.7),
                L.label(crop(overlay(an.full[ref], up((conf_pct > 0.3).astype(np.float32)))), "variant b, baseline = 20th percentile (misses static glare)", scale=0.7),
                L.label(crop(np.clip(np.dstack([np.nan_to_num(bfull)] * 3) * 255, 0, 255).astype(np.uint8)), "second-lowest of the full-res luma stack", scale=0.7),
            ]
            L.save_jpg(f"{L.OUT}/q4_glare_threshold_crop_fullres_{sname}_p{p}.jpg", L.vstack(imgs), q=92)
        del ystack
L.dump_json("q4_glare.json" if len(only) == 3 else f"q4_glare_{''.join(only)}.json", out)
