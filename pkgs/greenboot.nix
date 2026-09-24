{
  fetchFromGitHub,
  rustPlatform,
  grub2,
  lib,
}:
rustPlatform.buildRustPackage (finalAttrs: {
  pname = "greenboot";
  version = "0.16.4";

  src = fetchFromGitHub {
    owner = "fedora-iot";
    repo = "greenboot-rs";
    tag = "v${finalAttrs.version}";
    hash = "sha256-N78cP19LNio/kUmiRYwRUAnm/M3lfKRtvQmzvguS1Dc=";
  };

  # upstream doesn't ship a Cargo.lock; one is generated once and pinned
  # here (greenboot.Cargo.lock) for reproducible vendoring
  cargoLock.lockFile = ./greenboot.Cargo.lock;

  # nixos: grub ships its env file at /boot/grub/grubenv and the tool is
  # called grub-editenv, not grub2-editenv like on fedora
  postPatch = ''
    cp ${./greenboot.Cargo.lock} Cargo.lock
    substituteInPlace src/lib/grub.rs \
      --replace-fail "/boot/grub2/grubenv" "/boot/grub/grubenv" \
      --replace-fail "grub2-editenv" "grub-editenv"
  '';

  # unit tests poke a fake grubenv through grub-editenv (hence grub2 in
  # nativeCheckInputs), but the script-runner tests hardcode /usr/lib and
  # /etc paths that need root — same reason fedora builds without checks
  doCheck = false;
  nativeCheckInputs = [ grub2 ];
})
