#!/bin/sh
# wifi.sh — POSIX Wi-Fi picker with BSSID, Band, Channel
# Requires: nmcli, awk, nl, cut, tr

set -eu

err() { printf >&2 "Error: %s\n" "$*"; exit 1; }
command -v nmcli >/dev/null 2>&1 || err "nmcli not found. Install network-manager."

# Pick first wifi interface managed by NM
IFACE="$(nmcli -t -f DEVICE,TYPE device status | awk -F: '$2=="wifi"{print $1; exit}')"
[ -n "${IFACE:-}" ] || err "No Wi-Fi interface of TYPE=wifi found."

nmcli radio wifi on >/dev/null 2>&1 || true

TMP="${TMPDIR:-/tmp}/wifi_scan.$$"
trap 'rm -f "$TMP"' EXIT INT HUP TERM

# Derive band from frequency MHz
band_of_freq() {
  f="$1"
  # 2.4 GHz band
  if [ "$f" -ge 2400 ] && [ "$f" -le 2500 ]; then
    echo "2.4"
    return
  fi
  # 5 GHz band (approx ranges)
  if [ "$f" -ge 4900 ] && [ "$f" -le 5895 ]; then
    echo "5"
    return
  fi
  # 6 GHz (Wi-Fi 6E/7)
  if [ "$f" -ge 5925 ] && [ "$f" -le 7125 ]; then
    echo "6"
    return
  fi
  echo "?"
}

scan_networks() {
  # Fields: IN-USE:SSID:BSSID:FREQ:CHAN:SECURITY:SIGNAL
  nmcli -t -f IN-USE,SSID,BSSID,FREQ,CHAN,SECURITY,SIGNAL device wifi list ifname "$IFACE" \
    | awk -F: 'length($2)>0 {print $0}' >"$TMP"
}

print_menu() {
  echo
  printf "Interface: %s\n\n" "$IFACE"
  # Header
  printf "%-4s %-1s %-28s %-17s %-4s %-4s %-12s %s\n" "#" "*" "SSID" "BSSID" "Band" "Ch" "SECURITY" "SIGNAL"
  printf "%-4s %-1s %-28s %-17s %-4s %-4s %-12s %s\n" "----" "-" "----------------------------" "-----------------" "----" "----" "------------" "------"
  i=0
  while IFS=: read -r inuse ssid bssid freq chan sec sig; do
    i=$((i+1))
    [ -n "$sec" ] || sec="--"
    [ -n "$sig" ] || sig="0"
    [ -n "$chan" ] || chan="--"
    [ -n "$freq" ] || freq=0
    star=""
    [ "$inuse" = "*" ] && star="*"
    band="$(band_of_freq "$freq")"
    ssid_disp=$(printf "%s" "$ssid" | cut -c1-28)
    printf "%-4s %-1s %-28s %-17s %-4s %-4s %-12s %s\n" "$i" "$star" "$ssid_disp" "$bssid" "$band" "$chan" "$sec" "$sig"
  done <"$TMP"
  echo
  echo "[C] Connect (hidden SSID)   [D] Disconnect current   [R] Rescan   [Q] Quit"
  echo "Pick a number to connect to that exact AP (by BSSID)."
}

disconnect_now() {
  active_id="$(nmcli -t -f NAME,TYPE,DEVICE connection show --active \
    | awk -F: -v ifc="$IFACE" '$2=="wifi" && $3==ifc{print $1; exit}')"
  if [ -n "${active_id:-}" ]; then
    echo "Disconnecting \"$active_id\" on $IFACE…"
    nmcli connection down id "$active_id" >/dev/null 2>&1 || nmcli device disconnect "$IFACE" >/dev/null 2>&1 || true
    echo "✅ Disconnected."
  else
    echo "No active Wi-Fi connection on $IFACE."
  fi
}

connect_to() {
  ssid="$1"
  bssid="$2"
  sec="$3"
  echo
  echo "Connecting to SSID: $ssid (AP $bssid)"
  if [ "$sec" = "--" ] || [ "$sec" = "NONE" ]; then
    nmcli device wifi connect "$ssid" ifname "$IFACE" bssid "$bssid" || err "Connect failed."
  else
    # Try without password first (enterprise/pre-config)
    if ! nmcli -w 10 device wifi connect "$ssid" ifname "$IFACE" bssid "$bssid" >/dev/null 2>&1; then
      printf "Wi-Fi password for \"%s\": " "$ssid" >/dev/tty
      stty -echo </dev/tty 2>/dev/null || true
      IFS= read -r pass </dev/tty || pass=""
      stty echo </dev/tty 2>/dev/null || true
      echo
      nmcli device wifi connect "$ssid" ifname "$IFACE" bssid "$bssid" password "$pass" || err "Connect failed."
    fi
  fi
  echo "✅ Connected."
}

while :; do
  scan_networks
  if [ ! -s "$TMP" ]; then
    echo "No networks found. Rescanning…"
    nmcli device wifi rescan ifname "$IFACE" >/dev/null 2>&1 || true
    sleep 2
    scan_networks
  fi

  print_menu

  printf "Select # / C / D / R / Q: "
  IFS= read -r choice
  case $(printf "%s" "$choice" | tr '[:upper:]' '[:lower:]') in
    q) echo "Bye."; exit 0 ;;
    r)
      echo "Rescanning…"
      nmcli device wifi rescan ifname "$IFACE" >/dev/null 2>&1 || true
      sleep 1
      ;;
    d)
      disconnect_now
      printf "Press Enter to continue…"; IFS= read -r _ ;;
    c)
      printf "Enter SSID (exact, case-sensitive): "
      IFS= read -r manual_ssid
      [ -z "$manual_ssid" ] && continue
      printf "Security (press Enter if unknown): "
      IFS= read -r sec_hint
      [ -z "$sec_hint" ] && sec_hint="WPA-PSK"
      # For hidden, we can’t choose a specific AP—let NM pick
      echo "Connecting to hidden SSID: $manual_ssid"
      if ! nmcli -w 10 device wifi connect "$manual_ssid" ifname "$IFACE" >/dev/null 2>&1; then
        printf "Wi-Fi password for \"%s\": " "$manual_ssid" >/dev/tty
        stty -echo </dev/tty 2>/dev/null || true
        IFS= read -r pass </dev/tty || pass=""
        stty echo </dev/tty 2>/dev/null || true
        echo
        nmcli device wifi connect "$manual_ssid" ifname "$IFACE" password "$pass" || err "Connect failed."
      fi
      echo "✅ Connected."
      printf "Press Enter to continue…"; IFS= read -r _ ;;
    *)
      # numeric selection → pick that line
      case "$choice" in *[!0-9]*|"") echo "Invalid choice."; sleep 1; continue ;; esac
      sel="$(nl -ba "$TMP" | awk -v n="$choice" '$1==n{ $1=""; sub(/^ *\t?/,""); print; exit }')"
      [ -n "${sel:-}" ] || { echo "Invalid number."; sleep 1; continue; }
      inuse=$(printf "%s" "$sel" | awk -F: '{print $1}')
      ssid=$( printf "%s" "$sel" | awk -F: '{print $2}')
      bssid=$(printf "%s" "$sel" | awk -F: '{print $3}')
      sec=$(  printf "%s" "$sel" | awk -F: '{print $6}')
      [ -n "$sec" ] || sec="--"
      connect_to "$ssid" "$bssid" "$sec"
      printf "Press Enter to continue…"; IFS= read -r _ ;;
  esac
done
