{
  lib,
  config,
  ...
}: let
  inherit (lib) mkDefault mkIf mkMerge;
  inherit (lib.options) mkOption;
  inherit (lib.types) bool;

  cfg = config.brainrotos.efi.v1;
in {
  options = {
    brainrotos.efi.v1.enable = mkOption {
      type = bool;
      default = true;
      description = "Enable EFI support (required for auto rollback).";
    };
  };

  config = mkMerge [
    (mkIf (!cfg.enable) {
      boot.loader = {
        grub.enable = true;
      };
    })
    (mkIf cfg.enable {
      boot.loader = {
        systemd-boot = {
          enable = true;
          editor = false;
        };

        efi.canTouchEfiVariables = mkDefault true;
        efi.efiSysMountPoint = mkDefault "/boot";
      };
    })
  ];
}
