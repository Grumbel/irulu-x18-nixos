{ config, lib, pkgs, modulesPath, crossPkgs, ... }:

let
  panelPatch = {
    # JD9365 panel entry for the X18 (non-burst video mode)
    name = "irulu-x18";
    patch = ./patches/0001-drm-panel-jadard-add-iRULU-X18-panel.patch;
  };

  sileadPatch = {
    # GSL touch chip resets mid-transfer on the reset command
    name = "silead-reset-bus-error";
    patch = ./patches/0002-input-silead-tolerate-reset-command-bus-error.patch;
  };

  rtl8723bsPatch = {
    # Module parameter to select the antenna path when the eFuse is empty
    name = "rtl8723bs-ant-path";
    patch = ./patches/0003-staging-rtl8723bs-add-rtw_ant_path-parameter.patch;
  };

  # Lean kernel: only the drivers this tablet needs (kernel/x18-lean.config,
  # generated from kernel/x18-lean.fragment). Builds in minutes.
  leanKernel = crossPkgs.linuxManualConfig {
    inherit (crossPkgs.linux_6_18) src version;
    modDirVersion = "${crossPkgs.linux_6_18.version}-irulu";
    configfile = ./kernel/x18-lean.config;
    kernelPatches = [ panelPatch sileadPatch rtl8723bsPatch ];
  };

  # Fallback: the generic nixpkgs kernel (~7400 modules, slow to build)
  genericKernel = crossPkgs.linux_6_18.override (old: {
    kernelPatches = (old.kernelPatches or [ ]) ++ [ panelPatch sileadPatch rtl8723bsPatch ];
    # The stock nixpkgs aarch64 config already has the A64 display, panel,
    # touch, PMIC, audio, RTL8723BS and MUSB gadget drivers; only Realtek
    # Bluetooth over UART is missing.
    structuredExtraConfig = with lib.kernel; (old.structuredExtraConfig or { }) // {
      BT_HCIUART_RTL = yes;
      BT_HCIUART_3WIRE = yes;
    };
  });

  kernel = leanKernel;

  # The board DTB is built on its own from ./dts, so DT changes don't need a
  # kernel rebuild.
  boardDtbs = crossPkgs.buildPackages.runCommand "irulu-x18-dtbs"
    {
      nativeBuildInputs = with crossPkgs.buildPackages; [ dtc gnutar xz ];
    }
    ''
      tar xf ${kernel.src} --strip-components=1 --wildcards \
        '*/include/dt-bindings' '*/include/uapi/linux/input-event-codes.h' \
        '*/arch/arm64/boot/dts/allwinner' \
        '*/arch/arm64/boot/dts/*.dtsi'
      d=arch/arm64/boot/dts/allwinner
      cp ${./dts/sun50i-a64-irulu-x18.dts} $d/sun50i-a64-irulu-x18.dts
      ${crossPkgs.buildPackages.stdenv.cc}/bin/cpp -nostdinc -undef -D__DTS__ \
        -x assembler-with-cpp -I include -I arch/arm64/boot/dts \
        $d/sun50i-a64-irulu-x18.dts -o x18.pp
      mkdir -p $out/allwinner
      dtc -I dts -O dtb -@ -o $out/allwinner/sun50i-a64-irulu-x18.dtb x18.pp
    '';

  # Only the firmware files this board needs, instead of all of linux-firmware
  boardFirmware = pkgs.runCommand "irulu-x18-firmware" { } ''
    mkdir -p $out/lib/firmware/rtlwifi $out/lib/firmware/rtl_bt $out/lib/firmware/silead
    fw=${pkgs.linux-firmware}/lib/firmware
    cp -L $fw/rtlwifi/rtl8723bs_nic.bin* $out/lib/firmware/rtlwifi/
    cp -L $fw/rtl_bt/rtl8723bs_* $out/lib/firmware/rtl_bt/
    cp ${./firmware/silead/gsl1680-irulu-x18.fw} $out/lib/firmware/silead/gsl1680-irulu-x18.fw
  '';

  uboot = crossPkgs.ubootPine64;
in
{
  imports = [
    "${modulesPath}/installer/sd-card/sd-image.nix"
    "${modulesPath}/profiles/minimal.nix"
  ];

  options.irulu.uboot = lib.mkOption {
    type = lib.types.package;
    default = uboot;
    readOnly = true;
    description = "U-Boot written to the SD card (pine64_plus_defconfig, DDR3 defaults match the X18).";
  };

  config = {
    nixpkgs.hostPlatform = "aarch64-linux";
    system.stateVersion = "26.05";
    networking.hostName = "irulu-x18";

    # --- Boot -------------------------------------------------------------

    boot.kernelPackages = pkgs.linuxPackagesFor kernel;
    hardware.deviceTree.name = "allwinner/sun50i-a64-irulu-x18.dtb";
    hardware.deviceTree.dtbSource = boardDtbs;

    boot.loader.grub.enable = false;
    boot.loader.generic-extlinux-compatible.enable = true;

    # Some of these may be built in, which is fine.
    boot.initrd.allowMissingModules = true;
    boot.initrd.availableKernelModules = [
      "sunxi-mmc"
      "sunxi-rsb"
      "axp20x-rsb"
      "axp20x-regulator"
    ];
    # Load the display stack in the initrd so the console shows up early
    # (there is no serial console without opening the case).
    boot.initrd.kernelModules = [
      "sun4i-drm"
      "sun8i-mixer"
      "sun4i-tcon"
      "sun6i_mipi_dsi"
      "phy-sun6i-mipi-dphy"
      "panel-jadard-jd9365da-h3"
      "pwm-sun4i"
      "pwm_bl"
    ];
    boot.kernelModules = [ "g_ether" ];
    boot.kernelParams = [
      "console=tty0"
      "console=ttyS0,115200n8"
      "loglevel=7"
      "ignore_loglevel"
      "panic=60"
    ];
    boot.consoleLogLevel = 7;

    # Boot logger: without a serial console, early failures leave no trace,
    # so dump dmesg to the FAT partition (readable on any PC) during boot.
    boot.initrd.systemd.extraBin.dmesg = "${pkgs.util-linux}/bin/dmesg";
    boot.initrd.systemd.services.irulu-bootlog = {
      description = "Write dmesg to the FIRMWARE partition";
      wantedBy = [ "initrd.target" ];
      unitConfig.DefaultDependencies = false;
      script = ''
        while [ ! -e /dev/disk/by-label/FIRMWARE ]; do sleep 1; done
        mkdir -p /run/bootlog
        mount -t vfat /dev/disk/by-label/FIRMWARE /run/bootlog
        while true; do
          dmesg > /run/bootlog/dmesg-initrd.txt
          sync
          sleep 2
        done
      '';
    };
    systemd.services.irulu-bootlog = {
      description = "Write dmesg to the FIRMWARE partition for the first minutes";
      wantedBy = [ "sysinit.target" ];
      unitConfig = {
        DefaultDependencies = false;
        RequiresMountsFor = "/boot/firmware";
      };
      path = [ pkgs.util-linux pkgs.coreutils ];
      script = ''
        for i in $(seq 90); do
          dmesg > /boot/firmware/dmesg-stage2.txt
          sync
          sleep 2
        done
      '';
    };

    hardware.firmware = [ boardFirmware ];
    hardware.enableRedistributableFirmware = lib.mkForce false;

    sdImage = {
      compressImage = false;
      # The A64 boot ROM loads SPL from 8 KiB into the card
      postBuildCommands = ''
        dd if=${uboot}/u-boot-sunxi-with-spl.bin of=$img bs=1024 seek=8 conv=notrunc
      '';
      populateFirmwareCommands = ''
        cp ${./wifi.conf.example} firmware/wifi.conf.example
        cp ${./README-SDCARD.txt} firmware/README.txt
      '';
      populateRootCommands = ''
        mkdir -p ./files/boot
        ${config.boot.loader.generic-extlinux-compatible.populateCmd} -c ${config.system.build.toplevel} -d ./files/boot
      '';
    };

    # Mount the FAT partition so wifi.conf can be read and edited
    fileSystems."/boot/firmware".options = lib.mkForce [ "nofail" ];

    # --- Networking -------------------------------------------------------

    networking.useNetworkd = true;
    # Keep the plain wlan0 / usb0 names used below
    networking.usePredictableInterfaceNames = false;
    systemd.network.enable = true;

    # Wi-Fi: no networks are declared, so wpa_supplicant reads
    # /etc/wpa_supplicant/imperative.conf, which is seeded from
    # wifi.conf on the FAT partition.
    # The RTL8723BS-VQ0 module has an empty eFuse (Android loads
    # /system/etc/wifi/wifi_efuse_8723bs_vq0.map instead). Without it the
    # driver picks the wrong antenna path (no TX) and a random MAC.
    # From that map: 0xC3 = 0x51 -> single antenna on S0 (path B).
    # MAC: factory address from the Android "private" partition.
    boot.extraModprobeConfig = ''
      options r8723bs rtw_ant_path=1 rtw_initmac=XX:XX:XX:XX:XX:XX
    '';

    networking.wireless = {
      enable = true;
      interfaces = [ "wlan0" ];
    };
    systemd.services.irulu-wifi-config = {
      description = "Copy wifi.conf from the SD card FAT partition";
      wantedBy = [ "multi-user.target" ];
      before = [ "wpa_supplicant-wlan0.service" "wpa_supplicant.service" ];
      unitConfig.RequiresMountsFor = "/boot/firmware";
      serviceConfig.Type = "oneshot";
      script = ''
        if [ -f /boot/firmware/wifi.conf ]; then
          mkdir -p /etc/wpa_supplicant
          install -m 0664 -o wpa_supplicant -g wpa_supplicant \
            /boot/firmware/wifi.conf /etc/wpa_supplicant/imperative.conf
        fi
      '';
    };
    systemd.network.networks."40-wlan0" = {
      matchConfig.Name = "wlan0";
      networkConfig.DHCP = "yes";
    };

    # USB OTG: plug the tablet into a PC and `ssh root@10.42.0.1`.
    # The PC gets an address via DHCP from the tablet.
    systemd.network.networks."30-usb0" = {
      matchConfig.Name = "usb0";
      address = [ "10.42.0.1/24" ];
      networkConfig.DHCPServer = true;
      dhcpServerConfig = {
        PoolOffset = 100;
        PoolSize = 20;
        EmitDNS = false;
        EmitRouter = false;
      };
    };
    networking.firewall.allowedUDPPorts = [ 67 ];

    # mDNS so it's reachable as irulu-x18.local over Wi-Fi
    services.avahi = {
      enable = true;
      nssmdns4 = true;
      publish = {
        enable = true;
        addresses = true;
      };
    };

    # --- Access -----------------------------------------------------------

    services.openssh = {
      enable = true;
      settings.PermitRootLogin = "prohibit-password";
    };
    users.users.root.openssh.authorizedKeys.keyFiles = [ ./authorized_keys ];
    # Fallback for the on-screen console (touch only; a USB keyboard via OTG
    # adapter works too)
    users.users.root.initialPassword = "irulu";

    # Rotate the console to landscape: fbcon=rotate:1
    # boot.kernelParams = [ "fbcon=rotate:1" ];

    # Mesa: lima (Mali-400 GPU) + kmsro for the display-only sun4i-drm
    hardware.graphics.enable = true;

    environment.systemPackages = with pkgs; [
      (callPackage ./pkgs/sdl2-kms-test { })
      kmscube
      libdrm # modetest
      mesa-demos # eglinfo
      evtest
      i2c-tools
      iw
      wpa_supplicant
      usbutils
      htop
      dtc
    ];

    documentation.enable = false;
    nix.settings.experimental-features = [ "nix-command" "flakes" ];
  };
}
