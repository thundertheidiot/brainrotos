{lib, ...}: let
  inherit (lib) mkDefault;
in {
  config = {
    networking.networkmanager.enable = true;

    boot.tmp.cleanOnBoot = mkDefault true;
    hardware.enableRedistributableFirmware = mkDefault true;

    boot.initrd.systemd.enable = true;
    boot.initrd.systemd.emergencyAccess = true;

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
