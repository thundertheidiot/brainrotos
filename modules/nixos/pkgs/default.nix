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
    pathExists
    ;
  inherit (lib)
    attrByPath
    hasAttrByPath
    filter
    isAttrs
    isString
    mkOption
    splitString
    ;

  inherit (lib.types) nullOr path;

  packageFile = config.brainrotos.packages.v1.filePath;
  data =
    if packageFile != null && pathExists packageFile then (fromJSON (readFile packageFile)) else [ ];

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

  # supports dotted attribute paths such as kdePackages.kate
  resolvePlain =
    pkg:
    let
      attrPath = splitString "." pkg;
    in
    if !hasAttrByPath attrPath pkgs then
      throw "brainrotos: package '${pkg}' listed in the package file does not exist in nixpkgs"
    else
      attrByPath attrPath null pkgs;

  plainPackages = map resolvePlain plainPackages';
  versionedPackages = map mkRetroApp versionedPackages';

  packages = versionedPackages ++ plainPackages;
in
{
  options = {
    brainrotos.packages.v1.filePath = mkOption {
      type = nullOr path;
      # only evaluated when the option isn't overridden, which requires
      # impure evaluation, null means no managed package file
      default = <brainrotos> + "/packages.json";
      description = "File path for package file, null for no managed packages.";
    };
  };

  config = {
    environment.systemPackages = packages;
  };
}
