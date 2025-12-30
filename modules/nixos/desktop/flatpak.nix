{
  lib,
  config,
  pkgs,
  ...
}: let
  inherit (lib) mkIf mkMerge;
  inherit (lib.options) mkOption;
  inherit (lib.lists) optional;
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
    # notifier
    (mkIf cfg.enable {
      systemd.user.services.brainrotos-flatpak-install-monitor = {
        description = "Monitor Flatpak Managed Install Status";
        wantedBy = ["graphical-session.target"];
        partOf = ["graphical-session.target"];

        path =
          [pkgs.libnotify]
          ++ optional config.brainrotos.desktop.gnome.v1.enable pkgs.gnome-console
          ++ optional config.brainrotos.desktop.plasma.v1.enable pkgs.kdePackages.konsole;
        script = let
          ifGnome = t:
            if config.brainrotos.desktop.gnome.v1.enable
            then t
            else "";
          ifPlasma = t:
            if config.brainrotos.desktop.plasma.v1.enable
            then t
            else "";
        in ''
          MARKER_FILE="$HOME/.local/state/flatpak-setup-done"
          SERVICE_NAME="flatpak-managed-install.service"

          if [ -f "$MARKER_FILE" ]; then
            exit 0
          fi

          if systemctl --system is-active --quiet "$SERVICE_NAME"; then
            if [ "$(notify-send -u critical -a "First Setup" --action=follow="Watch Log" "Important packages are still being installed, please wait..." -w)" = "follow" ]; then
              ${ifGnome "kgx --"}${ifPlasma "konsole -e"} journalctl -fu "$SERVICE_NAME"
            fi

            while systemctl --system is-active --quiet "$SERVICE_NAME"; do
              sleep 5
            done

            notify-send -u normal -a "First Setup" "Package installation completed!"

            ${ifGnome "gsettings set org.gnome.desktop.search-providers enabled \"['io.github.kolunmi.Bazaar.desktop']\""}
          fi

          mkdir --parents "$(dirname $MARKER_FILE)"
          touch "$MARKER_FILE"
        '';

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = false;
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
