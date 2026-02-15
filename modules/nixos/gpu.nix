{
  lib,
  config,
  pkgs,
  ...
}: let
  inherit (lib) mkIf mkMerge;
  inherit (lib.options) mkOption;
  inherit (lib.types) enum;

  cfg = config.brainrotos.gpu.v1;
in {
  options = {
    brainrotos.gpu.v1.type = mkOption {
      type = enum ["amd" "nvidia" "nvidia-old" "intel" "custom-no-setup" "none"];
      default = false;
      description = "GPU Drivers to install.";
    };
  };

  config = mkMerge [
    (mkIf (cfg != "none") {
      hardware.graphics.enable = true;
    })
    (mkIf (cfg == "intel") {
      services.xserver.videoDrivers = ["modesetting"];

      hardware.graphics.extraPackages = with pkgs; [
        intel-media-driver
        vpl-gpu-rt
      ];

      environment.sessionVariables = {
        LIBVA_DRIVER_NAME = "iHD";
      };

      hardware.enableRedistributableFirmware = true;
    })
    (mkIf (cfg == "amd") {
      services.xserver.videoDrivers = ["modesetting"];
      boot.initrd.kernelModules = ["amdgpu"];

      hardware.graphics.extraPackages = with pkgs; [
        vulkan-loader
        vulkan-validation-layers
        vulkan-extension-layer
      ];

      environment.systemPackages = [
        pkgs.lact # control panel
        pkgs.nvtopPackages.amd
      ];

      systemd.services.lactd = {
        enable = true;
        description = "Lact daemon";
        wantedBy = ["multi-user.target"];
        after = ["multi-user.target"];
        serviceConfig = {
          ExecStart = "${pkgs.lact}/bin/lact daemon";
          Nice = -10;
        };
      };

      hardware.enableRedistributableFirmware = true;
    })
    (mkIf (cfg == "nvidia") {
      services.xserver.videoDrivers = ["nvidia"];
      hardware.nvidia = {
        package = config.boot.kernelPackages.nvidiaPackages.beta;
        modesetting.enable = true;
        open = true;
        nvidiaSettings = true;
      };
    })
  ];
}
