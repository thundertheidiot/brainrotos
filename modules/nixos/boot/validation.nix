{
  config,
  pkgs,
  lib,
  ...
}: let
  inherit (lib) mkDefault mkIf mkMerge;
  inherit (lib.options) mkOption;
  inherit (lib.types) bool;

  cfg = config.brainrotos.boot-validation.v1;
in {
  options = {
    brainrotos.boot-validation.v1.enable = mkOption {
      type = bool;
      default = true;
      description = "Enable boot validation.";
    };
  };

  config = mkMerge [
    (mkIf (cfg.enable) {
      systemd.services.brainrotos-boot-validation-new-generation = {
        description = "Mark new generation as untrusted";
        requiredBy = ["sysinit-reactivation.target"];
        before = ["sysinit-reactivation.target"];

        unitConfig = {
          ConditionPathExists = ["/run/current-system" "/run/booted-system"];
        };

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };

        script = ''
          echo "System activated at $(date)"
        '';

        restartIfChanged = true;
      };

      systemd.services.brainrotos-bless-boot = {
        description = "Bless current generation";
        requires = ["boot-complete.target"];
        after = ["boot-complete.target"];
        wantedBy = ["multi-user.target"];

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };

        script = ''
          echo "Fake boot blessed"
        '';
      };

      systemd.services.brainrotos-boot-check-validity = {
        description = "Mark booted generation as blessed";
        requiredBy = ["boot-complete.target"];
        before = ["boot-complete.target"];
        after = ["graphical.target" "display-manager.service"];

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };

        path = with pkgs; [jq systemd];

        script = ''
          while :; do
            if [ ! -z "$(loginctl list-sessions -j | jq '.[] | select(.seat != null) | select(.tty != null)')" ]; then
              echo "Login successful"
              exit 0
            fi
          done
        '';
      };
    })
  ];
}
