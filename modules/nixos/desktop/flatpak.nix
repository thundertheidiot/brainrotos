{
  lib,
  config,
  pkgs,
  ...
}: let
  inherit (lib) mkIf mkMerge;
  inherit (lib.options) mkOption;
  inherit (lib.types) bool;

  cfg = config.brainrotos.flatpak.v1;
in {
  options = {
    brainrotos.flatpak.v1 = {
      enable = mkOption {
        type = bool;
        default = false;
        description = "Enable flatpaks.";
      };
    };
  };

  config = mkMerge [
    (mkIf cfg.enable {
      services.flatpak.enable = true;

      brainrotos.impermanence.v1.directories = [
        {
          path = "/var/lib/flatpak";
          permissions = "755";
        }
      ];

      # clean flatpak cache every 10 days
      systemd.tmpfiles.rules = [
        "R! /var/tmp/flatpak-cache-* - - - 10d"
      ];
    })
    # flathub as a static system remote, picked up by flatpak from remotes.d
    (mkIf cfg.enable {
      environment.etc."flatpak/remotes.d/flathub.flatpakrepo".source = ./flathub.flatpakrepo;
    })
    (mkIf (cfg.enable && config.brainrotos.desktop.plasma.v1.enable) {
      environment.systemPackages = [
        pkgs.kdePackages.flatpak-kcm
      ];
    })
  ];
}
