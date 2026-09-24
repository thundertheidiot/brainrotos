{...}: {
  imports = [
    ./base.nix
    ./boot
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
