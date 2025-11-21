{...}: {
  imports = [
    ./base.nix
    ./boot.nix
    ./cleanup.nix
    ./desktop
    ./impermanence.nix
    ./label-disks.nix
    ./nix.nix
    ./ramcache.nix
    ./security.nix
  ];
}
