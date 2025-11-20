{...}: {
  config = {
    networking.networkmanager.enable = true;

    boot.initrd.systemd.enable = true;
    boot.initrd.systemd.emergencyAccess = true;

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
