{
  lib,
  config,
  pkgs,
  ...
}: let
  inherit (lib) mkIf mkMerge;
  inherit (lib.options) mkOption;
  inherit (lib.types) bool;

  cfg = config.brainrotos.desktop.plasma.v1;
in {
  options = {
    brainrotos.desktop.plasma.v1 = {
      enable = mkOption {
        type = bool;
        default = false;
        description = "Enable KDE plasma";
      };
      defaults = mkOption {
        type = bool;
        default = true;
        description = "Default BrainrotOS settings for KDE Plasma.";
      };
    };
  };

  config = mkMerge [
    (mkIf cfg.enable {
      services.desktopManager.plasma6 = {
        enable = true;
        enableQt5Integration = true;
      };

      services.displayManager.sddm = {
        enable = true;
        wayland.enable = true;
      };

      environment.systemPackages = [
        pkgs.kdePackages.sddm-kcm
      ];
    })
    (mkIf cfg.enable {
      # impermanence
      brainrotos.impermanence.v1.directories = [
        {
          path = "/var/lib/sddm";
          permissions = "750";
          user = "sddm";
          group = "sddm";
        }
      ];

      # cache components to ram on boot
      brainrotos.ramcache.v1.paths = with pkgs.kdePackages; [
        dolphin
        kwin
        plasma-desktop
      ];
    })
    (mkIf (cfg.enable && cfg.defaults) {
      environment.etc."xdg/kwinrc".text = ''
        [Plugins]
        shakecursorEnabled=false
      '';

      environment.etc."xdg/kdeglobals".text = ''
        [General]
        UseSystemBell=false

        [KDE]
        LookAndFeelPackage=org.kde.breezedark.desktop
      '';

      environment.etc."xdg/kcminputrc".text = ''
        [Mouse]
        cursorTheme=Breeze_Light
      '';

      environment.etc."xdg/kglobalshortcutsrc".text = ''
        [kwin]
        Window Maximize=Meta+Up
        Overview=Meta
      '';

      environment.etc."xdg/gtk-3.0/settings.ini".text = ''
        [Settings]
        gtk-application-prefer-dark-theme=true
      '';

      environment.etc."xdg/gtk-4.0/settings.ini".text = ''
        [Settings]
        gtk-application-prefer-dark-theme=true
      '';
    })
  ];
}
