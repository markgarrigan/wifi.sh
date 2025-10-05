#!/bin/sh
# wifi — SSID/Band/Signal picker; robust parsing for nmcli 1.52, SSIDs with colons; SSID-first connect; BSSID fallback

set -eu
export LC_ALL=C

err() { printf >&2 "Error: %s\n" "$*"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

have nmcli || err "nmcli not found. Install network-manager."

# Pick first Wi-Fi interface
IFACE="$(nmcli -t -f DEVICE,TYPE device status | awk -F: '$2=="wifi"{print $1; exit}')"
[ -n "${IFACE:-}" ] || err "No Wi-Fi interface found."
nmcli radio wifi on >/dev/null 2>&1 || true

# Feature/driver probes
SUPPORTS_ASK=0
nmcli --help 2>/dev/null | grep -q -- '--ask' && SUPPORTS_ASK=1

TRY_BSSID=1
if command -v ethtool >/dev/null 2>&1; then
  if ethtool -i "$IFACE" 2>/dev/null | grep -qi 'driver: *brcmfmac'; then
    # Raspberry Pi Broadcom driver is picky about forced AP/channel
    TRY_BSSID=0
  fi
fi

TMP="${TMPDIR:-/tmp}/wifi_scan.$$"
TMP_SORT="${TMPDIR:-/tmp}/wifi_scan_sorted.$$"
trap 'rm -f "$TMP" "$TMP_SORT"' EXIT INT HUP TERM

is_uint(){ case "$1" in ''|*[!0-9]*) return 1;; *) return 0;; esac; }

band_of_freq(){
  f="$1"; is_uint "$f" || { echo "?"; return; }
  [ "$f" -ge 2400 ] && [ "$f" -le 2500 ] && { echo "2.4"; return; }
  [ "$f" -ge 4900 ] && [ "$f" -le 5895 ] && { echo "5"; return; }
  [ "$f" -ge 5925 ] && [ "$f" -le 7125 ] && { echo "6"; return; }
  echo "?"
}

sanitize_bssid(){ printf "%s" "$1" | tr -cd '0-9A-Fa-f:'; }

scan_networks(){
  # nmcli 1.52 (t for terse) with fields: SSID:BSSID:FREQ:SIGNAL:SECURITY
  # BSSID is 6 colon-separated octets; SSID may contain escaped \:; FREQ may be "#### MHz".
  nmcli -t -f SSID,BSSID,FREQ,SIGNAL,SECURITY device wifi list ifname "$IFACE" \
  | awk -F: '
    {
      n = NF
      # Need at least: SSID(>=1 field) + BSSID(6) + FREQ(1) + SIGNAL(1) + SECURITY(1) = 10 fields
      if (n < 10) next

      security = $n
      signal   = $(n-1)
      freq     = $(n-2)
      bssid    = $(n-8) ":" $(n-7) ":" $(n-6) ":" $(n-5) ":" $(n-4) ":" $(n-3)

      ssid = $1
      for (i = 2; i <= n-9; i++) ssid = ssid ":" $i

      gsub(/\\:/, ":", ssid)  # unescape literal colons in SSID

      if (length(ssid) > 0) {
        printf "%s|%s|%s|%s|%s\n", ssid, bssid, freq, signal, security
      }
    }
  ' >"$TMP"

  # Sort by SIGNAL desc; stable by SSID then BSSID for ties
  if [ -s "$TMP" ]; then
    sort -t'|' -k4,4nr -k1,1 -k2,2 "$TMP" > "$TMP_SORT" || cp "$TMP" "$TMP_SORT"
  else
    : > "$TMP_SORT"
  fi
}

print_menu(){
  echo
  printf "Interface: %s\n\n" "$IFACE"
  printf "%-4s %-32s %-4s %s\n" "#" "SSID" "Band" "Signal"
  printf "%-4s %-32s %-4s %s\n" "----" "--------------------------------" "----" "------"
  i=0
  while IFS='|' read -r ssid bssid freq signal security; do
    i=$((i+1))
    freq_digits=$(printf "%s" "${freq:-}"   | tr -cd '0-9')
    sig_digits=$( printf "%s" "${signal:-}" | tr -cd '0-9')
    [ -n "$sig_digits" ] || sig_digits="0"
    band="$(band_of_freq "${freq_digits:-0}")"
    ssid_disp=$(printf "%s" "$ssid" | cut -c1-32)
    printf "%-4s %-32s %-4s %s\n" "$i" "$ssid_disp" "$band" "$sig_digits"
  done <"$TMP_SORT"
  echo
  echo "[C] Connect (hidden SSID)   [D] Disconnect current   [R] Rescan   [Q] Quit"
  echo "Pick a number to connect (tries SSID first; may fall back to BSSID)."
}

disconnect_now(){
  active_id="$(nmcli -t -f NAME,TYPE,DEVICE connection show --active \
    | awk -F: -v ifc="$IFACE" '$2=="wifi" && $3==ifc{print $1; exit}')"
  if [ -n "${active_id:-}" ]; then
    echo "Disconnecting \"$active_id\"..."
    nmcli connection down id "$active_id" >/dev/null 2>&1 \
      || nmcli device disconnect "$IFACE" >/dev/null 2>&1 || true
    echo "✅ Disconnected."
  else
    echo "No active Wi-Fi connection."
  fi
}

connect_to_row(){
  row="$1"
  ssid=$(     printf "%s" "$row" | awk -F'|' '{print $1}')
  bssid=$(    printf "%s" "$row" | awk -F'|' '{print $2}')
  freq=$(     printf "%s" "$row" | awk -F'|' '{print $3}')
  signal=$(   printf "%s" "$row" | awk -F'|' '{print $4}')
  security=$( printf "%s" "$row" | awk -F'|' '{print $5}')
  sbssid="$(sanitize_bssid "$bssid")"

  is_open=0
  # nmcli SECURITY examples: "--" (open), "WPA2", "WPA3", "WPA2 WPA3", "WEP"
  [ "$security" = "--" ] && is_open=1

  echo
  echo "Connecting to SSID: $ssid"
  [ "$TRY_BSSID" -eq 1 ] && [ -n "$sbssid" ] && echo "Preferred AP (BSSID): $sbssid"

  # 1) Try SSID-first (avoids brcmfmac channel errors). Use --ask if supported for secured nets.
  if [ "$is_open" -eq 1 ]; then
    if nmcli -w 20 device wifi connect "$ssid" ifname "$IFACE"; then
      echo "✅ Connected (open network)."; return 0
    fi
  else
    if [ "$SUPPORTS_ASK" -eq 1 ]; then
      if nmcli -w 30 --ask device wifi connect "$ssid" ifname "$IFACE"; then
        echo "✅ Connected (asked for credentials)."; return 0
      fi
      echo "…SSID connect with --ask failed; manual password fallback."
    else
      echo "Wi-Fi password required."
      printf "Wi-Fi password for \"%s\": " "$ssid" >/dev/tty
      stty -echo </dev/tty 2>/dev/null || true
      IFS= read -r pass </dev/tty || pass=""
      stty echo </dev/tty 2>/dev/null || true
      echo
      if nmcli -w 30 device wifi connect "$ssid" ifname "$IFACE" password "$pass"; then
        echo "✅ Connected (by SSID with password)."; return 0
      fi
    fi
  fi

  # 2) If SSID-first failed and allowed, attempt BSSID-specific connect
  if [ "$TRY_BSSID" -eq 1 ] && [ -n "$sbssid" ]; then
    echo "…Trying AP-specific connect (BSSID)."
    if [ "$is_open" -eq 1 ]; then
      if nmcli -w 20 device wifi connect "$ssid" ifname "$IFACE" bssid "$sbssid"; then
        echo "✅ Connected (by BSSID, open)."; return 0
      fi
    else
      if [ "$SUPPORTS_ASK" -eq 1 ]; then
        if nmcli -w 30 --ask device wifi connect "$ssid" ifname "$IFACE" bssid "$sbssid"; then
          echo "✅ Connected (by BSSID with credentials)."; return 0
        fi
      else
        printf "Wi-Fi password for \"%s\" (BSSID %s): " "$ssid" "$sbssid" >/dev/tty
        stty -echo </dev/tty 2>/dev/null || true
        IFS= read -r pass </dev/tty || pass=""
        stty echo </dev/tty 2>/dev/null || true
        echo
        if nmcli -w 30 device wifi connect "$ssid" ifname "$IFACE" bssid "$sbssid" password "$pass"; then
          echo "✅ Connected (by BSSID with password)."; return 0
        fi
      fi
    fi
  fi

  err "Connect failed."
}

# Main loop
while :; do
  scan_networks
  if [ ! -s "$TMP_SORT" ]; then
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
    r) echo "Rescanning…"; nmcli device wifi rescan ifname "$IFACE" >/dev/null 2>&1; sleep 1 ;;
    d) disconnect_now; printf "Press Enter to continue…"; IFS= read -r _ ;;
    c)
      printf "Enter SSID (exact): "; IFS= read -r manual_ssid
      [ -z "$manual_ssid" ] && continue
      echo "Connecting to hidden SSID: $manual_ssid"
      if [ "$SUPPORTS_ASK" -eq 1 ]; then
        if nmcli -w 30 --ask device wifi connect "$manual_ssid" ifname "$IFACE" >/dev/null 2>&1; then
          echo "✅ Connected."
        else
          echo "Hidden SSID connect failed."
        fi
      else
        if nmcli -w 20 device wifi connect "$manual_ssid" ifname "$IFACE" >/dev/null 2>&1; then
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
      fi
      printf "Press Enter to continue…"; IFS= read -r _ ;;
    *)
      case "$choice" in *[!0-9]*|"") echo "Invalid choice."; sleep 1; continue ;; esac
      sel="$(nl -ba "$TMP_SORT" | awk -v n="$choice" '$1==n{ $1=""; sub(/^ *\t?/,""); print; exit }')"
      [ -n "${sel:-}" ] || { echo "Invalid number."; sleep 1; continue; }
      connect_to_row "$sel"
      printf "Press Enter to continue…"; IFS= read -r _ ;;
  esac
done
