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

  config =
    mkMerge [
    ];
}
