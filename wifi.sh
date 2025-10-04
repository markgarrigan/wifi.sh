#!/bin/sh
# wifi-picker.sh — POSIX-only Wi-Fi picker using nmcli
# Works in /bin/sh (dash). No bash features required.

set -eu

err() { printf >&2 "Error: %s\n" "$*"; exit 1; }

# Require nmcli
command -v nmcli >/dev/null 2>&1 || err "nmcli not found. Install network-manager."

# Find Wi-Fi interface
IFACE="$(nmcli -t -f DEVICE,TYPE device status | awk -F: '$2=="wifi"{print $1; exit}')"
[ -n "${IFACE:-}" ] || err "No Wi-Fi interface of TYPE=wifi found."

# Ensure radio on
nmcli radio wifi on >/dev/null 2>&1 || true

# Temp file for scan results
TMP="${TMPDIR:-/tmp}/wifi_scan.$$"
trap 'rm -f "$TMP"' EXIT INT HUP TERM

scan_networks() {
  # Fields: IN-USE:SSID:SECURITY:SIGNAL
  nmcli -t -f IN-USE,SSID,SECURITY,SIGNAL device wifi list ifname "$IFACE" \
    | awk -F: 'length($2)>0 {print $0}' >"$TMP"
}

print_menu() {
  echo
  printf "Interface: %s\n\n" "$IFACE"
  printf "%-4s %-1s %-32s %-12s %s\n" "#" "*" "SSID" "SECURITY" "SIGNAL"
  printf "%-4s %-1s %-32s %-12s %s\n" "----" "-" "--------------------------------" "------------" "------"
  i=0
  while IFS=: read -r inuse ssid sec sig; do
    i=$((i+1))
    [ -n "$sec" ] || sec="--"
    [ -n "$sig" ] || sig="0"
    star=""
    [ "$inuse" = "*" ] && star="*"
    ssid_disp=$(printf "%s" "$ssid" | cut -c1-32)
    printf "%-4s %-1s %-32s %-12s %s\n" "$i" "$star" "$ssid_disp" "$sec" "$sig"
  done <"$TMP"
  echo
  echo "[C] Connect (hidden SSID)   [D] Disconnect current   [R] Rescan   [Q] Quit"
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
  sec="$2"
  echo
  echo "Connecting to SSID: $ssid"
  if [ "$sec" = "--" ] || [ "$sec" = "NONE" ]; then
    nmcli device wifi connect "$ssid" ifname "$IFACE" || err "Connect failed."
  else
    # Try without password first (in case of pre-config)
    if ! nmcli -w 10 device wifi connect "$ssid" ifname "$IFACE" >/dev/null 2>&1; then
      printf "Wi-Fi password for \"%s\": " "$ssid" >/dev/tty
      stty -echo </dev/tty 2>/dev/null || true
      IFS= read -r pass </dev/tty || pass=""
      stty echo </dev/tty 2>/dev/null || true
      echo
      nmcli device wifi connect "$ssid" ifname "$IFACE" password "$pass" || err "Connect failed."
    fi
  fi
  echo "✅ Connected."
}

while :; do
  scan_networks
  # If nothing found, rescan once
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
      connect_to "$manual_ssid" "$sec_hint"
      printf "Press Enter to continue…"; IFS= read -r _ ;;
    *)
      # Expect a number; select that line
      case "$choice" in
        *[!0-9]*|"") echo "Invalid choice."; sleep 1; continue ;;
      esac
      sel_line="$(nl -ba "$TMP" | awk -v n="$choice" '$1==n{ $1=""; sub(/^ *\t?/,""); print; exit }')"
      if [ -z "${sel_line:-}" ]; then
        echo "Invalid number."; sleep 1; continue
      fi
      # Parse fields from selected line
      inuse=$(printf "%s" "$sel_line" | awk -F: '{print $1}')
      ssid=$(printf "%s" "$sel_line" | awk -F: '{print $2}')
      sec=$(printf "%s" "$sel_line" | awk -F: '{print $3}')
      [ -n "$sec" ] || sec="--"
      connect_to "$ssid" "$sec"
      printf "Press Enter to continue…"; IFS= read -r _ ;;
  esac
done
