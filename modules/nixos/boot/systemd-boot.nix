{
  lib,
  config,
  pkgs,
  ...
}: let
  inherit (lib) mkIf mkMerge getExe' makeBinPath;

  cfg = config.brainrotos.boot.v1;
in {
  config = mkMerge [
    (mkIf (cfg.enable && cfg.efi && cfg.bootloader == "systemd") {
      boot.loader.systemd-boot = {
        enable = true;
        editor = false;

        extraInstallCommands = let
          path = makeBinPath [
            pkgs.jq
            pkgs.systemd
          ];
        in ''
          PATH=${path}:$PATH

          json=$(bootctl list --json=short)

          new=$(echo "$json" | jq -r '.[0].id')
          default=$(bootctl list --json=short | jq 'first(.[] | select(.isDefault)).id')

          # previous id won't exist on a fresh install
          if [ "$default" != "null" ] && [ -n "$default" ]; then
            echo "  Boot validation in effect"
            echo "  New generation: $new"
            echo "  Old generation: $default"

            # default to old one
            bootctl set-default "$default"
            # boot new one once
            bootctl set-oneshot "$new"
          else
            echo "  No previous generation detected. Defaulting to new generation."
          fi
        '';
      };

      systemd.services.brainrotos-validate-boot = {
        path = [
          pkgs.systemd
          pkgs.jq
          pkgs.gawk
        ];

        script = ''
          newest=$(bootctl list --json=short | jq '.[0].id')
          current=$(bootctl list --json=short | jq 'first(.[] | select(.isSelected)).id')
          default=$(bootctl list --json=short | jq 'first(.[] | select(.isDefault)).id')

          if [ ! -n "$newest" ] || [ ! -n "$current" ] || [ ! -n "$default" ]; then
            exit 1
          fi

          if [ "$newest" = "$current" ] && [ "$current" != "$default" ]; then
            echo "Current generation validated successfully, setting as default"
            bootctl set-default "$current"
            echo "systemd-boot: Default entry updated to $current"
          fi
        '';
      };
    })
  ];
}
