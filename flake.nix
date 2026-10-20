{
  description = "NixOS for the iRULU X18 / eXpro X1S tablet (Allwinner A64)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs =
    { self, nixpkgs }:
    let
      buildSystem = "x86_64-linux";
      system = self.nixosConfigurations.irulu-x18;
    in
    {
      # Hardware support, for use in your own configuration
      nixosModules.default = ./modules/irulu-x18.nix;
      nixosModules.irulu-x18 = ./modules/irulu-x18.nix;

      # Example system / SD card image. The userland is native aarch64 and
      # comes from the binary cache; kernel, DTB and U-Boot are
      # cross-compiled on x86_64 (needs binfmt emulation for the few local
      # aarch64 derivations).
      nixosConfigurations.irulu-x18 = nixpkgs.lib.nixosSystem {
        modules = [
          self.nixosModules.default
          ./configuration.nix
          { hardware.irulu-x18.kernelBuildPlatform = buildSystem; }
        ];
      };

      packages.${buildSystem} = {
        default = system.config.system.build.sdImage;
        sdImage = system.config.system.build.sdImage;
        toplevel = system.config.system.build.toplevel;
        kernel = system.config.boot.kernelPackages.kernel;
        uboot = system.config.system.build.uboot;
      };
    };
}
