{
  stdenv,
  pkg-config,
  SDL2,
  libGL,
}:

stdenv.mkDerivation {
  pname = "sdl2-kms-test";
  version = "0.1";

  src = ./sdl2-kms-test.c;
  dontUnpack = true;

  nativeBuildInputs = [ pkg-config ];
  buildInputs = [
    SDL2
    libGL
  ];

  buildPhase = ''
    $CC -O2 -Wall -o sdl2-kms-test $src $(pkg-config --cflags --libs sdl2 glesv2) -lm
  '';

  installPhase = ''
    install -Dm755 sdl2-kms-test $out/bin/sdl2-kms-test
  '';

  meta.mainProgram = "sdl2-kms-test";
}
