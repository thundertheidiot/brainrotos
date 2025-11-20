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

  cfg = config.brainrotos.ramcache.v1;
in {
  options = {
    brainrotos.ramcache.v1 = {
      enable = mkOption {
        type = bool;
        default = true;
        description = "Enable caching of frequenty used programs to ram on boot.";
      };
      paths = mkOption {
        apply = map toString;
        default = [];
        description = "Paths to cache.";
      };
    };
  };

  config = mkIf cfg.enable {
    systemd.services."brainrotos-ram-cache" = {
      enable = true;
      wantedBy = ["graphical.target"];
      path = [pkgs.vmtouch];
      script = ''
        vmtouch -vltf ${concatStringsSep " " cfg.paths}
      '';
    };
  };
}
