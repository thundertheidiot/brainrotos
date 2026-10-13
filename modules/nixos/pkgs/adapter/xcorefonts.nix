# Old Xlib/Motif applications need bitmap fonts in the X server's font path.
{
  lib,
  runCommand,
  mkfontscale,
  gzip,
  font-misc-misc,
  font-cursor-misc,
  font-alias,
  font-adobe-75dpi,
  font-adobe-100dpi,
}:
let
  fonts = [
    font-misc-misc
    font-cursor-misc
    font-alias
    font-adobe-75dpi
    font-adobe-100dpi
  ];
in
runCommand "retro-xcorefonts"
  {
    nativeBuildInputs = [
      mkfontscale
      gzip
    ];
  }
  ''
    mkdir -p "$out/misc"
    # Decompress PCFs: some Xwayland font paths silently ignore compressed fonts.
    for package in ${lib.escapeShellArgs fonts}; do
      find "$package/share/fonts" -mindepth 2 -type f \
        -regex '.*\.\(pcf\|pcf\.gz\|bdf\|bdf\.gz\)' -print0 |
        while IFS= read -r -d "" file; do
          filename=$(basename "$file")
          case "$file" in
            *.gz) gzip -dc "$file" > "$out/misc/''${filename%.gz}" ;;
            *) ln -s "$file" "$out/misc/$filename" ;;
          esac
        done
    done
    # Preserve alias order; the X server uses the first matching definition.
    find ${font-misc-misc} ${font-cursor-misc} ${font-alias} \
      -name fonts.alias -exec cat {} + > "$out/misc/fonts.alias"
    mkfontscale "$out/misc"
    mkfontdir "$out/misc"
  ''
