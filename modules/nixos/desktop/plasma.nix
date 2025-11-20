{
  lib,
  config,
  pkgs,
  ...
}: let
  inherit (lib) mkIf;
  inherit (lib.options) mkOption;
  inherit (lib.types) bool;

  cfg = config.brainrotos.desktop.plasma.v1;
in {
  options = {
    brainrotos.desktop.plasma.v1.enable = mkOption {
      type = bool;
      default = true;
      description = "Enable KDE plasma";
    };
  };

  config = mkIf cfg.enable {
    services.desktopManager.plasma6 = {
      enable = true;
      enableQt5Integration = true;
    };

    services.displayManager.sddm = {
      enable = true;
      wayland.enable = true;
    };

    brainrotos.impermanence.v1.directories = [
      {
        path = "/var/lib/sddm";
        permissions = "750";
        user = "sddm";
        group = "sddm";
      }
    ];

    brainrotos.ramcache.v1.paths = with pkgs.kdePackages; [
      dolphin
      kwin
      plasma-desktop
    ];
  };
}
