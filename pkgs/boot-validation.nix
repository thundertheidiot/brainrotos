{
  lib,
  runCommand,
  shellcheck,
  writeShellApplication,
  replaceVars,
  coreutils,
  gawk,
  gnugrep,
  gnused,
  grub2,
  systemd,
  util-linux,
  loader ? "systemd-boot",
  attempts ? 3,
  timeout ? 300,
  grubenv ? "/boot/brainrotos.grubenv",
  legacyGrubenv ? "/boot/greenboot.grubenv",
  loaderConf ? "/boot/loader/loader.conf",
  entriesDir ? "/boot/loader/entries",
  distroName ? "NixOS",
}:
let
  sourceDir = ../modules/nixos/boot;
  loaderLib =
    runCommand "boot-validation-${loader}-lib"
      {
        nativeBuildInputs = [ shellcheck ];
      }
      ''
        install -Dm555 ${sourceDir + "/boot-validation-${loader}.sh"} $out
        shellcheck --exclude=SC2154 $out
      '';
in
assert lib.elem loader [
  "grub"
  "systemd-boot"
];
writeShellApplication {
  name = "brainrotos-boot-validation";
  runtimeInputs = [
    coreutils
    gawk
    gnugrep
    gnused
    grub2
    systemd
    util-linux
  ];
  text = lib.readFile (
    replaceVars (sourceDir + "/boot-validation.sh") {
      inherit
        attempts
        timeout
        grubenv
        legacyGrubenv
        loaderConf
        entriesDir
        ;
      distroName = lib.escapeShellArg distroName;
      loaderLib = "${loaderLib}";
    }
  );
}
