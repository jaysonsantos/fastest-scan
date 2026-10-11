# Research: image quality, JPEG, PDF, and benchmark metrics

Source: a research agent, 2026-10-09. `[V]` = read in a source. `[M]` = measurement
of the agent (synthetic text page, simulated H.264/H.265 clip, ideal alignment,
Tesseract 5.5). `[I]` = inference of the agent.

## Recommended recipe

1. **Select frames.** Score the page area of each frame at half scale with
   Tenengrad. Keep the 4 to 8 sharpest. The sharpest is the reference. Do not
   average all frames: a mean of 12 frames, some with motion blur, was 0.1 to
   0.8 dB worse than the sharpest frame. [M]
2. **Align.** Start from the quad homography. Refine per tile: 32 px tiles, 3-level
   pyramid, parabola sub-pixel fit (the HDR+ pattern) [I]. Target 0.25 px RMS [I].
   Paper is not flat; the SmartDoc evaluation tool needs local patch alignment for
   that reason [V].
3. **Warp one time.** Compose homography, tile offsets and output scale. Sample each
   source frame directly onto the output grid with Catmull-Rom bicubic, in gamma
   space. Lanczos-3 adds halo: Robidoux states that sharpness and halo increase
   together [V]. Set output size = longest quad edges x 1.25, maximum 300 dpi. Then
   the warp never minifies and needs no prefilter. [I]
4. **Merge.** Use a weighted mean per pixel: weight = (tile sharpness)^3 x glare
   mask. This is per-tile lucky imaging with soft seams [I]. PSNR against the
   sharpest frame changed by ±0.1 dB, and by +0.3 dB at most after sharpening [M].
   The benefit is lower noise and glare fusion.
5. **Correct illumination.** Downscale to 300 px long side [V: ScanTailor]. Use
   cells of one text line. Paper colour per cell = mean of the top 25 % luminance
   pixels [V: Zhang-He]. Reject cells 25 % darker than the 5x5-cell median and fill
   from neighbours [I]; Zhang-He and ScanTailor reject by plane or polynomial fit
   [V]. Smooth, upsample, then gain = target / background, clamp 0.8 to 2.5. Apply
   one luminance gain map to all channels, as ScanTailor does [V]. A smooth map
   gives no halo and keeps pictures. [I]
6. **White-balance.** Apply one global gain per channel from the median paper
   colour. Limit it to ±25 %. [I]
7. **Sharpen.** Apply an unsharp mask on luminance: sigma = 1.0 px x upscale
   factor, amount 1.0 to 1.2, threshold 2. The unsharp mask gave +0.7 to +1.7 dB
   against the clean page; the OCR effect was not consistent [M]. Add no spatial
   denoise.
8. **Set levels.** Linear only: P1 -> 16, 0.97 x paper level -> 255, clip. The clip
   removes the white-side halo of step 7 [I]. Use no S-curve and no threshold; they
   change the stroke width. [I]
9. **Set size.** Tesseract accuracy drops below 10 pt x 300 dpi (x-height 20 px),
   fails below x-height 10 px, and LSTM degrades above about 30 px [V]. 4K (2160 px
   on the short side) gives A4 at most 261 dpi and A5 at most 370 dpi [I]. At
   300 dpi, A4 is 2480x3508 and A5 is 1748x2480. Keep a 10 px white border. [V]
10. **Encode.** Use JPEG quality 85. Grey page: 1 component. Colour page: 4:4:4.
    Grey test on 8x8 block means: mean chroma < 3 and P99.5 < 12 [I]. Grey was 18 %
    smaller than RGB 4:4:4. 4:2:0 cost 4.6 dB on red text. Tesseract confidence was
    91.0 at q92 and q75, 90.3 at q30. [M]
11. **Encoder.** Write a baseline encoder in Zig with 2-pass optimised Huffman [I].
    `stb_image_write` forces 4:2:0 at quality ≤ 90, uses fixed Huffman tables, and
    always writes 3 components [V]. libjpeg-turbo: optimised Huffman +5.2 %
    compression ratio, progressive +11 %. mozjpeg adds 8 % at 4 to 6 x encode
    time. [V]

Alignment need [I]: frame pick none; mean 0.25 px; tile seams 0.5 px; drizzle or
super-resolution 0.1 px.

## Later, not in the first version

- Wronski super-resolution: it needs aliased raw CFA bursts and sub-pixel
  alignment; the gain is "small" from 1.5x to 2x [V]. The phone demosaics, scales
  and compresses video. [I]
- Drizzle on a 2x grid: step 3 already is shift-and-add. One warp against two
  differed by 0.06 dB at most. [M]
- HDR+ DFT Wiener merge: it targets raw sensor noise [I]. Codec loss was 0.1 to
  0.4 dB at phone bit rates. [M]
- Deconvolution: it needs a PSF and amplifies codec blocks. [I]
- Hard-shadow removal: Bako fails on pictures without a mask; the Dropbox
  per-channel solve shifted colours. [V]
- noteshrink: 8-colour k-means and indexed PNG remove anti-aliasing. [V]
- unpaper: its docs list no shading correction. [V]
- mozjpeg, JPEG 2000, JBIG2, MRC: these change the size only. [I]
- Genius Scan publishes filter names only [V]. The agent did not check Adobe Scan,
  Office Lens, or CamScanner.

## Benchmark metrics (mean of 10 or more pages)

- OCR guard: Tesseract TSV mean word confidence and the count of words with
  confidence ≥ 80. Confidence stayed at 88 to 91; single-page word accuracy jumped
  by up to 0.3. [M]
- Edge sharpness: median over text tiles of P99(gradient) / (P95 − P5). [I]
- Background flatness: standard deviation of 32x32 tile medians on paper pixels. [I]
- Glare: % of page area brighter than 1.18 x the smooth paper model. [I]
- Skew from projection-profile variance; page count against a manual count; bytes
  per page. [I]

## Minimal PDF

poppler and Ghostscript accepted this layout. [M]

```text
%PDF-1.4
%<4 bytes >= 0x80>
1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj
2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj
3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 595.20 841.92]
  /Resources << /XObject << /Im0 5 0 R >> >> /Contents [4 0 R] >> endobj
4 0 obj << /Length 37 >> stream
q 595.20 0 0 841.92 0 0 cm /Im0 Do Q
endstream endobj
5 0 obj << /Type /XObject /Subtype /Image /Width 2480 /Height 3508
  /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /DCTDecode /Length N >> stream
<N bytes: complete JPEG file>
endstream endobj
xref
0 6
0000000000 65535 f
<"%010d 00000 n \n" per object>
trailer << /Size 6 /Root 1 0 R >>
startxref
<offset of xref>
%%EOF
```

MediaBox = pixels x 72 / dpi. Use `/DeviceRGB` for 3 components.

For the later text layer: keep `/Contents` an array, store the pixel size and the
dpi per page, and let the writer allocate the object numbers. Then append a stream
`BT 3 Tr /F1 s Tf ... Tm [<hex>] TJ ET` and a `/Font` resource; `pdftotext` read
such a layer [M]. Unicode needs a Type0 glyphless font with ToUnicode, as Tesseract
writes. [V]

## Sources

- <https://arxiv.org/abs/1905.03277> (Wronski, handheld multi-frame super-resolution)
- <https://github.com/tesseract-ocr/tessdoc/blob/main/tess3/FAQ-Old.md> and
  <https://tesseract-ocr.github.io/tessdoc/ImproveQuality.html>
- <https://github.com/4lex4/scantailor-advanced/blob/master/src/core/EstimateBackground.cpp>
- <https://www.microsoft.com/en-us/research/wp-content/uploads/2016/11/Digital-Signal-Processing.pdf>
  (Zhang-He)
- <https://dropbox.tech/machine-learning/fast-document-rectification-and-enhancement>
- <https://web.ece.ucsb.edu/~psen/Papers/ACCV16_RemovingShadows.pdf> (Bako)
- <https://usage.imagemagick.org/filter/nicolas/> (Robidoux)
- <https://libjpeg-turbo.org/About/Mozjpeg>
- <https://github.com/nothings/stb/blob/master/stb_image_write.h>
- <https://github.com/tesseract-ocr/tesseract/blob/main/src/api/pdfrenderer.cpp>
