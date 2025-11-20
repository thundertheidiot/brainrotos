{...}: {
  config = {
    networking.networkmanager.enable = true;

    boot.initrd.systemd.enable = true;
  };
}
