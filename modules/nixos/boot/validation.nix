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
    ;
  inherit (lib.attrsets) listToAttrs;

  cfg = config.brainrotos.boot-validation.v1;

  useGrub = config.boot.loader.grub.enable;
  useSystemdBoot = config.boot.loader.systemd-boot.enable;
  enabled = cfg.enable && (useGrub || useSystemdBoot);

  greenboot = pkgs.callPackage ../../../pkgs/greenboot.nix { };

  grubenvFile = "/boot/grub/grubenv";
  loaderConfFile = "${config.boot.loader.efi.efiSysMountPoint}/loader/loader.conf";

  bootLoader = if useGrub then "grub" else "systemd-boot";

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
    ];

    text = pkgs.replaceVars ./boot-validation.sh {
      inherit (cfg) attempts;
      timeout = cfg.loginTimeoutSec;
      inherit bootLoader;
      grubenv = grubenvFile;
      loaderConf = loaderConfFile;
    };
  };

  greenbootHook =
    name: sub:
    pkgs.writeShellScript name ''
      exec ${bootValidation}/bin/brainrotos-boot-validation ${sub}
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
          Number of failed boots before falling back to the previous
          generation. The failing generation is booted once plus this many
          retries (greenboot semantics).
        '';
      };

      loginTimeoutSec = mkOption {
        type = int;
        default = 300;
        description = ''
          How long to wait for a user login before declaring a boot failed.
          GDM starting is not success; a login is.
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
          assertion = cfg.attempts >= 1;
          message = "brainrotos.boot-validation.v1.attempts must be at least 1";
        }
        {
          assertion = cfg.loginTimeoutSec >= 30;
          message = "brainrotos.boot-validation.v1.loginTimeoutSec must be at least 30";
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
        "greenboot/check/required.d/10-user-login".source = greenbootHook "10-user-login" "login-watchdog";
        "greenboot/green.d/10-record-last-good".source = greenbootHook "10-record-last-good" "on-success";
        "greenboot/red.d/10-fallback-reboot".source = greenbootHook "10-fallback-reboot" "on-fail";
      }
      // listToAttrs (
        map (p: {
          name = "greenboot/check/required.d/50-${p.name}";
          value.source = p;
        }) cfg.extraRequiredChecks
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

      systemd.services.greenboot-healthcheck = {
        description = "Greenboot Health Checks Runner";
        wantedBy = [ "multi-user.target" ];
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
        ];
      };

      systemd.targets.greenboot-success = {
        description = "GreenBoot Healthcheck Success Target";
        wantedBy = [ "multi-user.target" ];
        requires = [ "boot-complete.target" ];
        after = [
          "greenboot-healthcheck.service"
          "boot-complete.target"
        ];
      };
    })

    (mkIf (enabled && useGrub) {
      boot.loader.grub.extraConfig = grubCountingSnippet;
    })
  ];
}
