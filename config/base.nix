{lib, ...}: let
  inherit (lib) mkDefault;
in {
  imports = [<brainrotos>];

  config = {
    brainrotos = {
      impermanence.v1.enable = mkDefault true;
      efi.v1.enable = mkDefault true;
      ramcache.v1.enable = mkDefault true;
      flatpak.v1.enable = mkDefault true;
    };

    # systemd.services.display-manager.serviceConfig.ExecStart = lib.mkForce "/run/current-system/sw/bin/false";
  };
}
