"""Q3: exposure and white-balance drift between the frames of a spread.

Per frame and channel: g_c = exp(median(log(ref_c / frame_c))) on 8x box-reduced aligned pages,
on pixels where both lumas are in [0.3, 0.94] (paper, no clipped glare, no dark print).
Then the remaining local gain error is measured on ~100 px tiles after the global gain.
"""
import numpy as np

import fslib as L
from config import SPREADS
from stack import PageStack, box_down, to_f

res = {}
for sname in SPREADS:
    for p in (0, 1):
        st = PageStack(sname, p)
        ref = box_down(to_f(st.aligned(st.ref)), 8)
        ref_y = ref @ np.array([0.114, 0.587, 0.299], np.float32)
        recs = []
        for kind in ("stable", "early"):
            for n in st.good(kind):
                if n == st.ref:
                    continue
                a = box_down(to_f(st.aligned(n)), 8)
                ins = box_down(st.inside(n).astype(np.float32), 8) > 0.99
                ay = a @ np.array([0.114, 0.587, 0.299], np.float32)
                v = ins & (ref_y > 0.3) & (ref_y < 0.94) & (ay > 0.3) & (ay < 0.94) & (np.abs(ref_y / np.maximum(ay, 1e-3) - 1) < 0.3)
                if v.sum() < 500:
                    continue
                g = np.array([np.exp(np.median(np.log(ref[..., c][v] / a[..., c][v]))) for c in range(3)])
                gl = float(np.exp(np.median(np.log(ref_y[v] / ay[v]))))
                # tile residual after the per-channel global gain (luma)
                ratio = np.where(v, ref_y / np.maximum(ay * gl, 1e-3), np.nan)
                T = 12  # 12 low-res px = 96 full-res px
                tiles = []
                for y in range(0, ratio.shape[0] - T + 1, T):
                    for x in range(0, ratio.shape[1] - T + 1, T):
                        t = ratio[y : y + T, x : x + T]
                        if np.isfinite(t).sum() > 0.6 * T * T:
                            tiles.append(np.nanmedian(t))
                tiles = np.array(tiles)
                recs.append(
                    dict(
                        frame=n,
                        kind=kind,
                        gain_b=float(g[0]),
                        gain_g=float(g[1]),
                        gain_r=float(g[2]),
                        gain_luma=gl,
                        wb_r_over_g=float(g[2] / g[1]),
                        wb_b_over_g=float(g[0] / g[1]),
                        tile_p05=float(np.percentile(tiles, 5)),
                        tile_p95=float(np.percentile(tiles, 95)),
                        tile_absdev_p95=float(np.percentile(np.abs(tiles - 1), 95)),
                        tile_absdev_med=float(np.median(np.abs(tiles - 1))),
                    )
                )
        res[f"{sname}{p}"] = recs
        for kind in ("stable", "early"):
            rr = [r for r in recs if r["kind"] == kind]
            if not rr:
                continue
            f = lambda k: np.array([r[k] for r in rr])
            print(
                f"{sname} p{p} {kind:6s} n={len(rr):2d} luma gain {f('gain_luma').min():.3f}..{f('gain_luma').max():.3f}  "
                f"R/G {f('wb_r_over_g').min():.3f}..{f('wb_r_over_g').max():.3f}  B/G {f('wb_b_over_g').min():.3f}..{f('wb_b_over_g').max():.3f}  "
                f"local tile |gain-1| after global gain: median {np.median(f('tile_absdev_med')):.4f}, p95 {np.median(f('tile_absdev_p95')):.4f} (worst frame {f('tile_absdev_p95').max():.4f})",
                flush=True,
            )
L.dump_json("q3_exposure.json", res)
