{
  lib,
  config,
  pkgs,
  ...
}: let
  inherit (lib) mkIf;
  inherit (lib.options) mkOption;
  inherit (lib.types) bool;
  inherit (lib.strings) concatStringsSep;
  inherit (builtins) toString;

  cfg = config.brainrotos.ramcache;
in {
  options = {
    brainrotos.ramcache.enable.v1 = mkOption {
      type = bool;
      default = true;
      description = "Enable caching of frequenty used programs to ram on boot.";
    };

    brainrotos.ramcache.paths.v1 = mkOption {
      apply = map toString;
      default = [];
      description = "Paths to cache.";
    };
  };

  config = mkIf cfg.enable.v1 {
    systemd.services."brainrotos-ram-cache" = {
      enable = true;
      wantedBy = ["graphical.target"];
      path = [pkgs.vmtouch];
      script = ''
        vmtouch -vltf ${concatStringsSep " " cfg.paths.v1}
      '';
    };
  };
}
