#!/bin/sh
# wifi.sh — POSIX Wi-Fi picker with SSID, Band, Signal (numeric)
# - Uses nmcli with a custom separator to avoid ':' escaping issues
# - Sanitizes BSSID before connect; falls back to SSID-only if needed

set -eu

err() { printf >&2 "Error: %s\n" "$*"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

have nmcli || err "nmcli not found. Install network-manager."

# Find first Wi-Fi interface managed by NetworkManager
IFACE="$(nmcli -t -f DEVICE,TYPE device status | awk -F: '$2=="wifi"{print $1; exit}')"
[ -n "${IFACE:-}" ] || err "No Wi-Fi interface (TYPE=wifi) found."
nmcli radio wifi on >/dev/null 2>&1 || true

TMP="${TMPDIR:-/tmp}/wifi_scan.$$"
trap 'rm -f "$TMP"' EXIT INT HUP TERM

is_uint() { case "$1" in ''|*[!0-9]*) return 1;; *) return 0;; esac }

band_of_freq() {
  f="$1"
  is_uint "$f" || { echo "?"; return; }
  # MHz ranges
  [ "$f" -ge 2400 ] && [ "$f" -le 2500 ] && { echo "2.4"; return; }
  [ "$f" -ge 4900 ] && [ "$f" -le 5895 ] && { echo "5";   return; }
  [ "$f" -ge 5925 ] && [ "$f" -le 7125 ] && { echo "6";   return; }
  echo "?"
}

sanitize_bssid() {
  # Keep only hex digits and colons
  printf "%s" "$1" | tr -cd '0-9A-Fa-f:'
}

scan_networks() {
  # Use a safe separator so colons inside fields don't split rows.
  # Fields: SSID|BSSID|FREQ|SIGNAL|SECURITY|IN-USE
  nmcli -t --escape yes --separator '|' \
    -f SSID,BSSID,FREQ,SIGNAL,SECURITY,IN-USE \
    device wifi list ifname "$IFACE" \
    | awk -F'|' 'length($1)>0' >"$TMP"
}

print_menu() {
  echo
  printf "Interface: %s\n\n" "$IFACE"
  printf "%-4s %-32s %-4s %s\n" "#" "SSID" "Band" "Signal"
  printf "%-4s %-32s %-4s %s\n" "----" "--------------------------------" "----" "------"
  i=0
  while IFS='|' read -r ssid bssid freq signal sec inuse; do
    i=$((i+1))
    # Normalize fields
    freq_digits=$(printf "%s" "${freq:-}"   | tr -cd '0-9')
    sig_digits=$( printf "%s" "${signal:-}" | tr -cd '0-9')
    [ -n "$sig_digits" ] || sig_digits="0"
    band="$(band_of_freq "${freq_digits:-0}")"
    ssid_disp=$(printf "%s" "$ssid" | cut -c1-32)
    printf "%-4s %-32s %-4s %s\n" "$i" "$ssid_disp" "$band" "$sig_digits"
  done <"$TMP"
  echo
  echo "[C] Connect (hidden SSID)   [D] Disconnect current   [R] Rescan   [Q] Quit"
  echo "Pick a number to connect (tries exact AP, falls back to SSID)."
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

connect_to_row() {
  row="$1"
  # Parse the row again using the same delimiter
  ssid=$(  printf "%s" "$row" | awk -F'|' '{print $1}')
  bssid=$( printf "%s" "$row" | awk -F'|' '{print $2}')
  sec=$(   printf "%s" "$row" | awk -F'|' '{print $5}')
  sbssid="$(sanitize_bssid "$bssid")"

  echo
  echo "Connecting to SSID: $ssid"

  if [ -n "$sbssid" ]; then
    echo "Trying AP (BSSID): $sbssid"
    if nmcli -w 10 device wifi connect "$ssid" ifname "$IFACE" bssid "$sbssid" >/dev/null 2>&1; then
      echo "✅ Connected (by BSSID)."
      return 0
    else
      echo "…BSSID connect failed, falling back to SSID only."
    fi
  fi

  # SSID-only (let NM choose the best AP). Prompt for pass only if needed.
  if nmcli -w 10 device wifi connect "$ssid" ifname "$IFACE" >/dev/null 2>&1; then
    echo "✅ Connected (by SSID)."
    return 0
  fi

  # Prompt for password and retry SSID-only
  printf "Wi-Fi password for \"%s\": " "$ssid" >/dev/tty
  stty -echo </dev/tty 2>/dev/null || true
  IFS= read -r pass </dev/tty || pass=""
  stty echo </dev/tty 2>/dev/null || true
  echo
  nmcli device wifi connect "$ssid" ifname "$IFACE" password "$pass" || err "Connect failed."
  echo "✅ Connected."
}

# ---------- Main loop ----------
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
    r) echo "Rescanning…"; nmcli device wifi rescan ifname "$IFACE" >/dev/null 2>&1 || true; sleep 1 ;;
    d) disconnect_now; printf "Press Enter to continue…"; IFS= read -r _ ;;
    c)
      printf "Enter SSID (exact, case-sensitive): "; IFS= read -r manual_ssid
      [ -z "$manual_ssid" ] && continue
      echo "Connecting to hidden SSID: $manual_ssid"
      if nmcli -w 10 device wifi connect "$manual_ssid" ifname "$IFACE" >/dev/null 2>&1; then
        echo "✅ Connected."
      else
        printf "Wi-Fi password for \"%s\": " "$manual_ssid" >/dev/tty
        stty -echo </dev/tty 2>/dev/null || true
        IFS= read -r pass </dev/tty || pass=""
        stty echo </dev/tty 2>/dev/null || true
        echo
        nmcli device wifi connect "$manual_ssid" ifname "$IFACE" password "$pass" || err "Connect failed."
        echo "✅ Connected."
      fi
      printf "Press Enter to continue…"; IFS= read -r _ ;;
    *)
      case "$choice" in *[!0-9]*|"") echo "Invalid choice."; sleep 1; continue ;; esac
      # Fetch the Nth line from the scan results and pass it to connect
      sel="$(nl -ba "$TMP" | awk -v n="$choice" '$1==n{ $1=""; sub(/^ *\t?/,""); print; exit }')"
      [ -n "${sel:-}" ] || { echo "Invalid number."; sleep 1; continue; }
      connect_to_row "$sel"
      printf "Press Enter to continue…"; IFS= read -r _ ;;
  esac
done
