# Materialize and adapt this output, not the entire historical dependency closure.
{
  lib,
  runCommand,
  patchelf,
  stdenv,
  glibc,
  libxcrypt-legacy,
  libx11,
  libglvnd,
  vulkan-loader,
  appOut,
  name,
  graphics ? true,
}:
let
  inherit (lib) makeLibraryPath optionals;
in
runCommand name
  {
    nativeBuildInputs = [ patchelf ];
    inherit appOut;
    interp = stdenv.cc.bintools.dynamicLinker;
    # Retain each executable's original RUNPATH after current libc/dispatch libs.
    rpathPrefix = makeLibraryPath (
      [
        glibc
        libxcrypt-legacy
      ]
      ++ optionals graphics [
        libx11
        libglvnd
        vulkan-loader
      ]
    );
  }
  ''
    bash ${./modernize.sh}
  ''
