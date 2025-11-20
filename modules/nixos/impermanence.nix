{
  lib,
  config,
  pkgs,
  ...
}: let
  inherit (lib) mkIf mkMerge isString;
  inherit (lib.options) mkOption;
  inherit (lib.lists) flatten;
  inherit (lib.strings) concatStringsSep replaceStrings;
  inherit (lib.attrsets) filterAttrs mapAttrsToList listToAttrs;
  inherit (lib.types) listOf bool str attrs either;

  cfg = config.brainrotos.impermanence.v1;
in {
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
        default = [];
        apply = let
          mkDir' = {
            path,
            persistPath ? "${cfg.persist}/rootfs/${path}",
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

      files = mkOption {
        type = listOf (either attrs str);
        default = [];
        apply = let
          mkFile' = {
            path,
            persistPath ? "${cfg.persist}/rootfs/${path}",
            permissions ? "1777",
            user ? "root",
            group ? "root",
            wantedBy ? [],
            before ? [],
          }: {
            inherit path persistPath permissions user group wantedBy before;
          };

          mkFile = file:
            if isString file
            then mkFile' {path = file;}
            else mkFile' file;
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
        "/var/lib/bluetooth"
        "/root/.cache/nix"
        "/var/lib/systemd"
        "/etc/NetworkManager/system-connections"
        "/var/lib/fwupd"
        "/var/cache/fwupd"
        "/var/lib/fprint"
      ];

      brainrotos.impermanence.v1.files = [
        "/etc/localtime"
      ];
    })

    # Create and mount directories
    (mkIf cfg.enable {
      systemd.mounts = map (dir:
        with dir; {
          where = path;
          what = persistPath;
          type = "none";
          options = "bind,X-fstrim.notrim,x-gvfs-hidden";

          before = ["graphical.target"] ++ before;
          wantedBy = ["graphical.target"] ++ wantedBy;
        })
      cfg.directories;

      systemd.tmpfiles.rules = flatten (map (dir:
        with dir; [
          "d ${persistPath} ${permissions} ${user} ${group} - -"
          "d ${path} ${permissions} ${user} ${group} - -"
        ])
      cfg.directories);
    })
    # Create and mount directories
    (mkIf cfg.enable {
      boot.postBootCommands =
        concatStringsSep " "
        (map (file:
          with file; ''
            [ -f "${persistPath}" ] && cp -P "${persistPath}" "${path}"
          ''))
        cfg.files;

      systemd.services = listToAttrs (map
        (file:
          with file; let
            name = "persist-${replaceStrings ["/"] ["_"] path}";
          in {
            inherit name;
            value = {
              wantedBy = ["graphical.target"];
              path = [pkgs.util-linux];
              unitConfig.defaultDependencies = true;
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
                # Service is stopped before shutdown
                ExecStop = pkgs.writeShellScript name ''
                  mkdir --parents "${persistPath}"
                  cp -P "${path}" "${persistPath}"
                '';
              };
            };
          })
        cfg.files);
    })

    ### fixes/hacks

    # home directories
    (mkIf cfg.enable {
      systemd.tmpfiles.rules =
        mapAttrsToList
        (name: user: "d ${user.home} 0700 ${name} ${user.group} - -")
        (filterAttrs (_name: attrs: attrs.createHome) config.users.users);
    })

    # machine id
    (mkIf cfg.enable {
      environment.etc = builtins.listToAttrs (builtins.map (loc: {
        name = loc;
        value = {source = "${cfg.persist}/rootfs/etc/${loc}";};
      }) ["machine-id"]);
    })

    # /etc/shadow (passwords)
    # cannot be handled through files, must run before user setup
    (mkIf cfg.enable (let
      pShadow = "${cfg.persist}/rootfs/etc/shadow";
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
          mkdir --parents "${cfg.persist}/rootfs/etc"
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
            mkdir --parents "${cfg.persist}/rootfs/etc"
            cp /etc/shadow ${pShadow}
          '';
        };
      };
    }))

    # openssh
    {
      systemd.tmpfiles.rules = ["d ${cfg.persist}/ssh 755 root root - -"];

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
    }
  ];
}
