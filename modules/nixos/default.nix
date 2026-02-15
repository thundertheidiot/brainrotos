{...}: {
  imports = [
    ./base.nix
    ./boot.nix
    ./cleanup.nix
    ./desktop
    ./gpu.nix
    ./impermanence.nix
    ./label-disks.nix
    ./nix.nix
    ./ramcache.nix
    ./security.nix
  ];
}
