{
  lib,
  config,
  ...
}: let
  inherit (lib) mkIf mkMerge;
  inherit (lib.options) mkOption;
  inherit (lib.types) bool;

  cfg = config.brainrotos.cleanup.v1;
in {
  options = {
    brainrotos.cleanup.v1 = {
      enable = mkOption {
        type = bool;
        default = true;
        description = "Basic system cleanup.";
      };

      accessibility = mkOption {
        type = bool;
        default = true;
        description = "Also disable accessibility tooling.";
      };
    };
  };

  config = mkMerge [
    (mkIf cfg.enable {
      system.tools.nixos-option.enable = false;
    })
    (mkIf (cfg.enable && cfg.accessibility) {
      services.speechd.enable = false;
      services.orca.enable = false;
    })
  ];
}
