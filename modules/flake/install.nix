{
  inputs,
  lib,
  ...
}: let
  inherit (lib) getExe;
in {
  perSystem = {pkgs, ...}: rec {
    packages.vm-setup = pkgs.writers.writeBashBin "vm-setup" ''
      set -e

      if [ "$EUID" -ne 0 ]; then
        echo "Please run as root (use sudo)"
        exit 1
      fi

      ${getExe packages.vm-disk-setup}
      ${getExe packages.quick-install}
    '';

    packages.vm-disk-setup = pkgs.writers.writeBashBin "vm-disk-setup" ''
      set -e

      DISK="''${1:-/dev/vda}"

      parted -s "$DISK" -- mklabel gpt
      parted -s "$DISK" -- mkpart ESP fat32 1MiB 512MiB
      parted -s "$DISK" -- set 1 esp on
      parted -s "$DISK" -- mkpart primary btrfs 512MiB 100%

      if [[ "$DISK" == *"nvme"* ]] || [[ "$DISK" == *"mmcblk"* ]]; then
          BOOT_PART="''${DISK}p1"
          MAIN_PART="''${DISK}p2"
      else
          BOOT_PART="''${DISK}1"
          MAIN_PART="''${DISK}2"
      fi

      mkfs.fat -F 32 -n BROS_BOOT "$BOOT_PART"
      mkfs.btrfs -f -L bros-main "$MAIN_PART"

      mount "$MAIN_PART" /mnt
      btrfs subvolume create /mnt/@nix
      btrfs subvolume create /mnt/@home
      btrfs subvolume create /mnt/@tmp
      btrfs subvolume create /mnt/@var_tmp
      umount /mnt
    '';

    packages.quick-install = pkgs.writers.writeBashBin "quick-install" ''
      set -e

      mkdir -p /mnt/boot /mnt/nix
      mount /dev/disk/by-label/BROS_BOOT /mnt/boot
      mount /dev/disk/by-label/bros-main -o subvol=@nix /mnt/nix

      mkdir -p /mnt/nix/osconfig
      cat > /mnt/nix/osconfig/default.nix << EOF
      {
        config = {
          brainrotos = {
            efi.v1.enable = $([ -d /sys/firmware/efi ] && echo true || echo false);
            desktop.gnome.v1.enable = true;
            firefox.v1.enable = true;
            user.v1.name = "user";
          };

          networking.hostName = "brainrotos";
          nixpkgs.hostPlatform = {system = "x86_64-linux";};
          system.stateVersion = "25.11";
        };
      }
      EOF

      nixos-install --impure --no-root-password --no-channel-copy -I brainrotos=/mnt/nix/osconfig --flake ${inputs.self.outPath}#base

      echo <<EOF
      BrainrotOS installed
      EOF
    '';
  };
}
