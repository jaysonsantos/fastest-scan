#!/usr/bin/env bash
# Runs the whole prototype end to end. Needs: uv, ffmpeg (only if frames/ is missing).
# At most 4 threads (cv2.setNumThreads(4) in fslib.py, BLAS limited below).
set -euo pipefail
cd "$(dirname "$0")"
export OMP_NUM_THREADS=4 OPENBLAS_NUM_THREADS=4 MKL_NUM_THREADS=4
PY="uv run --with numpy --with opencv-python-headless python"
mkdir -p logs out cache
[ -d frames ] || ./extract_frames.sh          # one decode pass, 352 frames, JPEG q:v 1
$PY check_index.py                            # frame indexes match the overlay pictures
$PY q7_sharpness.py                           # cache/sharpness.csv
$PY q1q2_registration.py A B C                # cache/reg_<S>.pkl, out/q1q2_stats_<S>.json
$PY q1q2_summary.py                           # Q1/Q2 tables
$PY q2_chain.py                               # chain start, 2..4 frame steps
$PY q2_chain_step1.py                         # chain start, every frame, coarse levels
$PY q3_exposure.py                            # Q3
$PY q4_glare.py                               # Q4
$PY q5_fusion.py                              # Q5
$PY q6_fingers.py                             # Q6 + final fused pages
$PY q7_pictures.py                            # Q7 crops
$PY q1_pictures.py                            # Q1 pictures
$PY q8_cost.py                                # Q8
$PY diag_edge_ghost.py                        # why patches ghost at a flexed page corner
