{
  lib,
  config,
  pkgs,
  ...
}: let
  inherit (lib) mkDefault mkIf mkMerge getExe';
  inherit (lib.options) mkOption;
  inherit (lib.types) bool enum;

  cfg = config.brainrotos.boot.v1;
in {
  options = {
    brainrotos.boot.v1 = {
      enable = mkOption {
        type = bool;
        default = true;
        description = "Configure bootloader and boot validation.";
      };

      efi = mkOption {
        type = bool;
        default = false;
        description = "Does this system support EFI?";
      };

      bootloader = mkOption {
        type = enum ["grub" "systemd"];
        default =
          if cfg.efi
          then "systemd"
          else "grub";
        description = "Bootloader variant to install.";
      };
    };
  };

  imports = [
    ./systemd-boot.nix
  ];

  config = mkMerge [
    (mkIf (cfg.enable && cfg.efi) {
      boot.loader.efi.canTouchEfiVariables = mkDefault true;
      boot.loader.efi.efiSysMountPoint = mkDefault "/boot";
    })
    (mkIf (cfg.enable) {
      systemd.services.brainrotos-validate-boot = rec {
        enable = true;
        description = "Validate system health and bless the newly booted configuration";

        requires = ["display-manager.service" "local-fs.target"];
        after = ["display-manger.service" "local-fs.target"];

        wantedBy = ["multi-user.target"];

        serviceConfig = {
          Type = "oneshot";
          User = "root";
          ExecStartPre = map (target: "${getExe' pkgs.systemd "systemctl"} is-active --quiet ${target}") requires;
        };
      };
    })
  ];
}
