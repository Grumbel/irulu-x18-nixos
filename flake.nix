{
  description = "NixOS SD card image for the iRULU X18 tablet (Allwinner A64)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  # Build with `nix build path:.#sdImage` from this directory. A plain `.#`
  # would copy the whole git repository (incl. the multi-GB dump) to the store.
  outputs = { self, nixpkgs }:
    let
      buildSystem = "x86_64-linux";

      # Kernel and U-Boot are cross-compiled (fast), the rest of the system is
      # native aarch64 so it comes from the binary cache (needs binfmt/qemu
      # for the few derivations that are built locally).
      crossPkgs = import nixpkgs {
        localSystem = buildSystem;
        crossSystem = "aarch64-linux";
      };

      system = self.nixosConfigurations.irulu-x18;
    in
    {
      nixosConfigurations.irulu-x18 = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        specialArgs = { inherit crossPkgs; };
        modules = [ ./configuration.nix ];
      };

      packages.${buildSystem} = {
        default = system.config.system.build.sdImage;
        sdImage = system.config.system.build.sdImage;
        toplevel = system.config.system.build.toplevel;
        kernel = system.config.boot.kernelPackages.kernel;
        uboot = system.config.irulu.uboot;
      };
    };
}
