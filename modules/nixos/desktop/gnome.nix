{
  lib,
  config,
  pkgs,
  ...
}: let
  inherit (lib) mkIf mkMerge;
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
