{
  config,
  lib,
  ...
}: let
  inherit (lib) mkDefault;
  inherit (lib.options) mkOption;
  inherit (lib.types) str;
in {
  options = {
    brainrotos.user.v1.name = mkOption {
      default = "brainrotos";
      type = str;
      description = "Username for the user account.";
    };
  };

  config = {
    networking.networkmanager.enable = true;

    boot.tmp.cleanOnBoot = mkDefault true;
    hardware.enableRedistributableFirmware = mkDefault true;

    boot.initrd.systemd.enable = true;
    boot.initrd.systemd.emergencyAccess = true;

    users.users."${config.brainrotos.user.v1.name}" = {
      isNormalUser = true;
      extraGroups = ["wheel"];
      initialPassword = mkDefault "password123";
    };

    systemd.settings.Manager = {
      DefaultTimeoutStopSec = "3s";
    };

    boot.initrd.availableKernelModules = [
      "ahci"
      "virtio_pci"
      "virtio_scsi"
      "virtio_blk"
      "scsi_mod"
      "sd_mod"
      "nvme"
    ];
  };
}
