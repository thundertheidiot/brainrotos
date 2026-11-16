{
  lib,
  config,
  pkgs,
  ...
}:
let
  inherit (lib) mkIf mkMerge isString;
  inherit (lib.options) mkOption;
  inherit (lib.lists) flatten;
  inherit (lib.strings) concatStringsSep replaceStrings;
  inherit (lib.attrsets) filterAttrs mapAttrsToList listToAttrs;
  inherit (lib.types)
    listOf
    bool
    str
    attrs
    either
    ;

  cfg = config.brainrotos.impermanence.v1;
in
{
  options = {
    brainrotos.impermanence.v1 = {
      enable = mkOption {
        type = bool;
        default = true;
        description = "Enable impermanence";
      };

      persist = mkOption {
        type = str;
        default = "/nix/persist";
        description = "Directory to use for persistance of files.";
      };

      directories = mkOption {
        type = listOf (either attrs str);
        default = [ ];
        apply =
          let
            mkDir' =
              {
                path,
                persistPath ? "${cfg.persist}/rootfs/${path}",
                permissions ? "0755",
                user ? "root",
                group ? "root",
                wantedBy ? [ ],
                before ? [ ],
              }:
              {
                inherit
                  path
                  persistPath
                  permissions
                  user
                  group
                  wantedBy
                  before
                  ;
              };

            mkDir = dir: if isString dir then mkDir' { path = dir; } else mkDir' dir;
          in
          list: map mkDir list;
        description = "Directories to persist across reboots.";
      };

      files = mkOption {
        type = listOf (either attrs str);
        default = [ ];
        apply =
          let
            mkFile' =
              {
                path,
                persistPath ? "${cfg.persist}/rootfs/${path}",
                permissions ? "0644",
                user ? "root",
                group ? "root",
                wantedBy ? [ ],
                before ? [ ],
              }:
              {
                inherit
                  path
                  persistPath
                  permissions
                  user
                  group
                  wantedBy
                  before
                  ;
              };

            mkFile = file: if isString file then mkFile' { path = file; } else mkFile' file;
          in
          list: map mkFile list;
        description = "Files to persist across reboots.";
      };
    };
  };

  config = mkMerge [
    (mkIf cfg.enable {
      brainrotos.impermanence.v1.directories = [
        {
          path = "/var/log";
          permissions = "711";
        }
        {
          path = "/var/lib/bluetooth";
          permissions = "0700";
        }
        {
          path = "/root/.cache/nix";
          permissions = "0700";
        }
        "/var/lib/systemd"
        {
          path = "/etc/NetworkManager/system-connections";
          permissions = "0700";
        }
        "/var/lib/fwupd"
        "/var/cache/fwupd"
        {
          path = "/var/lib/fprint";
          permissions = "0700";
        }
        {
          # sudo creates this as 0711, the timestamp dir inside is 0700
          path = "/var/db/sudo";
          permissions = "0711";
        }
        # uid/gid maps, must be stable so users keep their uids
        # (bind mounted early by the shadow restore activation script)
        "/var/lib/nixos"
      ];

      brainrotos.impermanence.v1.files = [
        "/etc/localtime"
      ];
    })

    # Create and mount directories
    (mkIf cfg.enable {
      systemd.mounts = map (
        dir: with dir; {
          where = path;
          what = persistPath;
          type = "none";
          options = "bind,X-fstrim.notrim,x-gvfs-hidden";

          before = [ "default.target" ] ++ before;
          wantedBy = [ "default.target" ] ++ wantedBy;
        }
      ) cfg.directories;

      systemd.tmpfiles.rules = flatten (
        map (
          dir: with dir; [
            "d ${persistPath} ${permissions} ${user} ${group} - -"
            "d ${path} ${permissions} ${user} ${group} - -"
          ]
        ) cfg.directories
      );
    })

    # Create and mount files
    (mkIf cfg.enable {
      boot.postBootCommands = concatStringsSep " " (
        map (
          file: with file; ''
            if [ -e "${persistPath}" ] || [ -L "${persistPath}" ]; then
              cp -P "${persistPath}" "${path}"
            fi
          ''
        ) cfg.files
      );

      systemd.services = listToAttrs (
        map (
          file:
          with file;
          let
            name = "persist-${replaceStrings [ "/" ] [ "_" ] path}";
          in
          {
            inherit name;
            value = {
              wantedBy = [ "default.target" ];
              path = [ pkgs.util-linux ];
              unitConfig.DefaultDependencies = true;
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
                # Service is stopped before shutdown
                ExecStop = pkgs.writeShellScript name ''
                  mkdir --parents "$(dirname ${persistPath})"
                  cp -P "${path}" "${persistPath}"
                '';
              };
            };
          }
        ) cfg.files
      );
    })

    ### fixes/hacks

    # home directories
    (mkIf cfg.enable {
      systemd.tmpfiles.rules = mapAttrsToList (
        name: user: "d ${user.home} 0700 ${name} ${user.group} - -"
      ) (filterAttrs (_name: attrs: attrs.createHome) config.users.users);
    })

    # machine id
    (mkIf cfg.enable {
      # /etc/machine-id is a dangling symlink until the persisted file
      # exists, which breaks dbus (and everything on top of it) on a
      # fresh install. generate it in stage 2, before systemd services.
      boot.postBootCommands = ''
        if [ ! -s "${cfg.persist}/rootfs/etc/machine-id" ]; then
          mkdir -p "${cfg.persist}/rootfs/etc"
          tr -d '-' < /proc/sys/kernel/random/boot_id > "${cfg.persist}/rootfs/etc/machine-id"
          chmod 0444 "${cfg.persist}/rootfs/etc/machine-id"
        fi
      '';

      environment.etc = listToAttrs (
        map (loc: {
          name = loc;
          value = {
            source = "${cfg.persist}/rootfs/etc/${loc}";
          };
        }) [ "machine-id" ]
      );
    })

    # /etc/shadow (passwords)
    # cannot be handled through files, must be restored before the users
    # activation script runs, so that existing hashes are kept and new users
    # are added on top of them
    (mkIf cfg.enable (
      let
        pShadow = "${cfg.persist}/rootfs/etc/shadow";
        pNixos = "${cfg.persist}/rootfs/var/lib/nixos";

        saveShadow = pkgs.writeShellScript "persist_etc_shadow" ''
          set -eu
          [ -f /etc/shadow ] || exit 0
          dir="$(dirname "${pShadow}")"
          mkdir --parents "$dir"
          tmp="$(mktemp --tmpdir="$dir" .shadow.XXXXXX)"
          trap 'rm -f "$tmp"' EXIT
          cp /etc/shadow "$tmp"
          chmod 600 "$tmp"
          sync "$tmp"
          mv -f "$tmp" "${pShadow}"
        '';
      in
      {
        system.activationScripts.etc_shadow_restore = {
          text = ''
            # /var/lib/nixos holds the uid/gid maps used by the users script,
            # it needs to be the persisted one before that runs
            mkdir -p "${pNixos}" /var/lib/nixos
            mountpoint -q /var/lib/nixos || mount --bind "${pNixos}" /var/lib/nixos

            # only at boot, when no shadow has been generated yet
            if [ ! -e /etc/shadow ] && [ -f "${pShadow}" ]; then
              mkdir -p /etc
              cp "${pShadow}" /etc/shadow.restore
              chmod 600 /etc/shadow.restore
              mv -f /etc/shadow.restore /etc/shadow
            fi
          '';
        };

        # the users script is a plain attrset unless sysusers/userborn is used
        system.activationScripts.users = mkIf (
          !config.systemd.sysusers.enable && !config.services.userborn.enable
        ) { deps = [ "etc_shadow_restore" ]; };

        systemd.services."etc_shadow_persistence" = {
          enable = true;
          description = "Persist /etc/shadow on shutdown.";
          wantedBy = [ "sysinit.target" ];
          unitConfig.RequiresMountsFor = [ "${cfg.persist}" ];
          unitConfig.DefaultDependencies = true;
          path = [ pkgs.coreutils ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = saveShadow;
            # Service is stopped before shutdown
            ExecStop = saveShadow;
          };
        };

        # save whenever shadow changes (password changes, new users)
        systemd.services."etc_shadow_save" = {
          description = "Persist /etc/shadow after a change.";
          unitConfig.RequiresMountsFor = [ "${cfg.persist}" ];
          path = [ pkgs.coreutils ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = saveShadow;
          };
        };

        systemd.paths."etc_shadow_save" = {
          description = "Watch /etc/shadow for changes.";
          wantedBy = [ "multi-user.target" ];
          pathConfig.PathChanged = "/etc/shadow";
        };
      }
    ))

    # openssh
    (mkIf cfg.enable {
      systemd.tmpfiles.rules = [ "d ${cfg.persist}/ssh 755 root root - -" ];

      services.openssh.hostKeys = [
        {
          path = "${cfg.persist}/ssh/ssh_host_ed25519_key";
          type = "ed25519";
        }
        {
          path = "${cfg.persist}/ssh/ssh_host_rsa_key";
          type = "rsa";
          bits = 4096;
        }
      ];
    })
  ];
}
