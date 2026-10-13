{
  lib,
  coreutils,
  makeWrapper,
  nix,
  nixos-rebuild-ng,
  rustPlatform,
  systemd,
}:
let
  inherit (lib) makeBinPath;
in
rustPlatform.buildRustPackage {
  pname = "br";
  version = "0.1.0";

  src = ../br;
  cargoLock.lockFile = ../br/Cargo.lock;

  nativeBuildInputs = [ makeWrapper ];

  preBuild = ''
    export BR_EXECUTABLE="$out/bin/br"
  '';

  postInstall = ''
    wrapProgram $out/bin/br \
      --set PATH /run/wrappers/bin:${
        makeBinPath [
          nix
          nixos-rebuild-ng
          coreutils
          systemd
        ]
      }
  '';
}
