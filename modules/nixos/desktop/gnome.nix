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
      services.displayManager.gdm.enable = true;
      services.gnome.games.enable = false;
      services.gnome.core-developer-tools.enable = false;

      # firefox is the preferred web browser, bazaar is used as the flatpak app store
      environment.gnome.excludePackages = [pkgs.epiphany pkgs.gnome-software pkgs.geary pkgs.yelp];
      services.gnome.gnome-software.enable = mkForce false;
      services.gnome.geary.enable = mkForce false;
    })
    (mkIf cfg.enable {
      # impermanence
      brainrotos.impermanence.v1.directories = [
        {
          path = "/var/lib/gdm";
          permissions = "755";
        }
      ];

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
