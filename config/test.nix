{...}: {
  # doesn't import local config
  config.brainrotos = {
    desktop.plasma.v1 = true;
    impermanence.enable.v1 = true;
    efi.v1 = true;
  };

  nixpkgs.hostPlatform = {system = "x86_64-linux";};

  users.users.test = {
    isNormalUser = true;
    extraGroups = ["wheel"];
    initialPassword = "password";
  };
}
