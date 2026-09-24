{ ... }: {
  # doesn't import local config
  config = {
    brainrotos = {
      desktop.gnome.v1.enable = true;
      impermanence.v1.enable = true;
      efi.v1.enable = true;
      ramcache.v1.enable = true;
      firefox.v1.enable = true;
      flatpak.v1.enable = true;
      gpu.v1.type = "intel";
      user.v1.name = "test";
    };

    nixpkgs.hostPlatform = {
      system = "x86_64-linux";
    };
    system.stateVersion = "25.11";

    users.users.root.password = "password123";
  };
}
