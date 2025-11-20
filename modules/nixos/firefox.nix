{
  lib,
  config,
  ...
}: let
  inherit (lib) mkIf mkMerge;
  inherit (lib.options) mkOption;
  inherit (lib.types) bool;
  inherit (lib.attrsets) mapAttrs;

  cfg = config.brainrotos.firefox.v1;
in {
  options = {
    brainrotos.firefox.v1.enable = mkOption {
      type = bool;
      default = false;
      description = "Enable firefox.";
    };

    brainrotos.firefox.v1.defaults = mkOption {
      type = bool;
      default = true;
      description = "Firefox settings and extensions.";
    };
  };

  config = mkMerge [
    (mkIf cfg.enable {
      programs.firefox.enable = true;

      brainrotos.ramcache.v1.paths = [
        config.programs.firefox.package
      ];
    })
    (mkIf cfg.defaults {
      programs.firefox.policies = {
        DisableAppUpdate = true;
        DisableTelemetry = true;
        DisableFirefoxStudies = true;

        FirefoxSuggest = {
          WebSuggestions = false;
          SponsoredSuggestions = false;
          ImproveSuggest = false;
        };

        ExtensionSettings =
          mapAttrs (_: v: {
            installation_mode = "force_installed";
            install_url = v;
            private_browsing = true;
          }) {
            "uBlock0@raymondhill.net" = "https://addons.mozilla.org/firefox/downloads/latest/ublock-origin/addon-11423598-latest.xpi";
          };
      };
    })
  ];
}
