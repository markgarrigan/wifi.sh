#!/bin/sh
# wifi — SSID/Band/Signal picker for terminals
# - nmcli 1.52-safe parsing (SSIDs with colons, FREQ like "#### MHz")
# - Sorted table (Signal desc)
# - SSID-first connect (avoids brcmfmac channel-set errors), optional BSSID fallback
# - Explicit security profiles to avoid "key-mgmt missing" on some setups

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
    # Raspberry Pi Broadcom driver: avoid AP/channel forcing (reduces -52 spam)
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
  # 5 GHz includes UNII bands; upper bound covers common values
  [ "$f" -ge 4900 ] && [ "$f" -le 5895 ] && { echo "5"; return; }
  [ "$f" -ge 5925 ] && [ "$f" -le 7125 ] && { echo "6"; return; }
  echo "?"
}

sanitize_bssid(){ printf "%s" "$1" | tr -cd '0-9A-Fa-f:'; }

scan_networks(){
  # nmcli terse: SSID:BSSID:FREQ:SIGNAL:SECURITY
  # BSSID = 6 octets with colons; SSID can contain escaped "\:"; FREQ may be "#### MHz"
  nmcli -t -f SSID,BSSID,FREQ,SIGNAL,SECURITY device wifi list ifname "$IFACE" \
  | awk -F: '
    {
      n = NF
      # min: SSID(>=1) + BSSID(6) + FREQ(1) + SIGNAL(1) + SECURITY(1) = 10 fields
      if (n < 10) next

      security = $n
      signal   = $(n-1)
      freq     = $(n-2)
      bssid    = $(n-8) ":" $(n-7) ":" $(n-6) ":" $(n-5) ":" $(n-4) ":" $(n-3)

      ssid = $1
      for (i = 2; i <= n-9; i++) ssid = ssid ":" $i

      gsub(/\\:/, ":", ssid)  # unescape literal colons

      if (length(ssid) > 0) {
        printf "%s|%s|%s|%s|%s\n", ssid, bssid, freq, signal, security
      }
    }
  ' >"$TMP"

  # Sort by SIGNAL desc; stable by SSID then BSSID
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
  echo "Pick a number to connect (SSID-first; explicit security; BSSID fallback if safe)."
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

# Create a temporary connection profile with explicit security.
# Args: ssid, security, [bssid or ""]
connect_via_profile(){
  _ssid="$1"; _sec="$2"; _bssid="${3:-}"
  _conn="__wifi_tmp_$$"
  # Clean any stale tmp connection with same name
  nmcli -t -f NAME connection show 2>/dev/null | awk -F: -v n="$_conn" '$1==n{print $1}' \
    | while read -r old; do nmcli connection delete id "$old" >/dev/null 2>&1 || true; done

  # Determine key-mgmt from SECURITY column
  # SECURITY examples: "--" (open), "WPA2", "WPA3", "WPA2 WPA3", "SAE", "WEP", "OWE"
  case " $_sec " in
    *" -- "*)  # Open
      nmcli -w 20 connection add type wifi ifname "$IFACE" con-name "$_conn" ssid "$_ssid" >/dev/null
      ;;
    *" WEP "*) # WEP (legacy)
      printf "WEP key for \"%s\": " "$_ssid" >/dev/tty
      stty -echo </dev/tty 2>/dev/null || true
      IFS= read -r _pass </dev/tty || _pass=""
      stty echo </dev/tty 2>/dev/null || true
      echo
      nmcli -w 20 connection add type wifi ifname "$IFACE" con-name "$_conn" ssid "$_ssid" \
        802-11-wireless-security.key-mgmt none \
        802-11-wireless-security.wep-key0 "$_pass" \
        802-11-wireless-security.wep-key-type key >/dev/null
      ;;
    *" SAE "*|*" WPA3 "*)  # WPA3-Personal
      if [ "$SUPPORTS_ASK" -eq 1 ]; then
        # Let NM prompt for SAE vs mixed; still set sae first
        nmcli -w 30 connection add type wifi ifname "$IFACE" con-name "$_conn" ssid "$_ssid" \
          802-11-wireless-security.key-mgmt sae >/dev/null
        echo "(Credential prompt may appear in TTY)"
        nmcli -w 45 --ask connection up id "$_conn" ${_bssid:+ap "$_bssid"} && return 0
        # Fallback to PSK for mixed WPA2/3
        nmcli connection modify "$_conn" 802-11-wireless-security.key-mgmt wpa-psk >/dev/null
        nmcli -w 45 --ask connection up id "$_conn" ${_bssid:+ap "$_bssid"} && return 0
        nmcli connection delete id "$_conn" >/dev/null 2>&1 || true
        return 1
      else
        printf "Wi-Fi password for \"%s\": " "$_ssid" >/dev/tty
        stty -echo </dev/tty 2>/dev/null || true
        IFS= read -r _pass </dev/tty || _pass=""
        stty echo </dev/tty 2>/dev/null || true
        echo
        nmcli -w 20 connection add type wifi ifname "$IFACE" con-name "$_conn" ssid "$_ssid" \
          802-11-wireless-security.key-mgmt sae \
          802-11-wireless-security.psk "$_pass" >/dev/null || true
        nmcli -w 30 connection up id "$_conn" ${_bssid:+ap "$_bssid"} && return 0
        # Fallback to PSK
        nmcli connection modify "$_conn" 802-11-wireless-security.key-mgmt wpa-psk >/dev/null
        nmcli -w 30 connection up id "$_conn" ${_bssid:+ap "$_bssid"} && return 0
        nmcli connection delete id "$_conn" >/dev/null 2>&1 || true
        return 1
      fi
      ;;
    *" OWE "*) # Enhanced Open (OWE) — no password but key-mgmt=owe
      nmcli -w 20 connection add type wifi ifname "$IFACE" con-name "$_conn" ssid "$_ssid" \
        802-11-wireless-security.key-mgmt owe >/dev/null
      ;;
    *) # WPA/WPA2-Personal (default)
      if [ "$SUPPORTS_ASK" -eq 1 ]; then
        nmcli -w 20 connection add type wifi ifname "$IFACE" con-name "$_conn" ssid "$_ssid" \
          802-11-wireless-security.key-mgmt wpa-psk >/dev/null
        echo "(Credential prompt may appear in TTY)"
        nmcli -w 45 --ask connection up id "$_conn" ${_bssid:+ap "$_bssid"} && return 0
        nmcli connection delete id "$_conn" >/dev/null 2>&1 || true
        return 1
      else
        printf "Wi-Fi password for \"%s\": " "$_ssid" >/dev/tty
        stty -echo </dev/tty 2>/dev/null || true
        IFS= read -r _pass </dev/tty || _pass=""
        stty echo </dev/tty 2>/dev/null || true
        echo
        nmcli -w 20 connection add type wifi ifname "$IFACE" con-name "$_conn" ssid "$_ssid" \
          802-11-wireless-security.key-mgmt wpa-psk \
          802-11-wireless-security.psk "$_pass" >/dev/null
      fi
      ;;
  esac

  # Bring it up (SSID-first). If BSSID provided (and allowed), pass as AP hint.
  nmcli -w 45 connection up id "$_conn" ${_bssid:+ap "$_bssid"} >/dev/null
}

connect_to_row(){
  row="$1"
  ssid=$(     printf "%s" "$row" | awk -F'|' '{print $1}')
  bssid=$(    printf "%s" "$row" | awk -F'|' '{print $2}')
  security=$( printf "%s" "$row" | awk -F'|' '{print $5}')
  sbssid="$(sanitize_bssid "$bssid")"

  echo
  echo "Connecting to SSID: $ssid"
  [ "$TRY_BSSID" -eq 1 ] && [ -n "$sbssid" ] && echo "Preferred AP (BSSID): $sbssid"

  # 1) SSID-first with explicit profile (no AP hint)
  if connect_via_profile "$ssid" "$security" ""; then
    echo "✅ Connected (SSID)."; return 0
  fi

  # 2) Optional BSSID fallback if not on brcmfmac (channel forcing can fail on Pi)
  if [ "$TRY_BSSID" -eq 1 ] && [ -n "$sbssid" ]; then
    echo "…Retrying with BSSID hint."
    if connect_via_profile "$ssid" "$security" "$sbssid"; then
      echo "✅ Connected (BSSID)."; return 0
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
      # Probe security for manual SSID by scanning and exact match (first hit)
      manual_row="$(grep -m1 -F "^$manual_ssid|" "$TMP_SORT" || true)"
      sec_guess="WPA2"
      if [ -n "$manual_row" ]; then
        sec_guess="$(printf "%s" "$manual_row" | awk -F'|' '{print $5}')"
      fi
      echo "Connecting to hidden/typed SSID: $manual_ssid (security: $sec_guess)"
      if connect_via_profile "$manual_ssid" "$sec_guess" ""; then
        echo "✅ Connected."
      else
        echo "Hidden SSID connect failed."
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
