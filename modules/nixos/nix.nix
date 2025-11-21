{
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkDefault;
in {
  config = {
    nix.package = pkgs.nixVersions.latest;

    nix.settings = {
      experimental-features = ["nix-command" "flakes"];
      use-xdg-base-directories = true;
      allow-import-from-derivation = true;
    };

    nix.nixPath = mkDefault [
      "brainrotos=/nix/osconfig"
    ];

    nixpkgs.config.allowUnfree = true;
  };
}
