{
  inputs,
  lib,
  config,
  ...
}: {
  systems = [
    "x86_64-linux"
  ];

  flake.nixosConfigurations = let
    inherit (builtins) readDir;
    inherit (lib.strings) removeSuffix;
    inherit (lib.attrsets) mapAttrs';

    getName = rec {
      regular = name:
        removeSuffix ".nix" name;

      directory = name: name;

      symlink = regular;
      unknown = name: throw "${name} is of file type unknown, aborting";
    };
  in
    mapAttrs' (n: v: {
      name = getName.${v} n;
      value = inputs.nixpkgs.lib.nixosSystem {
        modules = [
          "${inputs.self.outPath}/modules/nixos"
          "${inputs.self.outPath}/config/${n}"
          inputs.nix-flatpak.nixosModules.nix-flatpak
        ];
      };
    }) (readDir "${inputs.self.outPath}/config");
}
