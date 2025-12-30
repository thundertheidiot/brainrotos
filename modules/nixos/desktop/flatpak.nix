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
    # default flatpaks
    (mkIf cfg.enable {
      services.flatpak.packages = [
        "io.github.kolunmi.Bazaar"
        "com.github.tchx84.Flatseal"
      ];

      services.flatpak.overrides."io.github.kolunmi.Bazaar" = {
        Context.filesystems = [
          "host-etc:ro" # expose bazaar configs
        ];
      };

      # environment.etc won't work here, because it actually links stuff into /etc/static
      # and we cannot pass directories in /etc to the flatpak
      # using C here avoids having to mount /nix/store for the symlinks
      systemd.tmpfiles.rules = [
        "d /etc/bazaar 0755 root root - -"
        "C /etc/bazaar/bazaar.yaml - - - - ${(pkgs.formats.yaml {}).generate "bazaar.yaml" {
          txt-blocklist-paths = [
            "/run/host/etc/bazaar/blocklist.txt"
          ];
        }}"
        "C /etc/bazaar/blocklist.txt - - - - ${pkgs.writeText "blocklist.txt" ''
          com.valvesoftware.Steam
        ''}"
      ];
    })
    (mkIf (cfg.enable && config.brainrotos.desktop.plasma.v1.enable) {
      environment.systemPackages = [
        pkgs.kdePackages.flatpak-kcm
      ];
    })
  ];
}
