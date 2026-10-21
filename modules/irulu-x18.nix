# Hardware support for the iRULU X18 / "eXpro X1S" tablet (Allwinner A64).
#
# Kernel (lean config + patches), device tree, firmware, U-Boot with crust
# (deep sleep), Wi-Fi/Bluetooth, audio, GPU and power-button handling.
# Enable with `hardware.irulu-x18.enable = true;`.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.hardware.irulu-x18;

  # Packages used to build kernel, DTB and U-Boot. Cross-compiling from a
  # fast build machine is much quicker than building under emulation.
  buildPkgs =
    if cfg.kernelBuildPlatform == null then
      pkgs
    else
      import pkgs.path {
        localSystem = cfg.kernelBuildPlatform;
        crossSystem = pkgs.stdenv.hostPlatform;
      };

  kernelPatches = [
    {
      # JD9365 panel entry (needs non-burst DSI video mode)
      name = "jadard-irulu-x18-panel";
      patch = ../patches/0001-drm-panel-jadard-add-iRULU-X18-panel.patch;
    }
    {
      # The GSL touch chip resets mid-transfer on the reset command
      name = "silead-reset-bus-error";
      patch = ../patches/0002-input-silead-tolerate-reset-command-bus-error.patch;
    }
    {
      # Load the logical eFuse map from a firmware file, like Android does
      name = "rtl8723bs-efuse-file";
      patch = ../patches/0003-staging-rtl8723bs-load-efuse-map-from-firmware-file.patch;
    }
    {
      # Headphone detection: use the codec's own jack detection
      name = "sun8i-codec-headset-jack";
      patch = ../patches/0004-asoc-sun8i-codec-create-headset-jack.patch;
    }
  ];

  # Lean kernel: only the drivers this tablet needs (kernel/x18-lean.config,
  # generated from kernel/x18-lean.fragment). Builds in minutes.
  leanKernel = buildPkgs.linuxManualConfig {
    inherit (buildPkgs.linux_6_18) src version;
    modDirVersion = "${buildPkgs.linux_6_18.version}-irulu";
    configfile = ../kernel/x18-lean.config;
    inherit kernelPatches;
  };

  # The generic nixpkgs kernel (~7400 modules, slow to build)
  genericKernel = buildPkgs.linux_6_18.override (old: {
    kernelPatches = (old.kernelPatches or [ ]) ++ kernelPatches;
    structuredExtraConfig =
      with lib.kernel;
      (old.structuredExtraConfig or { })
      // {
        BT_HCIUART_RTL = yes;
        BT_HCIUART_3WIRE = yes;
      };
  });

  kernel = if cfg.leanKernel then leanKernel else genericKernel;

  # The board DTB is built on its own from dts/, so DT changes don't need a
  # kernel rebuild.
  boardDtbs =
    buildPkgs.buildPackages.runCommand "irulu-x18-dtbs"
      {
        nativeBuildInputs = with buildPkgs.buildPackages; [
          dtc
          gnutar
          xz
        ];
      }
      ''
        tar xf ${kernel.src} --strip-components=1 --wildcards \
          '*/include/dt-bindings' '*/include/uapi/linux/input-event-codes.h' \
          '*/arch/arm64/boot/dts/allwinner' \
          '*/arch/arm64/boot/dts/*.dtsi'
        d=arch/arm64/boot/dts/allwinner
        cp ${../dts/sun50i-a64-irulu-x18.dts} $d/sun50i-a64-irulu-x18.dts
        ${buildPkgs.buildPackages.stdenv.cc}/bin/cpp -nostdinc -undef -D__DTS__ \
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
    cp ${../firmware/silead/gsl1680-irulu-x18.fw} $out/lib/firmware/silead/gsl1680-irulu-x18.fw
    cp ${../firmware/rtl8723bs/rtl8723bs_efuse_irulu_x18.bin} $out/lib/firmware/rtlwifi/rtl8723bs_efuse_irulu_x18.bin
  '';

  crust = buildPkgs.buildPackages.callPackage ../pkgs/crust {
    or1kPkgs = import buildPkgs.path {
      localSystem = buildPkgs.stdenv.buildPlatform;
      crossSystem = buildPkgs.lib.systems.examples.or1k;
    };
  };

  # nixpkgs builds all Allwinner U-Boots with SCP=/dev/null (no crust),
  # which leaves only s2idle. With crust, TF-A offers deep sleep. The
  # Pine64+ defaults (DDR3-1333, 672 MHz, ZQ 0x3b3bbb) match the X18.
  uboot = buildPkgs.ubootPine64.overrideAttrs (old: {
    env = (old.env or { }) // {
      SCP = "${crust}/scp.bin";
    };
  });

  installUboot = pkgs.writeShellApplication {
    name = "irulu-install-uboot";
    runtimeInputs = with pkgs; [
      coreutils
      util-linux
    ];
    text = ''
      img=${uboot}/u-boot-sunxi-with-spl.bin
      dev=/dev/mmcblk0   # microSD (mmc0)
      size=$(stat -c %s "$img")
      first=$(sfdisk -d "$dev" | sed -n 's/.*start= *\([0-9]*\).*/\1/p' | sort -n | head -1)
      if [ $((8192 + size)) -gt $((first * 512)) ]; then
        echo "U-Boot ($size bytes) would overlap the first partition" >&2
        exit 1
      fi
      backup=/root/uboot-backup-$(date +%Y%m%d-%H%M%S).bin
      dd if="$dev" of="$backup" bs=1024 skip=8 count=$((size / 1024 + 1)) status=none
      echo "Backed up current U-Boot area to $backup"
      dd if="$img" of="$dev" bs=1024 seek=8 conv=fsync status=none
      sync
      echo "Wrote $img to $dev"
    '';
  };

  # Without a MAC from the config, derive a stable, locally administered one
  # from /etc/machine-id (the module's own eFuse has no usable MAC).
  r8723bsModprobe = pkgs.writeShellScript "r8723bs-modprobe" ''
    mac=$(${pkgs.coreutils}/bin/sha256sum /etc/machine-id \
      | ${pkgs.gnused}/bin/sed -E 's/^(..)(..)(..)(..)(..).*/02:\1:\2:\3:\4:\5/')
    exec ${pkgs.kmod}/bin/modprobe --ignore-install r8723bs rtw_initmac=$mac "$@"
  '';
in
{
  options.hardware.irulu-x18 = {
    enable = lib.mkEnableOption "support for the iRULU X18 (eXpro X1S) tablet";

    kernelBuildPlatform = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "x86_64-linux";
      description = ''
        Platform to cross-compile kernel, device tree and U-Boot on. null
        builds them natively for aarch64 (slow under emulation).
      '';
    };

    leanKernel = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Use the minimal kernel config for this tablet (builds in minutes)
        instead of the generic nixpkgs kernel.
      '';
    };

    wifiMacAddress = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "02:12:34:56:78:9a";
      description = ''
        MAC address for the Wi-Fi interface. The Wi-Fi module carries no
        usable MAC; Android reads the factory one from its "private"
        partition (ULI/factory/mac.txt). If null, a stable locally
        administered address is derived from /etc/machine-id.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";

    # --- Boot -------------------------------------------------------------

    boot.kernelPackages = pkgs.linuxPackagesFor kernel;
    hardware.deviceTree.name = "allwinner/sun50i-a64-irulu-x18.dtb";
    hardware.deviceTree.dtbSource = boardDtbs;

    boot.loader.grub.enable = false;
    boot.loader.generic-extlinux-compatible.enable = true;
    # U-Boot's menu is only visible on the (internal) serial port and the
    # screen stays dark meanwhile; the default 5 s wait is wasted.
    boot.loader.timeout = lib.mkDefault 1;

    # Some of these may be built in, which is fine.
    boot.initrd.allowMissingModules = true;
    # No TPM on this board; saves tpm2-tss (and its deps) in the initrd
    boot.initrd.systemd.tpm2.enable = lib.mkDefault false;
    boot.initrd.availableKernelModules = [
      "sunxi-mmc"
      "sunxi-rsb"
      "axp20x-rsb"
      "axp20x-regulator"
    ];
    # Load the display stack in the initrd so the console shows up early
    # (there is no serial console without opening the case). The lean
    # kernel has these built in.
    boot.initrd.kernelModules = lib.mkIf (!cfg.leanKernel) [
      "sun4i-drm"
      "sun8i-mixer"
      "sun4i-tcon"
      "sun6i_mipi_dsi"
      "phy-sun6i-mipi-dphy"
      "panel-jadard-jd9365da-h3"
      "pwm-sun4i"
      "pwm_bl"
    ];

    hardware.firmware = [ boardFirmware ];
    hardware.enableRedistributableFirmware = lib.mkForce false;

    # U-Boot lives in the raw area of the SD card (8 KiB offset), which
    # nixos-rebuild doesn't touch; `irulu-install-uboot` writes it.
    system.build.uboot = uboot;
    environment.systemPackages = [ installUboot ];

    # --- Wi-Fi (RTL8723BS-VQ0) --------------------------------------------
    # - rtw_ips_mode=0: with "inactive power save" the driver turns the RF
    #   off while unassociated and associations then fail ~90% of the time
    #   (ASSOC-REJECT status_code=1).
    # - rtw_efuse_file: like Android, replace the chip's eFuse with the
    #   vendor map (wifi_efuse_8723bs_vq0.map, converted to binary): TX
    #   power calibration, antenna on S0/path B (path A doesn't connect at
    #   all), BT coexistence.
    boot.extraModprobeConfig = ''
      options r8723bs rtw_ips_mode=0 rtw_efuse_file=rtlwifi/rtl8723bs_efuse_irulu_x18.bin${
        lib.optionalString (cfg.wifiMacAddress != null) " rtw_initmac=${cfg.wifiMacAddress}"
      }
    ''
    + lib.optionalString (cfg.wifiMacAddress == null) ''
      install r8723bs ${r8723bsModprobe}
    '';

    # --- Bluetooth (RTL8723BS, H5 over UART1) -------------------------------
    hardware.bluetooth = {
      enable = lib.mkDefault true;
      powerOnBoot = lib.mkDefault true;
    };

    # --- Accelerometer (MiraMEMS, DA280-compatible) -------------------------
    # da280 has no OF match table, so udev can't autoload it from the DT node
    boot.kernelModules = [ "da280" ];

    # --- Power ------------------------------------------------------------

    # Tablet behaviour: short press suspends (and wakes), long press powers off
    services.logind.settings.Login = {
      HandlePowerKey = lib.mkDefault "suspend";
      HandlePowerKeyLongPress = lib.mkDefault "poweroff";
    };

    # logind needs the key held for 5 s to see a long press, but the AXP803
    # cuts the power itself after 6 s, which leaves only a 1 s window for a
    # clean poweroff. Move the hardware power-off to the maximum, 10 s.
    services.udev.extraRules = ''
      ACTION=="add|bind", SUBSYSTEM=="platform", DRIVER=="axp20x-pek", ATTR{shutdown}="10000"
    '';

    # After deep sleep wpa_supplicant can stay in its back-off after failed
    # associations; reconnecting from scratch is reliable.
    powerManagement.resumeCommands = lib.mkIf config.networking.wireless.enable ''
      ${pkgs.systemd}/bin/systemctl try-restart 'wpa_supplicant*.service'
    '';

    # --- Audio ------------------------------------------------------------
    # All mixer controls default to muted. Route AIF1 -> DAC -> Line Out
    # (internal speaker amp, PH7) and Headphone.
    systemd.services.irulu-audio-defaults = {
      description = "Set ALSA mixer defaults for the X18 codec";
      wantedBy = [ "sound.target" ];
      after = [ "sound.target" ];
      serviceConfig.Type = "oneshot";
      path = [ pkgs.alsa-utils ];
      script = ''
        for i in $(seq 20); do [ -e /dev/snd/controlC0 ] && break; sleep 1; done
        a="amixer -q -c0 set"
        $a "AIF1 Slot 0 Digital DAC" on
        $a "AIF1 DA0" 80%
        $a "DAC" on
        $a "DAC" 100%
        $a "Line Out" on
        $a "Line Out" 80%
        $a "Headphone Source" DAC
        $a "Headphone" on
        $a "Headphone" 60%
        # Internal microphone: MIC1 -> ADC -> AIF1
        $a "Mic1" cap
        $a "Mic1 Boost" 4
        $a "ADC Gain" 3
        $a "ADC" 160
        $a "AIF1 AD0" 160
        $a "AIF1 Slot 0 Digital ADC" cap
        $a "AIF1 Data Digital ADC" cap
      '';
    };

    # Speaker off while headphones are plugged in (patches/0004 reports
    # the jack as an input switch)
    systemd.services.irulu-headphone-switch = {
      description = "Turn the speaker off while headphones are plugged in";
      wantedBy = [ "multi-user.target" ];
      after = [ "irulu-audio-defaults.service" ];
      path = [
        pkgs.alsa-utils
        pkgs.evtest
        pkgs.coreutils
      ];
      serviceConfig.Restart = "on-failure";
      script = ''
        for i in $(seq 20); do
          for d in /sys/class/input/event*; do
            case $(cat "$d/device/name") in
              *"Headset Jack") dev=/dev/input/''${d##*/} ;;
            esac
          done
          [ -n "''${dev:-}" ] && break
          sleep 1
        done
        [ -n "''${dev:-}" ] || exit 1

        # evtest --query exits with 10 while the switch is set
        update() {
          if evtest --query "$dev" EV_SW SW_HEADPHONE_INSERT; then
            amixer -q -c0 set "Line Out" on
          else
            amixer -q -c0 set "Line Out" off
          fi
        }
        update
        stdbuf -oL evtest "$dev" | while read -r line; do
          case $line in *SW_HEADPHONE_INSERT*) update ;; esac
        done
      '';
    };

    # --- Graphics ---------------------------------------------------------
    # Mesa: lima (Mali-400 GPU) + kmsro for the display-only sun4i-drm
    hardware.graphics.enable = lib.mkDefault true;
  };
}
