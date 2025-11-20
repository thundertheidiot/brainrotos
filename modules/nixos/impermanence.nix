{
  lib,
  config,
  pkgs,
  ...
}: let
  inherit (lib) mkIf mkMerge isString;
  inherit (lib.options) mkOption;
  inherit (lib.lists) flatten;
  inherit (lib.attrsets) filterAttrs mapAttrsToList;
  inherit (lib.types) listOf bool str attrs either;

  cfg = config.brainrotos.impermanence;
in {
  options = {
    brainrotos.impermanence = {
      enable.v1 = mkOption {
        type = bool;
        default = true;
        description = "Enable impermanence";
      };

      persist.v1 = mkOption {
        type = str;
        default = "/nix/persist";
        description = "Directory to use for persistance of files.";
      };

      directories.v1 = mkOption {
        type = listOf (either attrs str);
        default = [];
        apply = let
          mkDir' = {
            path,
            persistPath ? "${cfg.persist.v1}/rootfs/${path}",
            permissions ? "1777",
            user ? "root",
            group ? "root",
            wantedBy ? [],
            before ? [],
          }: {
            inherit path persistPath permissions user group wantedBy before;
          };

          mkDir = dir:
            if isString dir
            then mkDir' {path = dir;}
            else mkDir' dir;
        in
          list: map mkDir list;
        description = "Directories to persist across reboots.";
      };
    };
  };

  config = mkMerge [
    (mkIf cfg.enable.v1 {
      brainrotos.impermanence.directories.v1 = [
        {
          path = "/var/log";
          permissions = "711";
        }
        "/var/lib/bluetooth"
        "/root/.cache/nix"
        "/var/lib/systemd"
        "/etc/NetworkManager/system-connections"
        "/var/lib/fwupd"
        "/var/cache/fwupd"
        "/var/lib/fprint"
      ];
    })

    # Create and mount directories
    (mkIf cfg.enable.v1 {
      systemd.mounts = map (dir:
        with dir; {
          where = path;
          what = persistPath;
          type = "none";
          options = "bind,X-fstrim.notrim,x-gvfs-hidden";

          before = ["graphical.target"] ++ before;
          wantedBy = ["graphical.target"] ++ wantedBy;
        })
      cfg.directories.v1;

      systemd.tmpfiles.rules = flatten (map (dir:
        with dir; [
          "d ${persistPath} ${permissions} ${user} ${group} - -"
          "d ${path} ${permissions} ${user} ${group} - -"
        ])
      cfg.directories.v1);
    })

    # fixes/hacks
    (mkIf cfg.enable.v1 {
      systemd.tmpfiles.rules =
        mapAttrsToList
        (name: user: "d ${user.home} 0700 ${name} ${user.group} - -")
        (filterAttrs (_name: attrs: attrs.createHome) config.users.users);
    })

    (mkIf cfg.enable.v1 {
      environment.etc = builtins.listToAttrs (builtins.map (loc: {
        name = loc;
        value = {source = "${cfg.persist.v1}/rootfs/etc/${loc}";};
      }) ["machine-id"]);
    })
    # etc shadow
    (mkIf cfg.enable.v1 (let
      pShadow = "${cfg.persist.v1}/rootfs/etc/shadow";
    in {
      system.activationScripts = {
        # The first copy accounts for reactivation after startup, this example scenario should explain that
        # 1. User starts up their computer
        # 2. ${pShadow} is copied over /etc/shadow
        # 3. User changes their password
        # 4. User updates their system, reactivating the configuration
        # 5. The old unchanged ${pShadow} is copied over /etc/shadow
        # 6. User is very confused, as their password has changed back
        etc_shadow = ''
          mkdir --parents "${cfg.persist.v1}/rootfs/etc"
          [ -f "/etc/shadow" ] && cp /etc/shadow ${pShadow}
          [ -f "${pShadow}" ] && cp ${pShadow} /etc/shadow
        '';

        users.deps = ["etc_shadow"];
      };

      systemd.services."etc_shadow_persistence" = {
        enable = true;
        description = "Persist /etc/shadow on shutdown.";
        wantedBy = ["multi-user.target"];
        path = [pkgs.util-linux];
        unitConfig.defaultDependencies = true;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          # Service is stopped before shutdown
          ExecStop = pkgs.writeShellScript "persist_etc_shadow" ''
            mkdir --parents "${cfg.persist.v1}/rootfs/etc"
            cp /etc/shadow ${pShadow}
          '';
        };
      };
    }))

    # openssh
    {
      systemd.tmpfiles.rules = ["d ${cfg.persist.v1}/ssh 755 root root - -"];

      services.openssh.hostKeys = [
        {
          path = "${cfg.persist.v1}/ssh/ssh_host_ed25519_key";
          type = "ed25519";
        }
        {
          path = "${cfg.persist.v1}/ssh/ssh_host_rsa_key";
          type = "rsa";
          bits = 4096;
        }
      ];
    }
  ];
}
