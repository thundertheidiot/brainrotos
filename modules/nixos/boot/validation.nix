{
  config,
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
      systemd.services.reactivation-test = {
        description = "test reactivation service";
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
    })
  ];
}
