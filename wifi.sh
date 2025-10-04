#!/usr/bin/env bash
# wifi-picker.sh — simple TUI-ish Wi-Fi picker using nmcli only
# Works on headless Ubuntu Server; no dialog/fzf required.

set -euo pipefail

# ---------- Helpers ----------
err() { echo "Error: $*" >&2; exit 1; }
bold() { tput bold 2>/dev/null || true; }
sgr0() { tput sgr0 2>/dev/null || true; }

need() { command -v "$1" >/dev/null 2>&1 || err "Missing $1"; }
need nmcli

# Find the primary Wi-Fi interface (first TYPE=wifi)
IFACE="$(nmcli -t -f DEVICE,TYPE device status | awk -F: '$2=="wifi"{print $1; exit}')"
[[ -n "${IFACE:-}" ]] || err "No Wi-Fi interface found (TYPE=wifi)."

# Make sure Wi-Fi radio is on
nmcli radio wifi on >/dev/null || true

# ---------- Functions ----------
scan_networks() {
  # Return a TAB-separated table: INUSE \t SSID \t SECURITY \t SIGNAL
  # nmcli sometimes prints blank SSIDs; filter them out.
  nmcli -t -f IN-USE,SSID,SECURITY,SIGNAL device wifi list ifname "$IFACE" \
    | awk -F: 'length($2)>0 {print $1 "\t" $2 "\t" ($3==""?"--":$3) "\t" ($4==""?"0":$4)}'
}

print_menu() {
  local data="$1"
  local i=0
  echo
  echo "$(bold)Interface: $IFACE$(sgr0)"
  echo
  printf "%-4s %-1s %-32s %-12s %s\n" "#" "*" "SSID" "SECURITY" "SIGNAL"
  printf "%-4s %-1s %-32s %-12s %s\n" "----" "-" "--------------------------------" "------------" "------"
  # shellcheck disable=SC2001
  while IFS=$'\t' read -r inuse ssid sec sig; do
    i=$((i+1))
    local star=""
    [[ "$inuse" == "*" ]] && star="*"
    # truncate SSID to 32 chars for tidy print (but keep full internally)
    local ssid_disp="${ssid:0:32}"
    printf "%-4s %-1s %-32s %-12s %s\n" "$i" "$star" "$ssid_disp" "$sec" "$sig"
  done <<< "$data"
  echo
  echo "[C] Connect to a network   [D] Disconnect current   [R] Rescan   [Q] Quit"
}

get_choice() {
  local data_lines
  data_lines=$(wc -l <<< "$1")
  read -rp "Select # / C / D / R / Q: " choice
  echo "$choice" | tr '[:upper:]' '[:lower:]'
}

connect_to() {
  local ssid="$1"
  local sec="$2"

  echo
  echo "$(bold)Connecting to SSID:${sgr0} $ssid"
  if [[ "$sec" == "--" || "$sec" == "NONE" ]]; then
    nmcli device wifi connect "$ssid" ifname "$IFACE"
  else
    # Try passwordless first (some WPA-enterprise can be pre-configured)
    if ! nmcli -w 10 device wifi connect "$ssid" ifname "$IFACE" 2>/dev/null; then
      # Prompt for passphrase silently
      read -rs -p "Wi-Fi password for \"$ssid\": " pass
      echo
      nmcli device wifi connect "$ssid" ifname "$IFACE" password "$pass"
    fi
  fi
  echo "✅ Connected."
}

disconnect_now() {
  # If a Wi-Fi connection is active on IFACE, bring it down.
  local active_id
  active_id="$(nmcli -t -f NAME,TYPE,DEVICE connection show --active \
               | awk -F: -v ifc="$IFACE" '$2=="wifi" && $3==ifc{print $1; exit}')"
  if [[ -n "$active_id" ]]; then
    echo "Disconnecting \"$active_id\" on $IFACE…"
    nmcli connection down id "$active_id" || nmcli device disconnect "$IFACE"
    echo "✅ Disconnected."
  else
    echo "No active Wi-Fi connection on $IFACE."
  fi
}

# ---------- Main loop ----------
while :; do
  MAPFILE -t ROWS < <(scan_networks)
  if [[ "${#ROWS[@]}" -eq 0 ]]; then
    echo "No networks found. Rescanning…"
    nmcli device wifi rescan ifname "$IFACE" || true
    sleep 2
    MAPFILE -t ROWS < <(scan_networks)
  fi

  # Build a parallel arrays of SSIDs and SECs for selection
  SSIDS=()
  SECS=()
  for line in "${ROWS[@]}"; do
    IFS=$'\t' read -r inuse ssid sec sig <<< "$line"
    SSIDS+=("$ssid")
    SECS+=("$sec")
  done

  print_menu "$(printf '%s\n' "${ROWS[@]}")"
  choice="$(get_choice "$(printf '%s\n' "${ROWS[@]}")")"

  case "$choice" in
    q) echo "Bye."; exit 0 ;;
    r)
      echo "Rescanning…"
      nmcli device wifi rescan ifname "$IFACE" || true
      sleep 1
      ;;
    d)
      disconnect_now
      read -rp "Press Enter to continue…"
      ;;
    c)
      # Prompt to type an SSID manually (for hidden networks)
      read -rp "Enter SSID (exact, case-sensitive): " manual_ssid
      [[ -z "$manual_ssid" ]] && continue
      # Ask security type hint (optional)
      read -rp "Security (press Enter if unknown): " sec_hint
      connect_to "$manual_ssid" "${sec_hint:-WPA-PSK}"
      read -rp "Press Enter to continue…"
      ;;
    ''|*[!0-9]*)
      echo "Invalid choice."; sleep 1 ;;
    *)
      index="$choice"
      if (( index < 1 || index > ${#SSIDS[@]} )); then
        echo "Invalid number."; sleep 1; continue
      fi
      sel_ssid="${SSIDS[$((index-1))]}"
      sel_sec="${SECS[$((index-1))]}"
      connect_to "$sel_ssid" "$sel_sec"
      read -rp "Press Enter to continue…"
      ;;
  esac
done
