# crust: firmware for the A64's AR100 (OpenRISC) management core. U-Boot
# loads it into SRAM; TF-A then offers PSCI SYSTEM_SUSPEND ("deep" sleep).
{
  stdenv,
  fetchFromGitHub,
  buildPackages,
  or1kPkgs,
  flex,
  bison,
}:

stdenv.mkDerivation {
  pname = "crust-irulu-x18";
  version = "0.6-unstable-2024-02-08";

  src = fetchFromGitHub {
    owner = "crust-firmware";
    repo = "crust";
    rev = "499a362645e6ce6ac1fd8ea8d0f25d4df6690688";
    hash = "sha256-NNp5K4YbfCkgJzaH3IokJHZICXGAepzSTxuIagJc/G4=";
  };

  depsBuildBuild = [ buildPackages.stdenv.cc ];
  nativeBuildInputs = [
    # Freestanding build: the libc-less compiler is enough (newlib for
    # or1k does not build with GCC 15)
    or1kPkgs.buildPackages.gccWithoutTargetLibc
    flex
    bison
  ];

  # The PineTab config fits: A64 + AXP803 on RSB, no serial console
  configurePhase = ''
    runHook preConfigure
    make HOST_COMPILE= CROSS_COMPILE=or1k-elf- pinetab_defconfig
    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    make HOST_COMPILE= CROSS_COMPILE=or1k-elf- -j$NIX_BUILD_CORES scp
    runHook postBuild
  '';

  installPhase = ''
    install -Dm644 build/scp/scp.bin $out/scp.bin
  '';

  dontStrip = true;
  hardeningDisable = [ "all" ];
}
