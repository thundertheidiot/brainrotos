{
  lib,
  makeWrapper,
  nix,
  nixos-rebuild-ng,
  nvd,
  rustPlatform,
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
          nvd
        ]
      }
  '';
}
