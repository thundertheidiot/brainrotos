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

      # why isn't this the default?
      systemd.services."flatpak-managed-install" = {
        after = ["network-online.target"];
        wants = ["network-online.target"];
      };

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
    (mkIf cfg.enable {
      services.flatpak.packages = [
        "io.github.kolunmi.Bazaar"
      ];

      services.flatpak.overrides."io.github.kolunmi.Bazaar" = {
        Context.filesystems = [
          "host-os:ro" # expose bazaar configs
        ];
      };

      environment.etc."bazaar/bazaar.yaml".source = (pkgs.formats.yaml {}).generate "bazaar.yaml" {
        txt-blocklist-paths = [
          "/run/host/etc/bazaar/blocklist.txt"
        ];
      };

      environment.etc."bazaar/blocklist.txt".text = ''
        com.valvesoftware.Steam
      '';
    })
    (mkIf (cfg.enable && config.brainrotos.desktop.plasma.v1.enable) {
      environment.systemPackages = [
        pkgs.kdePackages.flatpak-kcm
      ];
    })
  ];
}
