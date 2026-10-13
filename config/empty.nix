{ lib, pkgs, ... }:
let
  inherit (lib) mkDefault mkForce;
in
{
  config = {
    brainrotos = {
      impermanence.v1.enable = mkDefault true;
      efi.v1.enable = mkDefault true;
      ramcache.v1.enable = mkDefault true;
      flatpak.v1.enable = mkForce false;

      packages.v1.filePath = pkgs.writeText "fake.json" "[]";
    };
  };
}
