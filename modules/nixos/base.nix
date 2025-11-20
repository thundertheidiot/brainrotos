{...}: {
  config = {
    networking.networkmanager.enable = true;

    boot.initrd.systemd.enable = true;
    boot.initrd.systemd.emergencyAccess = true;
  };
}
