{
  inputs,
  lib,
  ...
}: {
  perSystem = {
    pkgs,
    config,
    ...
  }: let
    # Ephemeral test VM: tmpfs root, host nix store through 9p with a
    # writable overlay (so impermanence bind mounts work), nothing persists.
    vmTest =
      (inputs.self.nixosConfigurations.test.extendModules {
        modules = [
          "${inputs.nixpkgs}/nixos/modules/virtualisation/qemu-vm.nix"
          {
            virtualisation = {
              graphics = true;
              diskImage = null;
              writableStore = true;
              memorySize = 4096;
              cores = 4;
              resolution = {
                x = 1280;
                y = 800;
              };
              forwardPorts = [
                {
                  from = "host";
                  host.port = 2222;
                  guest.port = 22;
                }
              ];
            };
          }
        ];
      }).config;

    ovmf = pkgs.OVMF.fd;
    qemu = pkgs.qemu;
  in {
    packages.vm = pkgs.writeShellApplication {
      name = "vm";
      text = ''
        set -euo pipefail

        MEM=4096
        CPUS=4

        export QEMU_OPTS="-display gtk -vga none -device virtio-vga -m $MEM -smp $CPUS"
        exec ${vmTest.system.build.vm}/bin/run-${vmTest.system.name}-vm
      '';
    };

    packages.vm-installed = pkgs.writeShellApplication {
      name = "vm-installed";
      runtimeInputs = [pkgs.coreutils];
      text = ''
        set -euo pipefail

        VM_DIR="''${BRAINROTOS_VM_DIR:-$PWD/vm}"
        DISK="$VM_DIR/disk.qcow2"
        VARS="$VM_DIR/OVMF_VARS.fd"
        MEM=4096
        CPUS=4
        BIOS=false

        while [ $# -gt 0 ]; do
          case $1 in
            --bios) BIOS=true ;;
            *) echo "unknown option: $1" >&2; exit 1 ;;
          esac
          shift
        done

        if [ ! -e "$DISK" ]; then
          echo "No disk image at $DISK" >&2
          echo "Create one first with: sudo nix run .#vm-install" >&2
          exit 1
        fi

        PFLASH=()
        if [ "$BIOS" != true ]; then
          if [ ! -e "$VARS" ]; then
            cp ${ovmf.variables} "$VARS"
            chmod 0644 "$VARS"
          fi
          PFLASH=(
            -drive "if=pflash,format=raw,readonly=on,file=${ovmf.firmware}"
            -drive "if=pflash,format=raw,file=$VARS"
          )
        fi

        exec ${qemu}/bin/qemu-system-x86_64 \
          -machine q35,accel=kvm:tcg \
          -cpu max \
          -m "$MEM" \
          -smp "$CPUS" \
          -device virtio-rng-pci \
          -device virtio-net-pci,netdev=n0 \
          -netdev "user,id=n0,hostfwd=tcp::2222-:22" \
          -drive "file=$DISK,if=virtio,format=qcow2,cache=writeback" \
          "''${PFLASH[@]}" \
          -vga none \
          -device virtio-vga \
          -usb -device usb-tablet \
          -display gtk
      '';
    };

    packages.vm-push = pkgs.writeShellApplication {
      name = "vm-push";
      runtimeInputs = with pkgs; [
        coreutils
        openssh
        rsync
      ];
      text = ''
        set -euo pipefail

        # copy the working tree into the test vm (ssh on port 2222, root,
        # password123) and rebuild it from /root/brainrotos, so test
        # generations never have to be pushed to a remote
        #
        #   nix run .#vm-push            # stage a new generation (boot)
        #   nix run .#vm-push switch     # activate immediately
        #
        ACTION="''${1:-boot}"

        case "$ACTION" in
          boot | switch | test | build) ;;
          *)
            echo "usage: vm-push [boot|switch|test|build]" >&2
            exit 1
            ;;
        esac

        SSH_OPTS=(
          -p 2222
          -o StrictHostKeyChecking=no
          -o UserKnownHostsFile=/dev/null
        )

        rsync -a --delete \
          --exclude .git --exclude vm --exclude result \
          -e "ssh ''${SSH_OPTS[*]}" \
          "$PWD/" root@localhost:/root/brainrotos/

        # remote command over stdin: expansions happen client side
        # (shellcheck misreads the intent; $ACTION must expand locally)
        # shellcheck disable=SC2087
        ssh "''${SSH_OPTS[@]}" root@localhost bash -s <<EOF
          cd /root/brainrotos &&
          nixos-rebuild $ACTION --impure --flake /root/brainrotos#base
EOF
      '';
    };

    packages.vm-install = pkgs.writeShellApplication {
      name = "vm-install";
      runtimeInputs = with pkgs; [
        qemu
        parted
        systemd
        kmod
        coreutils
        nix
        nixos-install-tools
      ];
      text = ''
        set -euo pipefail

        VM_DIR="''${BRAINROTOS_VM_DIR:-$PWD/vm}"
        DISK="$VM_DIR/disk.qcow2"
        SIZE="64G" # sparse, only occupies the space actually written to
        FORCE=false
        BIOS=false

        while [ $# -gt 0 ]; do
          case $1 in
            --force) FORCE=true ;;
            --bios) BIOS=true ;;
            *) echo "unknown option: $1" >&2; exit 1 ;;
          esac
          shift
        done

        if [ "$(id -u)" -ne 0 ]; then
          echo "Please run as root (use sudo)" >&2
          exit 1
        fi

        if [ -e "$DISK" ] && ! $FORCE; then
          echo "Disk image $DISK already exists, use --force to recreate it" >&2
          exit 1
        fi

        mkdir -p "$(dirname "$DISK")"
        rm -f "$DISK" "$VM_DIR/OVMF_VARS.fd"

        modprobe nbd 2>/dev/null || echo "warning: could not modprobe nbd" >&2

        NBD=""
        for d in /dev/nbd[0-9]*; do
          if [ ! -e "/sys/class/block/$(basename "$d")/pid" ]; then
            NBD=$d
            break
          fi
        done
        if [ -z "$NBD" ]; then
          echo "No free /dev/nbd device found" >&2
          exit 1
        fi

        qemu-img create -f qcow2 "$DISK" "$SIZE"

        cleanup() {
          umount /mnt/boot 2>/dev/null || true
          umount /mnt/nix 2>/dev/null || true
          qemu-nbd --disconnect "$NBD" 2>/dev/null || true
        }
        trap cleanup EXIT

        qemu-nbd --connect="$NBD" --format=qcow2 "$DISK"

        ${lib.getExe config.packages."vm-disk-setup"} "$NBD"
        udevadm settle

        BRAINROTOS_TARGET_EFI=$([ "$BIOS" = true ] && echo 0 || echo 1) ${lib.getExe config.packages."quick-install"}

        if [ "$BIOS" = true ]; then
          # the installer ran against the nbd device on the host, but the
          # vm attaches the disk as virtio vda; repoint grub so in-vm
          # rebuilds install to the right disk
          sed -i 's|/dev/nbd[0-9]\+|/dev/vda|g' /mnt/nix/osconfig/default.nix
        fi

        umount /mnt/boot /mnt/nix
        sync
        qemu-nbd --disconnect "$NBD"
        trap - EXIT

        # the script runs as root, hand the artifacts back to the invoking user
        if [ -n "''${SUDO_USER:-}" ] && [ "''${SUDO_USER}" != root ]; then
          chown -R "$SUDO_USER" "$VM_DIR"
        else
          echo "warning: not invoked through sudo, assuming uid 1000 should own the vm files" >&2
          chown -R 1000 "$VM_DIR"
        fi

        echo ""
        echo "BrainrotOS installed to $DISK (virtual size $SIZE, actually using $(du -h "$DISK" | cut -f1))"
        echo "Boot it with: nix run .#vm-installed"
      '';
    };
  };
}
