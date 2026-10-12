# Build the display probe independently of any historical application.
{
  stdenv,
  libGL,
  libx11,
  libglvnd,
  wayland,
}:
stdenv.mkDerivation {
  pname = "glx-probe";
  version = "0.2.0";
  buildInputs = [
    libGL
    libx11
    libglvnd
    wayland
  ];
  dontUnpack = true;

  buildPhase = ''
    runHook preBuild
    $CC -o glx-probe ${./glprobe.c} -lGL -lX11 -lEGL -lwayland-client
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    install -Dm555 glx-probe "$out/bin/glx-probe"
    runHook postInstall
  '';
  meta.mainProgram = "glx-probe";
}
