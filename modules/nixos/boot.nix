{
  lib,
  config,
  ...
}: let
  inherit (lib) mkDefault mkIf mkMerge;
  inherit (lib.options) mkOption;
  inherit (lib.types) bool;

  cfg = config.brainrotos;
in {
  options = {
    brainrotos.efi.v1 = mkOption {
      type = bool;
      default = true;
      description = "Enable EFI support (required for auto rollback).";
    };
  };

  config = mkMerge [
    (mkIf (!cfg.efi.v1) {
      boot.loader = {
        grub.enable = true;
      };
    })
    (mkIf cfg.efi.v1 {
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
