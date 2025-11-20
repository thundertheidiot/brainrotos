{
  lib,
  config,
  pkgs,
  ...
}: let
  inherit (lib) mkIf;
  inherit (lib.options) mkOption;
  inherit (lib.types) bool;

  cfg = config.brainrotos.desktop;
in {
  options = {
    brainrotos.desktop.plasma.v1 = mkOption {
      type = bool;
      default = true;
      description = "Enable KDE plasma";
    };
  };

  config = mkIf cfg.plasma.v1 {
    services.desktopManager.plasma6 = {
      enable = true;
      enableQt5Integration = true;
    };

    services.displayManager.sddm = {
      enable = true;
      wayland.enable = true;
    };

    brainrotos.impermanence.directories.v1 = [
      {
        path = "/var/lib/sddm";
        permissions = "750";
        user = "sddm";
        group = "sddm";
      }
    ];

    brainrotos.ramcache.paths.v1 = with pkgs.kdePackages; [
      dolphin
      kwin
      plasma-desktop
    ];
  };
}
