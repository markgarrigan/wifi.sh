#!/bin/sh
# wifi — SSID/Band/Signal picker for terminals
# - nmcli 1.52-safe parsing (SSIDs with colons, FREQ like "#### MHz")
# - Single table: "#  Current  SSID  BAND  SIGNAL" with current indicator
# - Sort: SSID (A→Z), then Signal (desc) within same SSID
# - SSID-first connect (avoids brcmfmac channel-set errors), optional BSSID fallback
# - Explicit security profiles to avoid "key-mgmt missing" errors
# - Exits after successful connection

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

sanitize_bssid(){ printf "%s" "$1" | tr -cd '0-9A-Fa-f:'; }

scan_networks(){
  # Include IN-USE so we can show the active row.
  # Fields: IN-USE:SSID:BSSID:FREQ:SIGNAL:SECURITY
  # BSSID = 6 octets with colons; SSID may contain escaped "\:"; FREQ may be "#### MHz".
  nmcli -t -f IN-USE,SSID,BSSID,FREQ,SIGNAL,SECURITY device wifi list ifname "$IFACE" \
  | awk -F: '
    {
      n = NF
      # min: IN-USE(1) + SSID(>=1) + BSSID(6) + FREQ(1) + SIGNAL(1) + SECURITY(1) = 11 fields
      if (n < 11) next

      inuse   = $1
      security= $n
      signal  = $(n-1)
      freq    = $(n-2)
      bssid   = $(n-8) ":" $(n-7) ":" $(n-6) ":" $(n-5) ":" $(n-4) ":" $(n-3)

      ssid = $2
      for (i = 3; i <= n-9; i++) ssid = ssid ":" $i

      gsub(/\\:/, ":", ssid)  # unescape literal colons

      if (length(ssid) > 0) {
        printf "%s|%s|%s|%s|%s|%s\n", inuse, ssid, bssid, freq, signal, security
      }
    }
  ' >"$TMP"

  # Sort by SSID asc (col 2), then by SIGNAL desc (col 5), then by BSSID
  if [ -s "$TMP" ]; then
    sort -t'|' -k2,2f -k5,5nr -k3,3 "$TMP" > "$TMP_SORT" || cp "$TMP" "$TMP_SORT"
  else
    : > "$TMP_SORT"
  fi
}

print_menu(){
  echo
  printf "Interface: %s\n\n" "$IFACE"
  # One table: numbered, shows current indicator, SSID, band, signal
  awk -F'|' '
    BEGIN{
      printf "%-4s %-8s %-32s %-4s %s\n", "#", "Current", "SSID", "BAND", "SIGNAL";
      printf "%-4s %-8s %-32s %-4s %s\n", "----", "--------", "--------------------------------", "----", "------";
    }
    {
      idx++
      inuse = ($1=="*") ? "*" : ""
      ssid = $2
      freq = $4
      signal = $5
      gsub(/[^0-9]/,"", freq)
      if (freq>=2400 && freq<=2500) band="2.4";
      else if (freq>=4900 && freq<=5895) band="5";
      else if (freq>=5925 && freq<=7125) band="6";
      else band="?"
      if (length(ssid)>32) ssid = substr(ssid,1,32)
      printf "%-4d %-8s %-32s %-4s %s\n", idx, inuse, ssid, band, signal
    }
  ' "$TMP_SORT"
  echo
  echo "[C] Connect (hidden SSID)   [D] Disconnect current   [R] Rescan   [Q] Quit"
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
    *" SAE "*|*" WPA3 "*)  # WPA3-Personal / SAE
      if [ "$SUPPORTS_ASK" -eq 1 ]; then
        nmcli -w 30 connection add type wifi ifname "$IFACE" con-name "$_conn" ssid "$_ssid" \
          802-11-wireless-security.key-mgmt sae >/dev/null
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
        nmcli connection modify "$_conn" 802-11-wireless-security.key-mgmt wpa-psk >/dev/null
        nmcli -w 30 connection up id "$_conn" ${_bssid:+ap "$_bssid"} && return 0
        nmcli connection delete id "$_conn" >/dev/null 2>&1 || true
        return 1
      fi
      ;;
    *" OWE "*) # Enhanced Open (OWE)
      nmcli -w 20 connection add type wifi ifname "$IFACE" con-name "$_conn" ssid "$_ssid" \
        802-11-wireless-security.key-mgmt owe >/dev/null
      ;;
    *) # WPA/WPA2-Personal (default)
      if [ "$SUPPORTS_ASK" -eq 1 ]; then
        nmcli -w 20 connection add type wifi ifname "$IFACE" con-name "$_conn" ssid "$_ssid" \
          802-11-wireless-security.key-mgmt wpa-psk >/dev/null
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

  nmcli -w 45 connection up id "$_conn" ${_bssid:+ap "$_bssid"} >/dev/null
}

connect_to_row(){
  row="$1"
  ssid=$(     printf "%s" "$row" | awk -F'|' '{print $2}')
  bssid=$(    printf "%s" "$row" | awk -F'|' '{print $3}')
  security=$( printf "%s" "$row" | awk -F'|' '{print $6}')
  sbssid="$(sanitize_bssid "$bssid")"

  echo
  echo "Connecting to SSID: $ssid"
  [ "$TRY_BSSID" -eq 1 ] && [ -n "$sbssid" ] && echo "Preferred AP (BSSID): $sbssid"

  # 1) SSID-first with explicit profile (no AP hint)
  if connect_via_profile "$ssid" "$security" ""; then
    echo "✅ Connected to \"$ssid\"."
    exit 0
  fi

  # 2) Optional BSSID fallback if not on brcmfmac
  if [ "$TRY_BSSID" -eq 1 ] && [ -n "$sbssid" ]; then
    echo "…Retrying with BSSID hint."
    if connect_via_profile "$ssid" "$security" "$sbssid"; then
      echo "✅ Connected to \"$ssid\" (BSSID)."
      exit 0
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
      manual_row="$(grep -m1 -F "|$manual_ssid|" "$TMP_SORT" || true)"
      sec_guess="WPA2"
      if [ -n "$manual_row" ]; then
        sec_guess="$(printf "%s" "$manual_row" | awk -F'|' '{print $6}')"
      fi
      echo "Connecting to \"$manual_ssid\" (security: $sec_guess)..."
      if connect_via_profile "$manual_ssid" "$sec_guess" ""; then
        echo "✅ Connected to \"$manual_ssid\"."
        exit 0
      else
        echo "Hidden/typed SSID connect failed."
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
