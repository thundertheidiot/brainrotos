{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    mkIf
    mkMerge
    concatStringsSep
    range
    ;
  inherit (lib.options) mkOption;
  inherit (lib.types)
    bool
    int
    listOf
    package
    str
    ;
  inherit (lib.attrsets) listToAttrs;

  cfg = config.brainrotos.boot-validation.v1;

  useGrub = config.boot.loader.grub.enable;
  useSystemdBoot = config.boot.loader.systemd-boot.enable;
  enabled = cfg.enable && (useGrub || useSystemdBoot);

  # grub must find the env block at its prefix (/boot/grub/grubenv);
  # on non-grub systems the path is arbitrary, it is only greenboot's
  # state store
  grubenvFile =
    if useGrub
    then "/boot/grub/grubenv"
    else "${config.boot.loader.efi.efiSysMountPoint}/greenboot.grubenv";
  loaderConfFile = "${config.boot.loader.efi.efiSysMountPoint}/loader/loader.conf";

  bootLoader = if useGrub then "grub" else "systemd-boot";

  greenboot = pkgs.callPackage ../../../pkgs/greenboot.nix {
    grubenvPath = grubenvFile;
  };

  # grub has no arithmetic (nixpkgs does not carry fedora's increment
  # module), so counting is done by matching against literal strings.
  # the chain must run from 1 upwards: a block that fires cannot enable
  # a later block, otherwise one boot would decrement twice.
  grubCountingSnippet =
    let
      decrements = concatStringsSep "\n" (
        map (n: ''
          if [ "''${boot_counter}" = "${toString n}" ]; then
            set boot_counter=${toString (n - 1)}
          fi
        '') (range 1 cfg.attempts)
      );
    in
    ''
      # brainrotos boot validation
      # persistent steering (e.g. after a rollback landing): wins over
      # everything below and over greenboot's success writes
      if [ -n "''${bros_boot_entry}" ]; then
        set default="''${bros_boot_entry}"
      fi
      if [ -n "''${boot_counter}" -a "''${boot_success}" = "0" ]; then
        if [ "''${boot_counter}" = "0" -o "''${boot_counter}" = "-1" ]; then
          if [ -n "''${bros_fallback_entry}" ]; then
            set default="''${bros_fallback_entry}"
          fi
          set boot_counter=-1
        else
          ${decrements}
          save_env boot_counter
        fi
        save_env boot_counter
      fi

      # count this boot as not-yet-validated until userspace says otherwise
      set boot_success=0
      save_env boot_success
    '';

  # runtime helper; @var@ tokens in boot-validation.sh are substituted here
  bootValidation = pkgs.writeShellApplication {
    name = "brainrotos-boot-validation";
    runtimeInputs = with pkgs; [
      coreutils
      gawk
      gnugrep
      gnused
      grub2
      systemd
      util-linux
    ];

    text = lib.readFile (
      pkgs.replaceVars ./boot-validation.sh {
        inherit (cfg) attempts;
        timeout = cfg.desktopGraceSec;
        inherit bootLoader;
        grubenv = grubenvFile;
        loaderConf = loaderConfFile;
        desktop =
          if config.services.displayManager.enable
          then "1"
          else "0";
      }
    );

  };

  greenbootHook =
    name: sub:
    pkgs.writeShellScript name ''
      exec ${bootValidation}/bin/brainrotos-boot-validation ${sub}
    '';

  # PAM session-open hook (pam_exec): a real user (uid >= 1000) logging in
  # marks the generation validated. greeter/system users do not count and
  # session close is ignored. runs as root from the PAM stack.
  pamLoginHook = pkgs.writeShellScript "brainrotos-boot-validation-pam" ''
    if [ "''${PAM_TYPE:-}" != "open_session" ]; then
      exit 0
    fi
    uid=$(${pkgs.coreutils}/bin/id -u "''${PAM_USER:-}" 2>/dev/null) || exit 0
    if [ "$uid" -lt 1000 ]; then
      exit 0
    fi
    exec ${bootValidation}/bin/brainrotos-boot-validation on-success
  '';

  # greenboot runs on every `nixos-rebuild switch` (switch-to-configuration
  # starts newly wanted units); the healthcheck must only run once per boot,
  # otherwise an unbooted generation gets marked good at switch time
  healthcheckCondition = pkgs.writeShellScript "brainrotos-boot-healthcheck-condition" ''
    dir=/run/brainrotos-boot-validation
    current=$(cat /proc/sys/kernel/random/boot_id)
    if [ -f "$dir/boot-id" ] && [ "$(cat "$dir/boot-id")" = "$current" ]; then
      echo "greenboot healthcheck already ran during this boot; skipping"
      exit 1
    fi
    mkdir -p "$dir"
    echo "$current" > "$dir/boot-id"
  '';
in
{
  options = {
    brainrotos.boot-validation.v1 = {
      enable = mkOption {
        type = bool;
        default = true;
        description = "Enable boot validation.";
      };

      attempts = mkOption {
        type = int;
        default = 3;
        description = ''
          How many boots a broken generation gets before falling back to
          the previous one (the first boot plus retries).
        '';
      };

      desktopGraceSec = mkOption {
        type = int;
        default = 300;
        description = ''
          How long to wait for graphical.target and the display manager to
          come up before declaring a boot failed. This is machine startup
          time, not time for a user to log in: a machine whose desktop is
          up never fails validation, no matter when (or whether) someone
          logs in.
        '';
      };

      validatedLogins = mkOption {
        type = listOf str;
        default = [
          "login"
          "gdm-password"
          "gdm-autologin"
          "sddm"
          "sddm-autologin"
          "lightdm"
          "sshd"
        ];
        description = ''
          PAM services whose session open marks a generation as validated
          (last good). Entries for services that do not exist are inert.
        '';
      };

      extraRequiredChecks = mkOption {
        type = listOf package;
        default = [ ];
        description = ''
          Extra healthcheck scripts dropped into
          /etc/greenboot/check/required.d. A failing check marks the boot
          failed immediately.
        '';
      };
    };
  };

  config = mkMerge [
    (mkIf enabled {
      assertions = [
        {
          assertion = cfg.attempts >= 2;
          message = "brainrotos.boot-validation.v1.attempts must be at least 2";
        }
        {
          assertion = cfg.desktopGraceSec >= 30;
          message = "brainrotos.boot-validation.v1.desktopGraceSec must be at least 30";
        }
        {
          assertion = !useGrub || config.boot.loader.grub.configurationLimit >= 2;
          message = "boot.loader.grub.configurationLimit must keep at least 2 generations for boot validation fallback";
        }
        {
          assertion =
            !useSystemdBoot
            || config.boot.loader.systemd-boot.configurationLimit == null
            || config.boot.loader.systemd-boot.configurationLimit >= 2;
          message = "boot.loader.systemd-boot.configurationLimit must keep at least 2 generations for boot validation fallback";
        }
      ];

      environment.etc = {
        "greenboot/greenboot.conf".text = ''
          GREENBOOT_MAX_BOOT_ATTEMPTS=${toString cfg.attempts}
        '';
        # tier 1 success hook: re-asserts fallback steering before
        # greenboot clears the boot counter
        "greenboot/green.d/10-fallback-steer".source =
          greenbootHook "10-fallback-steer" "on-green";
        "greenboot/red.d/10-fallback-reboot".source = greenbootHook "10-fallback-reboot" "on-fail";
      }
      // (
        if config.services.displayManager.enable then
          {
            # tier 1: desktop came up. greenboot marks boot_success=1 and
            # clears the retry counter, so an unattended-but-working machine
            # never accumulates failures
            "greenboot/check/required.d/10-desktop-health".source =
              greenbootHook "10-desktop-health" "desktop-health";
          }
        else
          {
            # no desktop to check; keep required.d non-empty so greenboot
            # does not fail its runner. validation then only advances on
            # hard hangs, and logins still record the last good generation
            "greenboot/check/required.d/10-always-ok".source = pkgs.writeShellScript "10-always-ok" ''
              # no display manager configured; nothing to check
              exit 0
            '';
          }
      )
      // listToAttrs (
        map (p: {
          name = "greenboot/check/required.d/50-${p.name}";
          value.source = p;
        }) cfg.extraRequiredChecks
      );

      # tier 2: a real login marks the generation as validated. runs at
      # session open, root-owned so it can update the boot state; optional
      # so this hook can never lock anyone out
      security.pam.services = listToAttrs (
        map (name: {
          inherit name;
          value.rules.session.brainrotos-boot-validation = {
            order = 97;
            control = "optional";
            modulePath = "${config.security.pam.package}/lib/security/pam_exec.so";
            args = [ "${pamLoginHook}" ];
          };
        }) cfg.validatedLogins
      );

      # greenboot writes its status motd on every boot
      systemd.tmpfiles.rules = [ "d /etc/motd.d 0755 root root - -" ];

      systemd.services.brainrotos-boot-prepare = {
        description = "BrainrotOS Boot Validation Prepare";
        wantedBy = [ "multi-user.target" ];
        before = [ "greenboot-healthcheck.service" ];
        unitConfig.RequiresMountsFor = [ "/boot" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${bootValidation}/bin/brainrotos-boot-validation prepare";
        };
      };

      # the healthcheck itself must NOT be a dependency of multi-user (or
      # any boot target): it blocks for up to desktopGraceSec waiting for
      # the desktop, and graphical.target requires multi-user - the boot
      # would deadlock until the grace timeout. a trigger unit kicks it
      # off unblocked instead.
      systemd.services.greenboot-healthcheck-trigger = {
        description = "Kick off Greenboot Health Checks without blocking boot";
        wantedBy = [ "multi-user.target" ];
        after = [ "brainrotos-boot-prepare.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${pkgs.systemd}/bin/systemctl start --no-block greenboot-healthcheck.service";
        };
      };

      systemd.services.greenboot-healthcheck = {
        description = "Greenboot Health Checks Runner";
        # still required by boot-complete.target for opt-in consumers, but
        # nothing in the default boot pulls boot-complete in
        requiredBy = [ "boot-complete.target" ];
        before = [ "boot-complete.target" ];
        after = [ "brainrotos-boot-prepare.service" ];
        unitConfig.RequiresMountsFor = [
          "/boot"
          "/etc"
        ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecCondition = "${healthcheckCondition}";
          ExecStart = "${greenboot}/bin/greenboot health-check";
          PrivateMounts = true;
        };
        path = [
          greenboot
          pkgs.grub2
          pkgs.bash
          pkgs.coreutils
          pkgs.systemd
          # greenboot shells out to findmnt/mount for its /boot rw handling
          pkgs.util-linux
        ];
      };

      # purely opt-in: services that need "boot validated" ordering can
      # want this themselves. it must not be pulled into the default boot -
      # it requires boot-complete.target which waits for the healthcheck
      systemd.targets.greenboot-success = {
        description = "GreenBoot Healthcheck Success Target";
        requires = [ "boot-complete.target" ];
        after = [
          "greenboot-healthcheck.service"
          "boot-complete.target"
        ];
      };

      # manual escape hatch: stage a boot into a specific generation
      environment.systemPackages = [
        (pkgs.writeShellScriptBin "brainrotos-rollback" ''
          exec ${bootValidation}/bin/brainrotos-boot-validation rollback "$@"
        '')
      ];

    })

    # cycle reset at bootloader-update time: when a newer generation is
    # activated (switch AND boot), steering for a rolled-back generation
    # must be cleared, or the boot after a rebuild would go to the stale
    # fallback. this is the only hook that fires in both switch and boot
    # modes - activation scripts miss boot mode, and the prepare unit
    # misses the reboot right after a boot-mode rebuild.
    (mkIf (enabled && useGrub) {
      boot.loader.grub.extraConfig = grubCountingSnippet;
      boot.loader.grub.extraPrepareConfig = ''
        if ${pkgs.util-linux}/bin/mountpoint -q /boot; then
          ${bootValidation}/bin/brainrotos-boot-validation reset-cycle || true
        fi
      '';
    })

    (mkIf (enabled && useSystemdBoot) {
      boot.loader.systemd-boot.extraInstallCommands = ''
        if ${pkgs.util-linux}/bin/mountpoint -q ${config.boot.loader.efi.efiSysMountPoint}; then
          ${bootValidation}/bin/brainrotos-boot-validation reset-cycle || true
        fi
      '';
    })
  ];
}
