{
  inputs,
  lib,
  config,
  ...
}:
{
  systems = [
    "x86_64-linux"
  ];

  imports = [
    ./install.nix
    ./vm.nix
  ];

  perSystem = { pkgs, ... }: {
    packages.br = pkgs.callPackage ../../pkgs/br.nix { };
    packages.greenboot = pkgs.callPackage ../../pkgs/greenboot.nix { };
    packages.boot-validation = pkgs.callPackage ../../pkgs/boot-validation.nix { };
    devShells.default = pkgs.mkShell {
      packages = with pkgs; [
        cargo
        clippy
        python3
        shellcheck
        nixfmt
        rustc
        rustfmt
      ];
    };
  };

  flake.nixosConfigurations =
    let
      inherit (builtins) readDir;
      inherit (lib.strings) removeSuffix;
      inherit (lib.attrsets) mapAttrs';

      getName = rec {
        regular = name: removeSuffix ".nix" name;

        directory = name: name;

        symlink = regular;
        unknown = name: throw "${name} is of file type unknown, aborting";
      };
    in
    mapAttrs' (n: v: {
      name = getName.${v} n;
      value = inputs.nixpkgs.lib.nixosSystem {
        modules = [
          ({ pkgs, ... }: {
            # i'm sorry isabel
            _module.args.multiverse = inputs.multiverse.lib.mkMultiverse {
              system = pkgs.stdenv.hostPlatform.system;
              fastFallback = "eval";
            };
          })
          ({ pkgs, ... }: {
            environment.systemPackages = [ inputs.self.packages.${pkgs.system}.br ];
            environment.etc."br/source.json".text = builtins.toJSON {
              source = inputs.self.sourceInfo.url;
              update_ref = inputs.self.sourceInfo.url;
              source_store_path = inputs.self.outPath;
              configuration = n;
            };
          })
          "${inputs.self.outPath}/modules/nixos"
          "${inputs.self.outPath}/config/${n}"
          inputs.nix-flatpak.nixosModules.nix-flatpak
        ];
      };
    }) (readDir "${inputs.self.outPath}/config");
}
