{
  lib,
  config,
  pkgs,
  ...
}: let
  inherit (lib) mkIf;
  inherit (lib.options) mkOption;
  inherit (lib.types) bool listOf oneOf path package str;
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
        type = listOf (oneOf [path package str]);
        apply = map toString;
        default = [];
        description = "Paths to cache.";
      };
    };
  };

  config = mkIf (cfg.enable && cfg.paths != []) {
    systemd.services."brainrotos-ram-cache" = {
      enable = true;
      wantedBy = ["graphical.target"];
      path = [pkgs.vmtouch];
      script = ''
        vmtouch -ltf ${concatStringsSep " " cfg.paths}
      '';
    };
  };
}
