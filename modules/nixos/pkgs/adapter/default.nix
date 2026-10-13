# best-effort adaptation of historical nixpkgs-multiverse apps
# for a current Linux desktop. Upstream package outputs stay untouched.
#
# Patch executables in the app output to use current glibc and, unless gl is
# "off", graphics dispatch libraries with host drivers. External helpers,
# interpreters and plugins are not comprehensively modernized.
{
  lib,
  callPackage,
  stdenv,
  writeShellScriptBin,
  writeShellScript,
  python3,
  libx11,
  libglvnd,
  libdrm,
  libxcb,
  vulkan-loader,
  libxcrypt-legacy,
  coreutils,
  gnugrep,
  binutils-unwrapped,
  xset,
  # Helpers are overridable through callPackage, including in runtime tests.
  glProbe ? callPackage ./glprobe.nix { },
  xfontsDir ? callPackage ./xcorefonts.nix { },
  package,
  command ? package.meta.mainProgram or null,
  binaryName ? "${package.pname or (lib.getName package)}@${lib.getVersion package}",
  desktop ? true,
  gl ? "auto",
  waylandMode ? "auto",
  software ? false,
  display ? null,
  isolateHome ? false,
  extraArgs ? [ ],
}:

assert lib.elem gl [
  "auto"
  "on"
  "off"
];
assert lib.elem waylandMode [
  "auto"
  "on"
  "off"
];

let
  # Old derivations may have only name; fast multiverse packages provide
  # pname/version without needing to evaluate their .eval derivation.
  pname = package.pname or (lib.getName package);
  version = lib.getVersion package;
  appOut = if package ? out then package.out else package;

  appTree = callPackage ./modernize.nix {
    inherit appOut;
    graphics = gl != "off";
    name = "retro-${pname}-${version}-modernized";
  };

  name = binaryName;

  glMode =
    if gl == "on" then
      "1"
    else if gl == "off" then
      "0"
    else
      "auto";

  # Apply a consistent X11/dispatch stack to modernized processes.
  # Do not inject Mesa's vendor libraries: they must pair with host drivers.
  # Keep glibc out of LD_LIBRARY_PATH: old wrapper interpreters need their own
  # loader/libc pair. Patched ELF RUNPATHs and DT_NEEDED select current glibc.
  # Other untouched executables outside appOut can still be incompatible.
  modernGlLibPath = lib.makeLibraryPath (
    [ libxcrypt-legacy ]
    ++ lib.optionals (gl != "off") [
      libx11
      libglvnd
      libdrm
      libxcb
      vulkan-loader
    ]
  );
  # Both the main launcher and desktop helper templates get the same tools.
  runtimeInputs = [
    coreutils
    gnugrep
    binutils-unwrapped
    xset
    glProbe
  ];
  runtimePath = lib.makeBinPath runtimeInputs;

  script = selectedCommand: ''
    set -euo pipefail
    # Pin utility lookup without hiding application-specific inherited commands.
    export PATH="${runtimePath}''${PATH:+:$PATH}"

    binDir="${appTree}/bin"

    fail() { echo "${name}: $*" >&2; exit 1; }

    [ -d "$binDir" ] || fail "no bin/ in ${appTree}"
    echo "retro: modernized tree ${appTree} (patchelf interp+rpath)" >&2

    exe=""
    ${lib.optionalString (
      selectedCommand != null
    ) "exe=\"$binDir\"/${lib.escapeShellArg selectedCommand}"}
    if [ -z "''${exe:-}" ]; then
      for f in "$binDir"/*; do
        [ -f "$f" ] && [ -x "$f" ] || continue
        [ "$(basename "$f")" = ${lib.escapeShellArg pname} ] && { exe="$f"; break; }
      done
    fi
    if [ -z "''${exe:-}" ]; then
      for f in "$binDir"/*; do
        [ -f "$f" ] && [ -x "$f" ] || continue
        case "$(basename "$f")" in ${lib.escapeShellArg pname}*) exe="$f"; break ;; esac
      done
    fi
    if [ -z "''${exe:-}" ]; then
      for f in "$binDir"/* "$binDir"/.[!.]*; do
        [ -f "$f" ] && [ -x "$f" ] || continue
        exe="$f"; break
      done
    fi
    [ -n "$exe" ] && [ -f "$exe" ] && [ -x "$exe" ] || fail "no executable found in $binDir"
    echo "retro: ${pname} ${version} -> $exe" >&2

    # Inspect the selected executable and direct wrapper targets only. This is
    # a hint, not a complete dependency walk (plugins may load graphics later).
    scan_files=("$exe")
    if [ "$(head -c2 "$exe" 2>/dev/null)" = "#!" ]; then
      while IFS= read -r target; do
        [ -f "$target" ] && scan_files+=("$target")
      done < <(grep -aoE '/nix/store/[A-Za-z0-9.+_-]+/bin/[A-Za-z0-9._+-]+' "$exe" | sort -u)
    fi

    glWanted="${glMode}"
    vulkanWanted=0
    if [ "$glWanted" = "auto" ]; then
      glWanted=0
      for f in "''${scan_files[@]}"; do
        if grep -aqE 'libGL\.so|libEGL\.so|libOpenGL\.so|libglapi\.so|libgbm\.so' "$f"; then
          glWanted=1
          break
        fi
      done
      if [ "$glWanted" = 1 ]; then
        echo "retro: OpenGL detected -> host graphics" >&2
      fi
    fi

    if [ "${glMode}" != 0 ]; then
      for f in "''${scan_files[@]}"; do
        if grep -aq 'libvulkan\.so' "$f"; then
          vulkanWanted=1
          break
        fi
      done
    fi

    # Preserve backend choice for the application instead of forcing toolkits.
    ${lib.optionalString (software && gl != "off") ''
      export LIBGL_ALWAYS_SOFTWARE=1
      echo "retro: software OpenGL requested" >&2
    ''}

    if [ "${toString isolateHome}" = 1 ]; then
      # Resolve the user's state root before replacing HOME and XDG_STATE_HOME.
      # Reuse this versioned home across launches; cleanup must never delete it.
      isolated_home="''${XDG_STATE_HOME:-$HOME/.local/state}/${name}"
      case "$isolated_home" in
        /*) ;;
        *) fail "isolated home requires an absolute HOME or XDG_STATE_HOME" ;;
      esac
      (umask 077; mkdir -p "$isolated_home")
      export HOME="$isolated_home"
      export XDG_CONFIG_HOME="$HOME/.config"
      export XDG_DATA_HOME="$HOME/.local/share"
      export XDG_CACHE_HOME="$HOME/.cache"
      export XDG_STATE_HOME="$HOME/.local/state"
    fi

    display_ready() {
      # Keep application library overrides out of the display probe.
      DISPLAY="$1" env -u LD_LIBRARY_PATH \
        timeout -k 2 5 glx-probe x11 >/dev/null 2>&1
    }

    # Use the desktop session's Xwayland/X11 server; never start our own.
    if [ "${waylandMode}" = off ]; then unset WAYLAND_DISPLAY; fi
    native_wayland=0
    if [ -n "''${WAYLAND_DISPLAY:-}" ]; then
      native_wayland=1
    fi

    x11_ready=0
    if [ -n ${lib.escapeShellArg (if display == null then "" else display)} ]; then
      export DISPLAY=${lib.escapeShellArg (if display == null then "" else display)}
      display_ready "$DISPLAY" || fail "cannot connect to forced DISPLAY $DISPLAY"
      x11_ready=1
      echo "retro: using forced DISPLAY $DISPLAY" >&2
    elif [ -n "''${DISPLAY:-}" ] && display_ready "$DISPLAY"; then
      x11_ready=1
      echo "retro: using inherited DISPLAY $DISPLAY" >&2
    fi

    # Old Xlib/Motif apps need bitmap fonts, often absent on Xwayland.
    # Font grafting is bounded and nonfatal for apps that do not need it.
    if [ "$x11_ready" = 1 ]; then
      if timeout -k 2 5 xset -display "$DISPLAY" +fp "${xfontsDir}/misc" 2>/dev/null &&
        timeout -k 2 5 xset -display "$DISPLAY" fp rehash 2>/dev/null; then
        echo "retro: X core fonts grafted onto $DISPLAY" >&2
      else
        echo "retro: xset fontpath graft failed (continuing without)" >&2
      fi
    fi

    # Prefer a sufficiently recent app C++ runtime where possible. This
    # threshold is a compatibility heuristic, not a full symbol-set check.
    stdcxx_dir="${lib.makeLibraryPath [ stdenv.cc.cc.lib ]}"
    for d in $(grep -aohE '/nix/store/[A-Za-z0-9.+_-]+-gcc-[0-9][0-9.]*-lib/lib' "''${scan_files[@]}" 2>/dev/null | sort -u || true); do
      if [ -e "$d/libstdc++.so.6" ] && readelf -V "$d/libstdc++.so.6" 2>/dev/null | grep -a 'GLIBCXX_3\.4\.29' >/dev/null; then
        stdcxx_dir="$d"
        break
      fi
    done
    echo "retro: libstdc++ from $stdcxx_dir" >&2
    export LD_LIBRARY_PATH="$stdcxx_dir:${modernGlLibPath}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

    if [ "$glWanted" = 1 ] || [ "$vulkanWanted" = 1 ]; then
      # Leave host EGL/Vulkan vendor discovery and user overrides
      # intact. The current-library probe is only a preliminary OpenGL check,
      # not proof of a usable app context or hardware acceleration.
      # A GLX failure cannot predict the backend an app chooses with Wayland.
      if [ "$glWanted" = 1 ] && [ "$native_wayland" = 0 ] && [ "$x11_ready" = 1 ] && [ "${toString (!software)}" = 1 ]; then
        probe_mode="glx"
        if timeout -k 2 5 glx-probe "$probe_mode" >/dev/null 2>&1; then
          echo "retro: preliminary $probe_mode check passed (app requirements may differ)" >&2
        else
          export LIBGL_ALWAYS_SOFTWARE=1
          echo "retro: preliminary $probe_mode check failed; requesting software OpenGL" >&2
        fi
      fi
    fi

    set +e
    # Only the application gets its own bin/ first, after adapter setup.
    PATH="$binDir:$PATH" "$exe" ${lib.escapeShellArgs extraArgs} "$@"
    rc=$?
    set -e
    exit "$rc"
  '';
in
(writeShellScriptBin name (script command)).overrideAttrs (old: {
  # Keep upstream resources private; desktop launchers must use the adapter,
  # including actions that invoke a different executable from the same package.
  buildCommand =
    old.buildCommand
    + lib.optionalString desktop ''
      ${python3}/bin/python ${./desktop-entries.py} \
        ${appOut} ${appTree} "$out" \
        ${writeShellScript "retro-desktop-template" (script "__RETRO_DESKTOP_COMMAND__")} \
        ${
          lib.escapeShellArgs [
            name
            pname
            version
          ]
        } ${lib.escapeShellArg (if command == null then "" else command)}
    '';
  passthru = {
    inherit
      package
      pname
      version
      appOut
      appTree
      ;
  };
  meta.mainProgram = name;
})
