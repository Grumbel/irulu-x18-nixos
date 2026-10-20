# Example system for the SD card image: console, SSH over USB and Wi-Fi,
# a few test tools. Wi-Fi credentials and SSH keys are read from files on
# the card's FAT partition, so the image itself contains nothing personal.
{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:

{
  imports = [
    "${modulesPath}/installer/sd-card/sd-image.nix"
    "${modulesPath}/profiles/minimal.nix"
  ];

  hardware.irulu-x18.enable = true;

  system.stateVersion = "26.05";
  networking.hostName = "irulu-x18";

  boot.kernelModules = [ "g_ether" ]; # USB ethernet on the micro-USB port
  boot.kernelParams = [
    "console=tty0"
    "console=ttyS0,115200n8"
    "loglevel=7"
    "ignore_loglevel"
    "panic=60"
  ];
  boot.consoleLogLevel = 7;
  # Landscape console instead of the panel's native portrait:
  # boot.kernelParams = [ "fbcon=rotate:1" ];

  # --- SD card image ------------------------------------------------------

  sdImage = {
    compressImage = false;
    # The A64 boot ROM loads U-Boot's SPL from 8 KiB into the card
    postBuildCommands = ''
      dd if=${config.system.build.uboot}/u-boot-sunxi-with-spl.bin of=$img bs=1024 seek=8 conv=notrunc
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

  # Mount the FAT partition: wifi.conf, authorized_keys and boot logs
  fileSystems."/boot/firmware".options = lib.mkForce [ "nofail" ];

  # Boot logger: without a serial console, early failures leave no trace,
  # so dmesg is written to the FAT partition (readable on any PC).
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
    path = [
      pkgs.util-linux
      pkgs.coreutils
    ];
    script = ''
      for i in $(seq 90); do
        dmesg > /boot/firmware/dmesg-stage2.txt
        sync
        sleep 2
      done
    '';
  };

  # --- Networking -----------------------------------------------------------

  networking.useNetworkd = true;
  # Keep the plain wlan0 / usb0 names used below
  networking.usePredictableInterfaceNames = false;

  # Wi-Fi: no networks are declared, so wpa_supplicant reads
  # /etc/wpa_supplicant/imperative.conf, copied from wifi.conf on the FAT
  # partition at boot.
  networking.wireless = {
    enable = true;
    interfaces = [ "wlan0" ];
  };
  systemd.services.irulu-wifi-config = {
    description = "Copy wifi.conf from the SD card FAT partition";
    wantedBy = [ "multi-user.target" ];
    before = [
      "wpa_supplicant-wlan0.service"
      "wpa_supplicant.service"
    ];
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

  # USB: connect the micro-USB port to a PC and `ssh root@10.42.0.1`.
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

  # mDNS, so it's reachable as irulu-x18.local over Wi-Fi
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    publish = {
      enable = true;
      addresses = true;
    };
  };

  # --- Access -----------------------------------------------------------------

  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "prohibit-password";
  };
  # SSH public keys from authorized_keys on the FAT partition
  systemd.services.irulu-ssh-keys = {
    description = "Copy authorized_keys from the SD card FAT partition";
    wantedBy = [ "multi-user.target" ];
    before = [ "sshd.service" ];
    unitConfig.RequiresMountsFor = "/boot/firmware";
    serviceConfig.Type = "oneshot";
    script = ''
      if [ -f /boot/firmware/authorized_keys ]; then
        install -d -m 0700 /root/.ssh
        install -m 0600 /boot/firmware/authorized_keys /root/.ssh/authorized_keys
      fi
    '';
  };
  # For logging in on the console (with a USB keyboard on an OTG adapter).
  # Change it with `passwd` after the first login.
  users.users.root.initialPassword = "irulu";

  # --- Tools ------------------------------------------------------------------

  environment.systemPackages = with pkgs; [
    (callPackage ./pkgs/sdl2-kms-test { })
    kmscube
    libdrm # modetest
    mesa-demos # eglinfo
    alsa-utils # amixer, aplay, speaker-test
    evtest
    i2c-tools
    iw
    wpa_supplicant
    usbutils
    htop
    dtc
  ];

  documentation.enable = false;
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];
}
