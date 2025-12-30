{
  lib,
  config,
  pkgs,
  ...
}: let
  inherit (lib) mkIf mkMerge getExe getExe';
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
    # bazaar service
    (mkIf cfg.enable {
      systemd.user.services."bazaar" = {
        description = "Bazaar Background Service";

        after = ["graphical-session.target"];
        wantedBy = ["graphical-session.target"];
        partOf = ["graphical-session.target"];

        unitConfig.ConditionUser = config.brainrotos.user.v1.name;

        serviceConfig = {
          ExecStart = "${getExe' pkgs.flatpak "flatpak"} run io.github.kolunmi.Bazaar --no-window";
          Restart = "on-failure";
          RestartSec = "5s";
        };
      };
    })
    # notifier
    (mkIf cfg.enable {
      systemd.services."flatpak-managed-install" = {
        serviceConfig = let
          markerFile = "${config.brainrotos.impermanence.v1.persist}/flatpak-first-installation-complete.flag";
          notify-send = getExe' pkgs.libnotify "notify-send";
          srun = "systemd-run --machine=${config.brainrotos.user.v1.name}@.host --user";
        in {
          ExecStartPost = [
            (pkgs.writeShellScript "flatpak-post-notification" (let
              notify-send = getExe' pkgs.libnotify "notify-send";
            in ''
              if [ ! -f "${markerFile}" ]; then
                ${srun} ${notify-send} -u normal -a "All set 🎉" "Everything has been installed, your system is ready to use!"
              fi

              # this should never be a problem
              mkdir --parents "$(dirname ${markerFile})"
              touch "${markerFile}"
            ''))
          ];
        };
      };
    })
    (mkIf (cfg.enable && config.brainrotos.desktop.plasma.v1.enable) {
      environment.systemPackages = [
        pkgs.kdePackages.flatpak-kcm
      ];
    })
  ];
}
