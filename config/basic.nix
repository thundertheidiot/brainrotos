{...}: {
  imports = [./base.nix];

  config.brainrotos = {
    desktop.plasma.v1 = true;
    impermanence.enable.v1 = true;
  };
}
