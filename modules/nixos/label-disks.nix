{
  lib,
  config,
  ...
}: let
  inherit (lib) mkIf mkDefault;
  inherit (lib.options) mkOption;
  inherit (lib.types) bool;

  cfg = config.brainrotos;
in {
  options = {
    brainrotos.labeledDisks.v1 = mkOption {
      type = bool;
      default = true;
      description = "Find disks through labels.";
    };
  };
  config = mkIf cfg.labeledDisks.v1 {
    fileSystems = {
      "/" = {
        fsType = "tmpfs";
        options = [
          "size=10M"
          "defaults"
          "mode=755"
        ];
      };
      "/boot" = {
        label = mkDefault "bros-boot";
      };
      "/nix" = {
        label = mkDefault "bros-main";
        fsType = mkDefault "btrfs";
        options = mkDefault "subvolume=@nix";
        neededForBoot = true;
      };
      "/home" = {
        label = mkDefault "bros-main";
        fsType = mkDefault "btrfs";
        options = mkDefault "subvolume=@home";
      };
      "/tmp" = {
        label = mkDefault "bros-main";
        fsType = mkDefault "btrfs";
        options = mkDefault "subvolume=@tmp";
        neededForBoot = true;
      };
      "/var/tmp" = {
        label = mkDefault "bros-main";
        fsType = mkDefault "btrfs";
        options = mkDefault "subvolume=@var_tmp";
      };
    };
  };
}
