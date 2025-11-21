{
  lib,
  config,
  ...
}: let
  inherit (lib) mkIf mkForce;
  inherit (lib.options) mkOption;
  inherit (lib.types) bool;

  cfg = config.brainrotos.security.v1;
in {
  options = {
    brainrotos.security.v1.enable = mkOption {
      type = bool;
      default = true;
      description = "Harden system.";
    };
  };

  config = mkIf cfg.enable {
    security.sudo.enable = mkForce false;
    security.sudo-rs = {
      enable = true;
      execWheelOnly = true;

      extraConfig = ''
        Defaults pwfeedback
      '';
    };

    security.polkit.enable = true;

    # https://github.com/isabelroses/dotfiles/blob/main/modules/nixos/kernel/params.nix
  };
}
