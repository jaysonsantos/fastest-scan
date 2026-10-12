{
  description = "fastest-scan: turn a phone video of a book or a document into a PDF";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      forAllSystems = nixpkgs.lib.genAttrs [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
    in
    {
      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            packages = [
              # src/ and build.zig. The default `zig` of nixpkgs is one release older.
              pkgs.zig_0_17
              # the language server for Zig 0.17; `zls` of nixpkgs supports 0.16 only
              pkgs.zigscient
              # the CLI starts ffmpeg and ffprobe to decode the video
              pkgs.ffmpeg
              # scripts/bench.sh: page images from the PDF, OCR confidence, image statistics
              pkgs.poppler-utils
              pkgs.tesseract
              pkgs.imagemagick
              # the changelog and the version bump (scripts/release.sh)
              pkgs.git-cliff
              # linters, run together by `prek run --all-files` (.pre-commit-config.yaml)
              pkgs.prek
              pkgs.ziglint
              pkgs.taplo
              pkgs.shellcheck
              pkgs.shfmt
              pkgs.nixfmt
              pkgs.typos
              pkgs.actionlint
              pkgs.editorconfig-checker
              pkgs.gitleaks
            ];
          };
        }
      );
    };
}
