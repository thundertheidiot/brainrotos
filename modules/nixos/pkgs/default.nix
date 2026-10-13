# support easy custom package installation
{
  multiverse,
  lib,
  pkgs,
  config,
  ...
}:
let
  inherit (builtins)
    fromJSON
    readFile
    toPath
    pathExists
    ;
  inherit (lib)
    filter
    isAttrs
    isString
    mkOption
    ;

  inherit (lib.types) path;

  packageFile = config.brainrotos.packages.v1.filePath;
  data = if pathExists packageFile then (fromJSON (readFile packageFile)) else [ ];

  mkRetroApp =
    pkg:
    let
      package = multiverse.fast.version pkg.name pkg.version;
    in
    if pkg ? "libc" && !pkg.libc then
      package
    else
      pkgs.callPackage ./adapter (
        {
          inherit package;
        }
        // removeAttrs pkg [
          "name"
          "version"
          "libc"
        ]
      );

  plainPackages' = filter isString data;
  versionedPackages' = filter isAttrs data;

  plainPackages = map (pkg: pkgs."${pkg}") plainPackages';
  versionedPackages = map mkRetroApp versionedPackages';

  packages = versionedPackages ++ plainPackages;
in
{
  options = {
    brainrotos.packages.v1.filePath = mkOption {
      type = path;
      # <brainrotos/packages.json> will throw if the file doesn't exist
      default = toPath "${<brainrotos>}/packages.json";
      description = "File path for package file.";
    };
  };

  config = {
    environment.systemPackages = packages;
  };
}
