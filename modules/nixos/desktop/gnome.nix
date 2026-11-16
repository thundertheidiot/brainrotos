{
  lib,
  config,
  pkgs,
  ...
}: let
  inherit (lib) mkIf mkMerge mkForce;
  inherit (lib.options) mkOption;
  inherit (lib.types) bool;

  cfg = config.brainrotos.desktop.gnome.v1;
in {
  options = {
    brainrotos.desktop.gnome.v1 = {
      enable = mkOption {
        type = bool;
        default = false;
        description = "Enable Gnome";
      };
    };
  };

  config = mkMerge [
    (mkIf cfg.enable {
      services.desktopManager.gnome.enable = true;
      services.gnome.games.enable = false;
      services.gnome.core-developer-tools.enable = false;

      # firefox is the preferred web browser, bazaar is used as the flatpak app store
      environment.gnome.excludePackages = [pkgs.epiphany pkgs.gnome-software pkgs.geary pkgs.yelp];
      services.gnome.gnome-software.enable = mkForce false;
    })
    (mkIf cfg.enable {
      services.displayManager.gdm.enable = true;

      systemd.services."display-manager".serviceConfig = {
        # - here should ignore failure, which will happpen on first boot
        ExecStartPre = "-${pkgs.writeShellScript "gdm-copy-monitor-config" ''
          mkdir --parents /etc/xdg
          cp "${config.users.users."${config.brainrotos.user.v1.name}".home}/.config/monitors.xml" /etc/xdg/monitors.xml
        ''}";
      };

      # gdm persistence
      brainrotos.impermanence.v1.directories = [
        {
          path = "/var/lib/gdm";
          permissions = "755";
        }
      ];
    })
    (mkIf cfg.enable {
      # cache components to ram on boot
      brainrotos.ramcache.v1.paths = with pkgs; [
        nautilus
        mutter
        gnome-shell
        gnome-session
      ];
    })
  ];
}
