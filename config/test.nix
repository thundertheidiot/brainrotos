{...}: {
  # doesn't import local config
  config = {
    brainrotos = {
      desktop.plasma.v1.enable = true;
      impermanence.v1.enable = true;
      efi.v1.enable = true;
      ramcache.v1.enable = true;
      firefox.v1.enable = true;
      flatpak.v1.enable = true;
    };

    nixpkgs.hostPlatform = {system = "x86_64-linux";};
    system.stateVersion = "25.11";

    users.users.test = {
      isNormalUser = true;
      extraGroups = ["wheel"];
      initialPassword = "password";
    };

    users.users.root.password = "password";
  };
}
