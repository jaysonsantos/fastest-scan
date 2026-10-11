# 0006: The library has its own JPEG encoder and PDF writer

Date: 2026-10-09. Status: accepted.

## Context

The pages go into the PDF as JPEG images (`/DCTDecode`). The choices for the
encoder were `stb_image_write` (one C file, no control of chroma subsampling, fixed
Huffman tables), libjpeg-turbo (a C library with assembly), or a baseline encoder
in Zig.

## Decision

- `src/lib/jpeg.zig` is a baseline encoder: 8-bit, grey or YCbCr, 4:4:4 or 4:2:0,
  the quality scale of libjpeg, and Huffman tables built from the image.
- `src/lib/pdf.zig` writes PDF 1.7 with one image per page. It sends the bytes to a
  callback.

## Consequences

- The library has no C code. The Android build needs no extra toolchain work.
- The encoder controls the subsampling. Coloured text keeps full chroma.
- The encoder has no progressive mode and no trellis quantization. The files are
  larger than mozjpeg files at the same quality. The size is acceptable for the
  first version; measure it in the benchmark before any change.
