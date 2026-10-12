#!/usr/bin/env bash
# Nix supplies appOut, out, interp, rpathPrefix and the build tools.
set -euo pipefail

# Materialize valid links so patching cannot write into another store output.
# Preserve dangling links: historical packages can contain missing man pages.
mkdir -p "$out"
find -L "$appOut/." -print0 | while IFS= read -r -d "" source; do
    target="$out/${source#"$appOut/."}"
    if [ -d "$source" ]; then
        mkdir -p "$target"
    elif [ -L "$source" ] && [ ! -e "$source" ]; then
        cp -P --preserve=mode,timestamps "$source" "$target"
    else
        cp -L --preserve=mode,timestamps "$source" "$target"
    fi
done
chmod -R u+w "$out"

patched=0
rewritten=0
while IFS= read -r -d "" file; do
    if [ -n "$(patchelf --print-interpreter "$file" 2>/dev/null)" ]; then
        # External script interpreters retain their original loader/libc pair.
        original_rpath=$(patchelf --print-rpath "$file" 2>/dev/null || true)
        # RUNPATH avoids hijacking transitive host graphics-driver dependencies.
        patchelf --set-rpath "$rpathPrefix${original_rpath:+:$original_rpath}" \
            --set-interpreter "$interp" "$file"

        # Preload replacements for glibc's merged libraries and removed libcrypt.
        # Current libm must also win before an old indirect dependency claims it.
        needed=$(patchelf --print-needed "$file")
        for library in libm.so.6 libpthread.so.0 librt.so.1 libdl.so.2 libutil.so.1 libanl.so.1 libresolv.so.2 libcrypt.so.1; do
            case "$needed" in
                *"$library"*) ;;
                *) patchelf --add-needed "$library" "$file" ;;
            esac
        done
        patched=$((patched + 1))
    elif grep -aqI . "$file" 2>/dev/null && grep -aqF "$appOut/" "$file" 2>/dev/null; then
        # Redirect this output's embedded paths; other store roots remain old.
        sed -i "s|$appOut/|$out/|g" "$file"
        rewritten=$((rewritten + 1))
    fi
done < <(find "$out" -type f -print0 | sort -z)

echo "modernized: patched $patched ELFs, rewrote $rewritten scripts" >&2
