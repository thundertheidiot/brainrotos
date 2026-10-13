{
  lib,
  coreutils,
  makeWrapper,
  nix,
  nixos-rebuild-ng,
  rustPlatform,
  systemd,
}:
rustPlatform.buildRustPackage {
  pname = "br";
  version = "0.1.0";

  src = ../br;
  cargoLock.lockFile = ../br/Cargo.lock;

  nativeBuildInputs = [ makeWrapper ];

  postInstall = ''
    wrapProgram $out/bin/br \
      --set PATH ${
        lib.makeBinPath [
          nix
          nixos-rebuild-ng
          coreutils
          systemd
        ]
      }
  '';
}
