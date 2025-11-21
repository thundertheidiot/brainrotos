{
  lib,
  config,
  pkgs,
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
    # boot counting
    (mkIf cfg.enable {
      # full disclaimer, made with the help of gemini 3 pro
      boot.loader.systemd-boot.extraInstallCommands = let
        esp = config.boot.loader.efi.efiSysMountPoint;
        # TODO maybe switch these
        grep = "${pkgs.gnugrep}/bin/grep";
        gawk = "${pkgs.gawk}/bin/awk";
      in ''
        DEFAULT_ENTRY=$(${grep} "^default" ${esp}/loader/loader.conf | ${awk} '{print $2}')

        if [ -n "$DEFAULT_ENTRY" ] && [[ "$DEFAULT_ENTRY" != *"+"* ]]; then
          TRIES=2

          NEW_ENTRY="''${DEFAULT_ENTRY%.conf}+$TRIES.conf"

          if [ -f "${esp}/loader/entries/$DEFAULT_ENTRY" ]; then
            mv "${esp}/loader/entries/$DEFAULT_ENTRY" "${esp}/loader/entries/$NEW_ENTRY"

            # Update loader.conf to point to the new filename
            sed -i "s/$DEFAULT_ENTRY/$NEW_ENTRY/" "${esp}/loader/loader.conf"

            echo "Boot counting enabled: Renamed $DEFAULT_ENTRY to $NEW_ENTRY"
          fi
        fi
      '';

      # https://blog.printk.io/2020/02/systemd-boot-counting-and-boot-complete-target/
      systemd.targets."boot-complete" = {
        enable = true;
        wantedBy = ["basic.target"];
      };

      systemd.services."systemd-bless-boot" = {
        enable = true;
        wantedBy = ["multi-user.target"];
        requires = ["display-manager.service"];
      };
    })
  ];
}
