# Minimal touch GUI: sway, started automatically as user "tablet".
#
# - Windows are tabbed (each one fills the screen, tap the tabs to switch)
# - Top bar buttons: apps (launcher), keyboard (on-screen keyboard),
#   rotate, brightness, close window; battery and clock on the right
# - The screen turns off after 2 minutes; touch it to turn it back on
{
  config,
  lib,
  pkgs,
  ...
}:

let
  output = "DSI-1";

  # Volume buttons: digital volume of the codec (speaker and headphones)
  volume = pkgs.writeShellScript "irulu-volume" ''
    ${pkgs.alsa-utils}/bin/amixer -q -c0 set "AIF1 DA0" "$1"
    # Tell the bar to redraw (the timeout in case it isn't running)
    ${pkgs.coreutils}/bin/timeout 1 sh -c 'echo > "$XDG_RUNTIME_DIR/irulu-bar"'
  '';

  # i3bar protocol: blocks with names, taps come back on stdin as JSON
  # lines ("click_events"). Swaybar turns a tap into a button 1 click.
  bar = pkgs.writeShellScript "irulu-bar" ''
    export PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.procps
        pkgs.alsa-utils
        pkgs.brightnessctl
        config.programs.sway.package
      ]
    }

    block() { printf '{"name":"%s","full_text":" %s ","separator_block_width":8}' "$1" "$2"; }
    status() {
      bat=$(cat /sys/class/power_supply/axp20x-battery/capacity)
      case $(cat /sys/class/power_supply/axp20x-battery/status) in
        Charging) bat="$bat%+" ;;
        *) bat="$bat%" ;;
      esac
      printf '[%s,%s,%s,%s,%s,%s,%s,%s],\n' \
        "$(block apps "☰ Apps")" \
        "$(block kbd "⌨")" \
        "$(block rotate "⟳")" \
        "$(block light "☀ $(brightnessctl -m | cut -d, -f4)")" \
        "$(block close "✕")" \
        "$(block vol "♪ $(amixer -c0 get "AIF1 DA0" | grep -o -m1 '[0-9]*%')")" \
        "$(block bat "$bat")" \
        "$(block clock "$(date +%H:%M)")"
    }

    echo '{"version":1,"click_events":true}'
    echo '['
    status

    # Redraw every 20 s, or when something writes to the FIFO
    fifo=$XDG_RUNTIME_DIR/irulu-bar
    rm -f "$fifo"
    mkfifo "$fifo"
    exec 3<>"$fifo"
    while true; do
      read -r -t 20 -u 3 _
      status
    done &
    trap 'kill $!' EXIT

    # The tap reader must stay in the foreground: a background job's stdin
    # is /dev/null in a script. Events look like { "name": "apps", ... }.
    while read -r ev; do
      case ''${ev// /} in
        *'"name":"apps"'*) swaymsg -q exec fuzzel ;;
        *'"name":"kbd"'*) pkill -RTMIN -x wvkbd-mobintl ;;
        *'"name":"rotate"'*) swaymsg -q output ${output} transform 90 clockwise ;;
        *'"name":"light"'*)
          # 100% -> 50% -> 15% -> 100%
          case $(brightnessctl -m | cut -d, -f4) in
            100%) brightnessctl -q set 50% ;;
            5?%|4?%) brightnessctl -q set 15% ;;
            *) brightnessctl -q set 100% ;;
          esac ;;
        *'"name":"close"'*) swaymsg -q kill ;;
      esac
      status
    done
  '';

  swayConfig = pkgs.writeText "sway-config" ''
    # 800x1280 at about 190 dpi: scale up for finger-sized targets
    output ${output} scale 1.5
    input type:touch map_to_output ${output}

    font pango:DejaVu Sans 11
    workspace_layout tabbed
    default_border none
    hide_edge_borders --i3 both
    focus_on_window_activation focus

    bar {
      position top
      font pango:DejaVu Sans 14
      status_command ${bar}
      workspace_buttons no
      status_padding 6
      colors {
        background #202020
        statusline #ffffff
      }
    }

    # On-screen keyboard, hidden until the ⌨ button is tapped
    exec wvkbd-mobintl --hidden -H 250 -L 200
    exec swayidle -w \
      timeout 120 'swaymsg "output * power off"' \
      resume 'swaymsg "output * power on"'
    exec foot

    bindsym --locked XF86AudioRaiseVolume exec ${volume} 5%+
    bindsym --locked XF86AudioLowerVolume exec ${volume} 5%-

    # For a USB keyboard
    bindsym Mod4+Return exec foot
    bindsym Mod4+d exec fuzzel
    bindsym Mod4+q kill
    bindsym Mod4+Shift+e exit
  '';
in
{
  users.users.tablet = {
    isNormalUser = true;
    extraGroups = [
      "video"
      "input"
      "audio"
      "wheel"
    ];
    initialPassword = "irulu";
  };

  programs.sway = {
    enable = true;
    xwayland.enable = false;
    extraPackages = with pkgs; [
      foot
      fuzzel
      wvkbd
      swayidle
      brightnessctl
    ];
  };
  environment.etc."sway/config".source = lib.mkForce swayConfig;

  # Log in automatically; if sway exits, it is started again
  services.greetd = {
    enable = true;
    settings = rec {
      initial_session = {
        command = "sway";
        user = "tablet";
      };
      default_session = initial_session;
    };
  };

  # Backlight access for brightnessctl (group video)
  services.udev.packages = [ pkgs.brightnessctl ];
  fonts.enableDefaultPackages = true;

  environment.etc."xdg/foot/foot.ini".text = ''
    font=DejaVu Sans Mono:size=10
  '';
  environment.etc."xdg/fuzzel/fuzzel.ini".text = ''
    [main]
    font=DejaVu Sans:size=16
    lines=10
    width=30
    icons-enabled=no
    terminal=foot -e
  '';
}
