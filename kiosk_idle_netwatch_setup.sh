#!/bin/bash
set -e

# =========================
# Spinner megjelenítése
# =========================
spinner() {
  local pid=$1
  local message=$2
  local delay=0.1
  local frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")

  tput civis 2>/dev/null || true
  local i=0
  while [ -d "/proc/$pid" ]; do
    local frame=${frames[$i]}
    printf "\r\e[35m%s\e[0m %s" "$frame" "$message"
    i=$(((i + 1) % ${#frames[@]}))
    sleep "$delay"
  done
  printf "\r\e[32m✔\e[0m %s\n" "$message"
  tput cnorm 2>/dev/null || true
}

# =========================
# Ellenőrzés: ne fusson rootként
# =========================
if [ "$(id -u)" -eq 0 ]; then
  echo "Ezt a scriptet nem szabad rootként futtatni. Kérlek normál felhasználóként futtasd, sudo jogosultsággal."
  exit 1
fi

# Aktuális felhasználó és home könyvtár
CURRENT_USER="$(whoami)"
HOME_DIR="$(eval echo "~$CURRENT_USER")"

# Boot konfigurációs fájl útvonalának meghatározása (distro/kiadás függő)
if [ -f "/boot/firmware/config.txt" ]; then
  BOOT_CONFIG="/boot/firmware/config.txt"
  BOOT_CMDLINE="/boot/firmware/cmdline.txt"
else
  BOOT_CONFIG="/boot/config.txt"
  BOOT_CMDLINE="/boot/cmdline.txt"
fi

# =========================
# Függvény igen/nem kérdéshez alapértelmezett értékkel
# =========================
ask_user() {
  local prompt="$1"
  local default="$2"
  local default_text=""

  if [ "$default" = "y" ]; then
    default_text=" [alapértelmezett: igen]"
  elif [ "$default" = "n" ]; then
    default_text=" [alapértelmezett: nem]"
  fi

  while true; do
    read -p "$prompt$default_text (y/n): " yn
    yn="${yn:-$default}"
    case $yn in
      [Yy]* ) return 0;;
      [Nn]* ) return 1;;
      * ) echo "Kérlek igen (y) vagy nem (n) választ adj.";;
    esac
  done
}

ask_positive_integer() {
  local prompt="$1"
  local default="$2"
  local value

  while true; do
    read -p "$prompt [alapértelmezett: $default]: " value
    value="${value:-$default}"

    if [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
      printf '%s\n' "$value"
      return 0
    fi

    echo "Kérlek egy 0-nál nagyobb egész számot adj meg."
  done
}

# =========================
# KIOSKPARANCS blokkok kezelése
# =========================
KIOSK_BEGIN="#KIOSKPARANCS_BEGIN"
KIOSK_END="#KIOSKPARANCS_END"

is_root_file() {
  local file="$1"
  case "$file" in
    /boot/*|/boot/firmware/*|/etc/*|/usr/*|/var/*) return 0 ;;
    *) return 1 ;;
  esac
}

ensure_parent_dir() {
  local f="$1"
  local d
  d="$(dirname "$f")"

  if is_root_file "$f"; then
    sudo mkdir -p "$d"
  else
    mkdir -p "$d"
  fi
}

remove_kiosk_block() {
  local file="$1"
  [ -f "$file" ] || return 0

  if is_root_file "$file"; then
    sudo sed -i "/^${KIOSK_BEGIN}\$/,/^${KIOSK_END}\$/d" "$file"
  else
    sed -i "/^${KIOSK_BEGIN}\$/,/^${KIOSK_END}\$/d" "$file"
  fi
}

write_kiosk_block() {
  local file="$1"
  local content="$2"

  ensure_parent_dir "$file"

  # fájl létezzen (root esetén sudo-val)
  if [ ! -f "$file" ]; then
    if is_root_file "$file"; then
      sudo touch "$file"
    else
      touch "$file"
    fi
  fi

  remove_kiosk_block "$file"

  if is_root_file "$file"; then
    {
      echo "$KIOSK_BEGIN"
      printf "%b\n" "$content"
      echo "$KIOSK_END"
    } | sudo tee -a "$file" > /dev/null
  else
    {
      echo "$KIOSK_BEGIN"
      printf "%b\n" "$content"
      echo "$KIOSK_END"
    } >> "$file"
  fi
}

LABWC_HIDECURSOR_BEGIN="<!-- KIOSK_HIDE_CURSOR_BEGIN -->"
LABWC_HIDECURSOR_END="<!-- KIOSK_HIDE_CURSOR_END -->"

update_labwc_rcxml_hidecursor() {
  local rc_xml="$1"
  local mode="$2"

  python3 - "$rc_xml" "$mode" "$LABWC_HIDECURSOR_BEGIN" "$LABWC_HIDECURSOR_END" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
mode = sys.argv[2]
begin = sys.argv[3]
end = sys.argv[4]

keybind_block = f'''  {begin}
  <keybind key="W-h">
    <action name="HideCursor"/>
    <action name="WarpCursor" to="output" x="1" y="1"/>
  </keybind>
  {end}'''

minimal_rcxml = f'''<?xml version="1.0"?>
<labwc_config>
  <keyboard>
{keybind_block}
  </keyboard>
</labwc_config>
'''

if path.exists():
    text = path.read_text(encoding='utf-8')
else:
    text = ''

patterns = [
    rf"\n?[ \t]*{re.escape(begin)}.*?{re.escape(end)}[ \t]*\n?",
    r'\n?[ \t]*<keybind\s+key="W-h">.*?<action\s+name="HideCursor"\s*/>.*?</keybind>[ \t]*\n?',
]
for pattern in patterns:
    text = re.sub(pattern, '\n', text, flags=re.S)

text = re.sub(r'\n{3,}', '\n\n', text)

if mode == 'disable':
    if path.exists():
        path.write_text(text, encoding='utf-8')
    sys.exit(0)

if not text.strip():
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(minimal_rcxml, encoding='utf-8')
    sys.exit(0)

if re.search(r'<keyboard\b[^>]*/>', text):
    text = re.sub(r'<keyboard\b[^>]*/>', f'<keyboard>\n{keybind_block}\n</keyboard>', text, count=1)
elif re.search(r'</keyboard>', text):
    text = re.sub(r'</keyboard>', f'{keybind_block}\n</keyboard>', text, count=1)
elif re.search(r'</labwc_config>', text):
    text = re.sub(r'</labwc_config>', f'  <keyboard>\n{keybind_block}\n  </keyboard>\n</labwc_config>', text, count=1)
else:
    text = text.rstrip() + '\n\n' + minimal_rcxml

text = re.sub(r'\n{3,}', '\n\n', text)
path.write_text(text, encoding='utf-8')
PY
}

# =========================
# cmdline.txt paraméter-szintű kezelés
# (a cmdline.txt egyetlen sor, paramétereket cserélünk benne)
# =========================
read_cmdline_one_line() {
  local file="$1"
  if [ ! -f "$file" ]; then
    echo ""
    return 0
  fi
  tr -d '\r' < "$file" | head -n 1
}

write_cmdline_one_line() {
  local file="$1"
  local line="$2"
  printf "%s\n" "$line" | sudo tee "$file" > /dev/null
}

cmdline_remove_key() {
  local line="$1"
  local key="$2"
  echo "$line" \
    | sed -E "s/(^|[[:space:]])${key}=[^[:space:]]+//g" \
    | sed -E 's/[[:space:]]+/ /g' \
    | sed -E 's/^ //; s/ $//'
}

cmdline_set_key_value() {
  local file="$1"
  local key="$2"
  local value="$3"

  local line
  line="$(read_cmdline_one_line "$file")"
  line="$(cmdline_remove_key "$line" "$key")"

  if [ -n "$line" ]; then
    line="${line} ${key}=${value}"
  else
    line="${key}=${value}"
  fi

  write_cmdline_one_line "$file" "$line"
}

cmdline_ensure_flag() {
  local file="$1"
  local flag="$2"

  local line
  line="$(read_cmdline_one_line "$file")"

  if echo " $line " | grep -qE "[[:space:]]${flag}[[:space:]]"; then
    return 0
  fi

  if [ -n "$line" ]; then
    line="${line} ${flag}"
  else
    line="${flag}"
  fi

  write_cmdline_one_line "$file" "$line"
}

# =========================
# Memóriában épített beállítások (a végén egyben írjuk ki)
# =========================
LABWC_AUTOSTART_FILE="$HOME_DIR/.config/labwc/autostart"
AUTOSTART_NEEDS_UPDATE="n"
AUTOSTART_BLOCK=""

CONFIG_NEEDS_UPDATE="n"
CONFIG_BLOCK=""

CMDLINE_NEEDS_SPLASH="n"
CMDLINE_NEEDS_CONSOLE_TTY3="n"
CMDLINE_VIDEO_VALUE=""   # pl. HDMI-A-1:1920x1080@60
KIOSK_BROWSER_HELPER="/usr/local/bin/kiosk-browser-switch.sh"

# =========================
# 1) Csomaglista frissítése?
# =========================
echo
if ask_user "Szeretnéd frissíteni a csomaglistát?" "y"; then
  echo -e "\e[90mCsomaglista frissítése folyamatban, kérlek várj...\e[0m"
  sudo apt update > /dev/null 2>&1 &
  spinner $! "Csomaglista frissítése..."
fi

# =========================
# 2) Telepített csomagok frissítése?
# =========================
echo
if ask_user "Szeretnéd frissíteni a telepített csomagokat?" "y"; then
  echo -e "\e[90mTelepített csomagok frissítése folyamatban (ez eltarthat egy ideig), kérlek várj...\e[0m"
  sudo apt upgrade -y > /dev/null 2>&1 &
  spinner $! "Telepített csomagok frissítése..."
fi

# =========================
# 3) Wayland / labwc telepítése?
# =========================
echo
if ask_user "Szeretnéd telepíteni a Wayland és labwc csomagokat?" "y"; then
  echo -e "\e[90mWayland csomagok telepítése folyamatban, kérlek várj...\e[0m"
  sudo apt install --no-install-recommends -y labwc wlr-randr seatd > /dev/null 2>&1 &
  spinner $! "Wayland csomagok telepítése..."

  sudo systemctl enable --now seatd > /dev/null 2>&1 || true

  # Ha létezik seat csoport, hozzáadjuk (distrofüggő)
  if getent group seat > /dev/null 2>&1; then
    if id -nG "$CURRENT_USER" | tr ' ' '\n' | grep -qx seat; then
      echo -e "\e[33mA '$CURRENT_USER' már tagja a 'seat' csoportnak.\e[0m"
    else
      sudo usermod -aG seat "$CURRENT_USER"
      echo -e "\e[33mA '$CURRENT_USER' hozzá lett adva a 'seat' csoporthoz. A változás reboot után lép életbe.\e[0m"
    fi
  fi
fi

# =========================
# 4) Chromium telepítése?
# =========================
echo
if ask_user "Szeretnéd telepíteni a Chromium böngészőt?" "y"; then
  CHROMIUM_PKG=""
  if apt-cache show chromium >/dev/null 2>&1; then
    CHROMIUM_PKG="chromium"
  elif apt-cache show chromium-browser >/dev/null 2>&1; then
    CHROMIUM_PKG="chromium-browser"
  fi

  if [ -z "$CHROMIUM_PKG" ]; then
    echo -e "\e[33mNem található Chromium csomag az APT-ben. Lehet, hogy tároló kell, vagy kézi telepítés.\e[0m"
  else
    echo -e "\e[90mChromium telepítése folyamatban (ez eltarthat egy ideig), kérlek várj...\e[0m"
    sudo apt install --no-install-recommends -y "$CHROMIUM_PKG" > /dev/null 2>&1 &
    spinner $! "Chromium telepítése..."
  fi
fi

# =========================
# 5) greetd telepítése és beállítása? (LightDM <-> greetd váltó)
# =========================
echo
if ask_user "Szeretnéd telepíteni és használni a greetd-t (kioszk labwc autologin)?" "n"; then
  # --- Y ág: greetd bekapcs, lightdm kikapcs ---
  echo -e "\e[90mLightDM leállítása és letiltása (ha fut/telepítve van)...\e[0m"
  sudo systemctl disable --now lightdm > /dev/null 2>&1 || true

  echo -e "\e[90mgreetd telepítése folyamatban...\e[0m"
  sudo apt install -y greetd > /dev/null 2>&1 &
  spinner $! "greetd telepítése..."

  echo -e "\e[90m/etc/greetd/config.toml létrehozása vagy felülírása...\e[0m"
  sudo mkdir -p /etc/greetd
  sudo bash -c "cat <<EOL > /etc/greetd/config.toml
[terminal]
vt = 7
[default_session]
command = \"/usr/bin/labwc\"
user = \"$CURRENT_USER\"
EOL"

  echo -e "\e[32m✔\e[0m /etc/greetd/config.toml frissítve!"

  echo -e "\e[90mgreetd szolgáltatás engedélyezése és indítása...\e[0m"
  sudo systemctl enable --now greetd > /dev/null 2>&1 &
  spinner $! "greetd enable --now..."

  echo -e "\e[90mGrafikus target beállítása alapértelmezettként...\e[0m"
  sudo systemctl set-default graphical.target > /dev/null 2>&1 &
  spinner $! "Graphical target beállítása..."

else
  # --- N ág: greetd kikapcs, lightdm vissza ---
  echo -e "\e[90mgreetd leállítása és letiltása (ha telepítve van)...\e[0m"
  sudo systemctl disable --now greetd > /dev/null 2>&1 || true

  echo -e "\e[90mLightDM engedélyezése és indítása (ha telepítve van)...\e[0m"
  sudo systemctl enable --now lightdm > /dev/null 2>&1 || true

  echo -e "\e[90mGrafikus target beállítása alapértelmezettként...\e[0m"
  sudo systemctl set-default graphical.target > /dev/null 2>&1 || true
  echo -e "\e[32m✔\e[0m LightDM mód visszaállítva (ahol elérhető)."

  # --- EXTRA: greetd csomag törlése N esetén (opcionális) ---
  if dpkg -s greetd >/dev/null 2>&1; then
    echo
    if ask_user "Szeretnéd eltávolítani a greetd csomagot is (purge)?" "y"; then
      echo -e "\e[90mgreetd eltávolítása (purge)...\e[0m"
      sudo apt purge -y greetd > /dev/null 2>&1 &
      spinner $! "greetd purge..."

      echo -e "\e[90mFelesleges csomagok takarítása (autoremove)...\e[0m"
      sudo apt autoremove -y > /dev/null 2>&1 &
      spinner $! "autoremove..."

      echo -e "\e[32m✔\e[0m greetd eltávolítva."
    fi
  fi
fi

# =========================
# Segédscript létrehozása a Chromium kioszk váltásához
# =========================
write_kiosk_browser_helper() {
  local main_url="$1"
  local idle_url="$2"
  local idle_enabled="$3"
  local incognito_mode="$4"
  local use_net_wait="$5"
  local ping_host="$6"
  local max_wait="$7"
  local chromium_bin="$8"

  local main_url_escaped idle_url_escaped chromium_bin_escaped ping_host_escaped
  local tmp_file

  main_url_escaped=$(printf "%s" "$main_url" | sed -e "s/'/'\\''/g" -e "s/[&|]/\\&/g")
  idle_url_escaped=$(printf "%s" "$idle_url" | sed -e "s/'/'\\''/g" -e "s/[&|]/\\&/g")
  chromium_bin_escaped=$(printf "%s" "$chromium_bin" | sed -e "s/'/'\\''/g" -e "s/[&|]/\\&/g")
  ping_host_escaped=$(printf "%s" "$ping_host" | sed -e "s/'/'\\''/g" -e "s/[&|]/\\&/g")
  tmp_file=$(mktemp)

  cat > "$tmp_file" <<'EOF'
#!/bin/bash
set -e

MODE="${1:-work}"
STATE_FILE="/tmp/kiosk-browser-mode"
MAIN_URL='__MAIN_URL__'
IDLE_URL='__IDLE_URL__'
IDLE_ENABLED=__IDLE_ENABLED__
INCOGNITO_MODE=__INCOGNITO_MODE__
USE_NET_WAIT=__USE_NET_WAIT__
PING_HOST='__PING_HOST__'
MAX_WAIT=__MAX_WAIT__
CHROMIUM_BIN='__CHROMIUM_BIN__'

wait_for_network() {
  if [ "$USE_NET_WAIT" != "y" ]; then
    return 0
  fi

  local ok=0
  local i
  for i in $(seq 1 "$MAX_WAIT"); do
    if ping -c 1 -W 2 "$PING_HOST" > /dev/null 2>&1; then
      ok=1
      sleep 2
      break
    fi
    sleep 1
  done

  if [ "$ok" -ne 1 ]; then
    echo "[KIOSK] FIGYELEM: nincs hálózat $MAX_WAIT mp után sem, a Chromium így is indul." >&2
    sleep 2
  fi
}

start_browser() {
  local target_url="$1"
  local flags=()

  flags+=(--autoplay-policy=no-user-gesture-required)
  flags+=(--enable-features=UseOzonePlatform)
  flags+=(--ozone-platform=wayland)
  flags+=(--no-first-run)
  flags+=(--simulate-outdated-no-au)
  flags+=(--disable-features=TranslateUI,Translate)

  if [ "$INCOGNITO_MODE" = "y" ]; then
    flags+=(--incognito)
  fi

  flags+=(--kiosk "$target_url")

  nohup "$CHROMIUM_BIN" "${flags[@]}" > /tmp/kiosk-browser.log 2>&1 &
}

case "$MODE" in
  work)
    TARGET_URL="$MAIN_URL"
    ;;
  idle)
    if [ "$IDLE_ENABLED" != "y" ]; then
      exit 0
    fi
    TARGET_URL="$IDLE_URL"
    ;;
  *)
    echo "Ismeretlen mód: $MODE" >&2
    exit 1
    ;;
esac

if [ -f "$STATE_FILE" ] && [ "$(cat "$STATE_FILE")" = "$MODE" ]; then
  if pgrep -af chromium | grep -q -- '--kiosk'; then
    exit 0
  fi
fi

echo "$MODE" > "$STATE_FILE"
pkill -f 'chromium.*--kiosk' > /dev/null 2>&1 || true
pkill -f 'chromium-browser.*--kiosk' > /dev/null 2>&1 || true
sleep 1
wait_for_network
start_browser "$TARGET_URL"
EOF

  MAIN_URL_ESCAPED="$main_url_escaped" \
  IDLE_URL_ESCAPED="$idle_url_escaped" \
  IDLE_ENABLED_VALUE="$idle_enabled" \
  INCOGNITO_MODE_VALUE="$incognito_mode" \
  USE_NET_WAIT_VALUE="$use_net_wait" \
  PING_HOST_ESCAPED="$ping_host_escaped" \
  MAX_WAIT_VALUE="$max_wait" \
  CHROMIUM_BIN_ESCAPED="$chromium_bin_escaped" \
  python3 - "$tmp_file" <<'PYCODE'
from pathlib import Path
import os
import sys

path = Path(sys.argv[1])
text = path.read_text()
replacements = {
    '__MAIN_URL__': os.environ['MAIN_URL_ESCAPED'],
    '__IDLE_URL__': os.environ['IDLE_URL_ESCAPED'],
    '__IDLE_ENABLED__': os.environ['IDLE_ENABLED_VALUE'],
    '__INCOGNITO_MODE__': os.environ['INCOGNITO_MODE_VALUE'],
    '__USE_NET_WAIT__': os.environ['USE_NET_WAIT_VALUE'],
    '__PING_HOST__': os.environ['PING_HOST_ESCAPED'],
    '__MAX_WAIT__': os.environ['MAX_WAIT_VALUE'],
    '__CHROMIUM_BIN__': os.environ['CHROMIUM_BIN_ESCAPED'],
}
for key, value in replacements.items():
    text = text.replace(key, value)
path.write_text(text)
PYCODE

  sudo install -m 755 "$tmp_file" "$KIOSK_BROWSER_HELPER"
  rm -f "$tmp_file"
}

write_chromium_translate_policy() {
  local policy_dir="/etc/chromium/policies/managed"
  local policy_file="$policy_dir/99-kiosk-disable-translate.json"
  local tmp_file

  tmp_file=$(mktemp)
  cat > "$tmp_file" <<'EOF'
{
  "TranslateEnabled": false
}
EOF

  sudo mkdir -p "$policy_dir"
  sudo install -m 644 "$tmp_file" "$policy_file"
  rm -f "$tmp_file"
}


write_kiosk_netwatch_script() {
  local script_path="/usr/local/bin/kiosk-netwatch.sh"
  local tmp_file

  tmp_file=$(mktemp)
  cat > "$tmp_file" <<'EOF'
#!/bin/bash
set -u

CONFIG_FILE="/etc/default/kiosk-netwatch"

if [ -f "$CONFIG_FILE" ]; then
  # shellcheck disable=SC1091
  . "$CONFIG_FILE"
fi

CHECK_INTERVAL_SECONDS="${CHECK_INTERVAL_SECONDS:-30}"
REBOOT_AFTER_MINUTES="${REBOOT_AFTER_MINUTES:-5}"
PING_TARGETS="${PING_TARGETS:-1.1.1.1 8.8.8.8}"
HTTP_CHECK_URL="${HTTP_CHECK_URL:-https://connectivitycheck.gstatic.com/generate_204}"
LOG_TAG="kiosk-netwatch"

log_msg() {
  logger -t "$LOG_TAG" -- "$1"
}

check_network() {
  local target

  for target in $PING_TARGETS; do
    if ping -c 1 -W 3 "$target" >/dev/null 2>&1; then
      return 0
    fi
  done

  if command -v curl >/dev/null 2>&1; then
    if curl -fsSIL --max-time 8 "$HTTP_CHECK_URL" >/dev/null 2>&1; then
      return 0
    fi
  elif command -v wget >/dev/null 2>&1; then
    if wget -q --spider --timeout=8 "$HTTP_CHECK_URL" >/dev/null 2>&1; then
      return 0
    fi
  fi

  return 1
}

main() {
  local failure_since=0
  local now
  local reboot_after_seconds

  reboot_after_seconds=$((REBOOT_AFTER_MINUTES * 60))
  if [ "$reboot_after_seconds" -lt "$CHECK_INTERVAL_SECONDS" ]; then
    reboot_after_seconds="$CHECK_INTERVAL_SECONDS"
  fi

  log_msg "Elindult. Ellenőrzés ${CHECK_INTERVAL_SECONDS} mp-enként, reboot ${REBOOT_AFTER_MINUTES} perc folyamatos internetkimaradás után."

  while true; do
    if check_network; then
      if [ "$failure_since" -ne 0 ]; then
        log_msg "Internetkapcsolat helyreállt, hibaszámláló nullázva."
        failure_since=0
      fi
    else
      now=$(date +%s)
      if [ "$failure_since" -eq 0 ]; then
        failure_since="$now"
        log_msg "Internetkapcsolat nem elérhető, megkezdődött a visszaszámlálás."
      elif [ $((now - failure_since)) -ge "$reboot_after_seconds" ]; then
        log_msg "Internetkapcsolat ${REBOOT_AFTER_MINUTES} perce nem érhető el, rendszer újraindítása."
        /usr/bin/systemctl reboot
        exit 0
      fi
    fi

    sleep "$CHECK_INTERVAL_SECONDS"
  done
}

main
EOF

  sudo install -m 755 "$tmp_file" "$script_path"
  rm -f "$tmp_file"
}

write_kiosk_netwatch_config() {
  local reboot_after_minutes="$1"
  local config_path="/etc/default/kiosk-netwatch"
  local tmp_file

  tmp_file=$(mktemp)
  cat > "$tmp_file" <<EOF
# Kiosk internet watchdog beállítások
# Ezt a fájlt a kiosk setup script kezeli.
CHECK_INTERVAL_SECONDS=30
REBOOT_AFTER_MINUTES=${reboot_after_minutes}
PING_TARGETS="1.1.1.1 8.8.8.8"
HTTP_CHECK_URL="https://connectivitycheck.gstatic.com/generate_204"
EOF

  sudo install -m 644 "$tmp_file" "$config_path"
  rm -f "$tmp_file"
}

write_kiosk_netwatch_service() {
  local service_path="/etc/systemd/system/kiosk-netwatch.service"
  local tmp_file

  tmp_file=$(mktemp)
  cat > "$tmp_file" <<'EOF'
[Unit]
Description=Kiosk internet watchdog
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/kiosk-netwatch.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  sudo install -m 644 "$tmp_file" "$service_path"
  rm -f "$tmp_file"
}

disable_kiosk_netwatch() {
  local service_path="/etc/systemd/system/kiosk-netwatch.service"
  local config_path="/etc/default/kiosk-netwatch"
  local script_path="/usr/local/bin/kiosk-netwatch.sh"

  sudo systemctl disable --now kiosk-netwatch.service >/dev/null 2>&1 || true
  sudo rm -f "$service_path" "$config_path" "$script_path"
  sudo systemctl daemon-reload >/dev/null 2>&1 || true
  sudo systemctl reset-failed kiosk-netwatch.service >/dev/null 2>&1 || true
}

# =========================
# 6) Internet watchdog szolgáltatás beállítása?
# - külön systemd service + config, újrafuttatáskor ki/bekapcsolható
# =========================
echo
if ask_user "Szeretnéd bekapcsolni az internet ellenőrző szolgáltatást?" "y"; then
  NETWATCH_REBOOT_AFTER_MINUTES="$(ask_positive_integer "Hány perc folyamatos internetkimaradás után induljon újra a gép" "20")"

  write_kiosk_netwatch_script
  write_kiosk_netwatch_config "$NETWATCH_REBOOT_AFTER_MINUTES"
  write_kiosk_netwatch_service

  sudo systemctl daemon-reload >/dev/null 2>&1
  sudo systemctl enable --now kiosk-netwatch.service >/dev/null 2>&1 &
  spinner $! "Internet watchdog szolgáltatás engedélyezése..."

  echo -e "\e[32m✔\e[0m Internet watchdog engedélyezve: ${NETWATCH_REBOOT_AFTER_MINUTES} perc folyamatos netkimaradás után teljes rendszer reboot."
else
  disable_kiosk_netwatch
  echo -e "\e[32m✔\e[0m Internet watchdog kikapcsolva és eltávolítva."
fi

# =========================
# 7) labwc autostart: Chromium indítás (KIOSKPARANCS blokkba, memóriából)
# =========================
echo
if ask_user "Szeretnél Chromium autostartot létrehozni labwc-hez?" "y"; then
  read -p "Add meg a Chromiumban megnyitandó URL-t [alapértelmezett: http://192.168.1.40:18006]: " USER_URL
  USER_URL="${USER_URL:-http://192.168.1.40:18006}"

  echo
  INCOGNITO_MODE="n"
  if ask_user "Induljon a böngésző inkognitó módban?" "n"; then
    INCOGNITO_MODE="y"
  fi

  echo
  USE_NET_WAIT="n"
  if ask_user "Várjon hálózati kapcsolatra a Chromium indítása előtt?" "n"; then
    USE_NET_WAIT="y"
  fi

  PING_HOST="1.1.1.1"
  MAX_WAIT="30"
  if [ "$USE_NET_WAIT" = "y" ]; then
    read -p "Add meg a pingelendő hostot a hálózati ellenőrzéshez [alapértelmezett: 1.1.1.1]: " PING_HOST_IN
    PING_HOST="${PING_HOST_IN:-1.1.1.1}"
    MAX_WAIT="$(ask_positive_integer "Add meg a maximális várakozási időt másodpercben" "30")"
  fi

  echo
  IDLE_MODE="n"
  if ask_user "Szeretnéd bekapcsolni az idle képernyőt?" "y"; then
    IDLE_MODE="y"

    if ! command -v swayidle > /dev/null 2>&1; then
      echo -e "\e[90mswayidle telepítése folyamatban, kérlek várj...\e[0m"
      sudo apt install --no-install-recommends -y swayidle > /dev/null 2>&1 &
      spinner $! "swayidle telepítése..."
    fi

    read -p "Add meg az idle képernyő URL-jét [alapértelmezett: https://kiosk.athq.cc]: " IDLE_URL
    IDLE_URL="${IDLE_URL:-https://kiosk.athq.cc}"
    IDLE_TIMEOUT="$(ask_positive_integer "Add meg az idle várakozási időt másodpercben" "20")"
  else
    IDLE_URL="https://kiosk.athq.cc"
    IDLE_TIMEOUT="20"
  fi

  CHROMIUM_BIN="$(command -v chromium || command -v chromium-browser || true)"
  if [ -z "$CHROMIUM_BIN" ]; then
    if [ -x "/usr/bin/chromium" ]; then
      CHROMIUM_BIN="/usr/bin/chromium"
    elif [ -x "/usr/bin/chromium-browser" ]; then
      CHROMIUM_BIN="/usr/bin/chromium-browser"
    else
      CHROMIUM_BIN="/usr/bin/chromium"
      echo -e "\e[33mFigyelmeztetés: nem található Chromium bináris. Autostartban ez lesz: $CHROMIUM_BIN (ha kell, később javítsd).\e[0m"
    fi
  fi

  write_kiosk_browser_helper "$USER_URL" "$IDLE_URL" "$IDLE_MODE" "$INCOGNITO_MODE" "$USE_NET_WAIT" "$PING_HOST" "$MAX_WAIT" "$CHROMIUM_BIN"
  echo -e "\e[32m✔\e[0m Kioszk böngésző segédscript frissítve: $KIOSK_BROWSER_HELPER"

  write_chromium_translate_policy
  echo -e "\e[32m✔\e[0m Chromium fordítás letiltó policy frissítve: /etc/chromium/policies/managed/99-kiosk-disable-translate.json"

  AUTOSTART_NEEDS_UPDATE="y"
  if [ -z "$AUTOSTART_BLOCK" ]; then
    AUTOSTART_BLOCK+="# labwc autostart - kioszk beállítások
"
    AUTOSTART_BLOCK+="# Ezt a blokkot a kiosk setup script kezeli, kézzel ne szerkeszd a blokk két jelzője között.
"
    AUTOSTART_BLOCK+="
"
  fi

  AUTOSTART_BLOCK+="# Chromium indítása kioszk módban
"
  AUTOSTART_BLOCK+="${KIOSK_BROWSER_HELPER} work &
"

  if [ "$IDLE_MODE" = "y" ]; then
    AUTOSTART_BLOCK+="
"
    AUTOSTART_BLOCK+="# Idle képernyő kezelése inaktivitás esetén
"
    AUTOSTART_BLOCK+="(sleep 8 && swayidle -w timeout ${IDLE_TIMEOUT} '${KIOSK_BROWSER_HELPER} idle' resume '${KIOSK_BROWSER_HELPER} work') >/dev/null 2>&1 &
"
  fi

  AUTOSTART_BLOCK+="
"
fi

# =========================
# 8) Egérkurzor elrejtése (wtype) - autostart blokkba
# =========================
echo
LABWC_CONFIG_DIR="$HOME_DIR/.config/labwc"
mkdir -p "$LABWC_CONFIG_DIR"
RC_XML="$LABWC_CONFIG_DIR/rc.xml"

if ask_user "Szeretnéd elrejteni az egérkurzort kioszk módban?" "y"; then
  if ! command -v wtype > /dev/null 2>&1; then
    echo -e "\e[90mwtype telepítése folyamatban, kérlek várj...\e[0m"
    sudo apt install -y wtype > /dev/null 2>&1 &
    spinner $! "wtype telepítése..."
  fi

  echo -e "\e[90mHideCursor billentyűparancs beállítása az rc.xml-ben...\e[0m"
  update_labwc_rcxml_hidecursor "$RC_XML" "enable"
  echo -e "\e[32m✔\e[0m HideCursor billentyűparancs beállítva: $RC_XML"

  AUTOSTART_NEEDS_UPDATE="y"
  if [ -z "$AUTOSTART_BLOCK" ]; then
    AUTOSTART_BLOCK+="# labwc autostart - kioszk beállítások\n"
    AUTOSTART_BLOCK+="# Ezt a blokkot a kiosk setup script kezeli, kézzel ne szerkeszd a blokk két jelzője között.\n"
    AUTOSTART_BLOCK+="\n"
  fi

  AUTOSTART_BLOCK+="# Kurzor elrejtése indításkor (Win+H billentyű szimulálása)\n"
  AUTOSTART_BLOCK+="(sleep 5 && wtype -M logo -k h -m logo) &\n"
  AUTOSTART_BLOCK+="\n"
else
  echo -e "\e[90mHideCursor beállítás eltávolítása az rc.xml-ből (ha létezett)...\e[0m"
  update_labwc_rcxml_hidecursor "$RC_XML" "disable"

  AUTOSTART_NEEDS_UPDATE="y"
fi

# =========================
# 9) Splash képernyő telepítése?
# - config.txt: KIOSKPARANCS blokkba memóriából
# - cmdline.txt: paraméter szinten beállítjuk a végén
# =========================
echo
if ask_user "Szeretnéd telepíteni a splash képernyőt?" "y"; then
  echo -e "\e[90mSplash képernyő és témák telepítése folyamatban (ez eltarthat), kérlek várj...\e[0m"
  sudo apt-get install -y plymouth plymouth-themes pix-plym-splash > /dev/null 2>&1 &
  spinner $! "Splash telepítése..."

  if [ ! -e /usr/share/plymouth/themes/pix/pix.script ]; then
    echo -e "\e[33mFigyelmeztetés: a pix téma nem található. Splash lehet nem működik megfelelően.\e[0m"
  else
    echo -e "\e[90mSplash téma beállítása pix-re...\e[0m"
    sudo plymouth-set-default-theme pix > /dev/null 2>&1 || true

    echo -e "\e[90mEgyedi splash logó letöltése...\e[0m"
    SPLASH_URL="https://raw.githubusercontent.com/MISIKEX/rpi-kiosk/main/_assets/splashscreens/splash.png"
    SPLASH_PATH="/usr/share/plymouth/themes/pix/splash.png"

    if sudo wget -q "$SPLASH_URL" -O "$SPLASH_PATH"; then
      echo -e "\e[32m✔\e[0m Egyedi splash logó telepítve."
    else
      echo -e "\e[33mFigyelmeztetés: nem sikerült letölteni az egyedi splash logót. Marad az alapértelmezett.\e[0m"
    fi

    sudo update-initramfs -u > /dev/null 2>&1 &
    spinner $! "initramfs frissítése..."
  fi

  CONFIG_NEEDS_UPDATE="y"
  if [ -z "$CONFIG_BLOCK" ]; then
    CONFIG_BLOCK+="# Raspberry Pi kioszk beállítások\n"
    CONFIG_BLOCK+="# Ezt a blokkot a kiosk setup script kezeli, kézzel ne szerkeszd a blokk két jelzője között.\n"
    CONFIG_BLOCK+="\n"
  fi
  CONFIG_BLOCK+="# Splash képernyő engedélyezése / beállítása\n"
  CONFIG_BLOCK+="disable_splash=1\n"
  CONFIG_BLOCK+="\n"

  CMDLINE_NEEDS_SPLASH="y"
  CMDLINE_NEEDS_CONSOLE_TTY3="y"
fi

# =========================
# 10) Képernyőfelbontás beállítása?
# - cmdline.txt: video= paraméter érték (a végén cseréljük)
# - autostart: wlr-randr sor blokkba
# =========================
echo
if ask_user "Szeretnéd beállítani a képernyőfelbontást (cmdline.txt + labwc autostart)?" "y"; then
  if ! command -v edid-decode > /dev/null 2>&1; then
    echo -e "\e[90mSzükséges eszköz (edid-decode) telepítése, kérlek várj...\e[0m"
    sudo apt install -y edid-decode > /dev/null 2>&1 &
    spinner $! "edid-decode telepítése..."
  fi

  EDID_PATH=""
  if [ -r /sys/class/drm/card1-HDMI-A-1/edid ]; then
    EDID_PATH="/sys/class/drm/card1-HDMI-A-1/edid"
  elif [ -r /sys/class/drm/card0-HDMI-A-1/edid ]; then
    EDID_PATH="/sys/class/drm/card0-HDMI-A-1/edid"
  fi

  available_resolutions=()
  if [ -n "$EDID_PATH" ]; then
    edid_output="$(sudo cat "$EDID_PATH" | edid-decode 2>/dev/null || true)"
    while IFS= read -r line; do
      if [[ "$line" =~ ([0-9]+)x([0-9]+)[[:space:]]+([0-9]+\.[0-9]+|[0-9]+)\ Hz ]]; then
        resolution="${BASH_REMATCH[1]}x${BASH_REMATCH[2]}"
        frequency="${BASH_REMATCH[3]}"
        available_resolutions+=("${resolution}@${frequency}")
      fi
    done <<< "$edid_output"
  fi

  if [ ${#available_resolutions[@]} -eq 0 ]; then
    echo -e "\e[33mNem találtam EDID felbontásokat. Alapértelmezett listát használok.\e[0m"
    available_resolutions=("1920x1080@60" "1280x720@60" "1024x768@60" "1600x900@60" "1366x768@60")
  fi

  echo -e "\e[94mKérlek válassz felbontást (számot írj):\e[0m"
  select RESOLUTION in "${available_resolutions[@]}"; do
    if [[ -n "$RESOLUTION" ]]; then
      echo -e "\e[32mKiválasztva: $RESOLUTION\e[0m"
      break
    else
      echo -e "\e[33mÉrvénytelen választás, próbáld újra.\e[0m"
    fi
  done

  CMDLINE_VIDEO_VALUE="HDMI-A-1:${RESOLUTION}"

  AUTOSTART_NEEDS_UPDATE="y"
  if [ -z "$AUTOSTART_BLOCK" ]; then
    AUTOSTART_BLOCK+="# labwc autostart - kioszk beállítások\n"
    AUTOSTART_BLOCK+="# Ezt a blokkot a kiosk setup script kezeli, kézzel ne szerkeszd a blokk két jelzője között.\n"
    AUTOSTART_BLOCK+="\n"
  fi

  AUTOSTART_BLOCK+="# Képernyőfelbontás beállítása\n"
  AUTOSTART_BLOCK+="wlr-randr --output HDMI-A-1 --mode ${RESOLUTION}\n"
  AUTOSTART_BLOCK+="\n"
fi

# =========================
# 11) Képernyő elforgatása?
# - autostart: wlr-randr transform sor blokkba
# =========================
echo
if ask_user "Szeretnéd beállítani a képernyő elforgatását?" "n"; then
  echo -e "\e[94mKérlek válassz tájolást:\e[0m"
  orientations=("normal (0°)" "90° jobbra" "180°" "270° jobbra")
  transform_values=("normal" "90" "180" "270")

  select orientation in "${orientations[@]}"; do
    if [[ -n "$orientation" ]]; then
      idx=$((REPLY - 1))
      TRANSFORM="${transform_values[$idx]}"
      echo -e "\e[32mKiválasztva: $orientation\e[0m"
      break
    else
      echo -e "\e[33mÉrvénytelen választás, próbáld újra.\e[0m"
    fi
  done

  AUTOSTART_NEEDS_UPDATE="y"
  if [ -z "$AUTOSTART_BLOCK" ]; then
    AUTOSTART_BLOCK+="# labwc autostart - kioszk beállítások\n"
    AUTOSTART_BLOCK+="# Ezt a blokkot a kiosk setup script kezeli, kézzel ne szerkeszd a blokk két jelzője között.\n"
    AUTOSTART_BLOCK+="\n"
  fi

  AUTOSTART_BLOCK+="# Képernyő elforgatás beállítása\n"
  AUTOSTART_BLOCK+="wlr-randr --output HDMI-A-1 --transform ${TRANSFORM}\n"
  AUTOSTART_BLOCK+="\n"
fi

# =========================
# 12) Hangkimenet HDMI-re kényszerítése?
# - config.txt: KIOSKPARANCS blokkba memóriából
# =========================
echo
if ask_user "Szeretnéd a hangkimenetet HDMI-re kényszeríteni?" "y"; then
  CONFIG_NEEDS_UPDATE="y"
  if [ -z "$CONFIG_BLOCK" ]; then
    CONFIG_BLOCK+="# Raspberry Pi kioszk beállítások\n"
    CONFIG_BLOCK+="# Ezt a blokkot a kiosk setup script kezeli, kézzel ne szerkeszd a blokk két jelzője között.\n"
    CONFIG_BLOCK+="\n"
  fi
  CONFIG_BLOCK+="# Hang: HDMI kimenet kényszerítése\n"
  CONFIG_BLOCK+="dtparam=audio=off\n"
  CONFIG_BLOCK+="\n"
fi

# =========================
# 13) TV távirányító (HDMI-CEC) támogatás engedélyezése?
# =========================
echo
if ask_user "Szeretnéd engedélyezni a TV távirányítót HDMI-CEC-en keresztül?" "n"; then
  echo -e "\e[90mCEC segédprogramok telepítése folyamatban, kérlek várj...\e[0m"
  sudo apt-get install -y ir-keytable v4l-utils > /dev/null 2>&1 &
  spinner $! "CEC segédprogramok telepítése..."

  echo -e "\e[90mEgyedi CEC billentyűtérkép létrehozása...\e[0m"
  sudo mkdir -p /etc/rc_keymaps

  sudo bash -c "cat > /etc/rc_keymaps/custom-cec.toml" << 'EOL'
[[protocols]]
name = "custom_cec"
protocol = "cec"
[protocols.scancodes]
0x00 = "KEY_ENTER"
0x01 = "KEY_UP"
0x02 = "KEY_DOWN"
0x03 = "KEY_LEFT"
0x04 = "KEY_RIGHT"
0x09 = "KEY_EXIT"
0x0d = "KEY_BACK"
0x44 = "KEY_PLAYPAUSE"
0x45 = "KEY_STOPCD"
0x46 = "KEY_PAUSECD"
EOL

  echo -e "\e[32m✔\e[0m Egyedi CEC billentyűtérkép létrehozva!"

  echo -e "\e[90mCEC beállító wrapper script létrehozása...\e[0m"
  sudo bash -c "cat > /usr/local/bin/cec-setup.sh" << 'EOL'
#!/bin/bash
set -e

# 1) CEC eszköz detektálás: első létező /dev/cec*
CEC_DEV=""
for dev in /dev/cec*; do
  if [ -e "$dev" ]; then
    CEC_DEV="$dev"
    break
  fi
done

if [ -z "$CEC_DEV" ]; then
  echo "HIBA: Nem található /dev/cec* eszköz."
  exit 1
fi

# 2) rc eszköz detektálás: első ir-keytable által listázott rcX (rc0, rc1...)
RC_DEV=""
if command -v ir-keytable >/dev/null 2>&1; then
  RC_DEV=$(ir-keytable -l 2>/dev/null | grep -o 'rc[0-9]\+' | head -n 1 || true)
fi

if [ -z "$RC_DEV" ]; then
  RC_DEV="rc0"
fi

# 3) CEC beállítások
/usr/bin/cec-ctl -d "$CEC_DEV" --playback
sleep 2
/usr/bin/cec-ctl -d "$CEC_DEV" --active-source phys-addr=1.0.0.0
sleep 1

# 4) Keymap betöltése
/usr/bin/ir-keytable -c -s "$RC_DEV" -w /etc/rc_keymaps/custom-cec.toml

exit 0
EOL

  sudo chmod +x /usr/local/bin/cec-setup.sh
  echo -e "\e[32m✔\e[0m CEC wrapper script létrehozva: /usr/local/bin/cec-setup.sh"

  echo -e "\e[90mCEC systemd szolgáltatás létrehozása...\e[0m"
  sudo bash -c "cat > /etc/systemd/system/cec-setup.service" << 'EOL'
[Unit]
Description=CEC Remote Control Setup
After=multi-user.target
Before=graphical.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/cec-setup.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOL

  sudo systemctl daemon-reload > /dev/null 2>&1

  echo -e "\e[90mCEC szolgáltatás engedélyezése...\e[0m"
  sudo systemctl enable cec-setup.service > /dev/null 2>&1 &
  spinner $! "CEC szolgáltatás engedélyezése..."

  echo -e "\e[32m✔\e[0m HDMI-CEC távirányító támogatás beállítva!"
  echo -e "\e[90mMegjegyzés: a TV-n engedélyezd a HDMI-CEC-et (SimpLink/Anynet+/Bravia Sync).\e[0m"
fi

# =========================
# VÉGÉN: fájlmódosítások EGYBEN
# =========================

# 1) labwc autostart KIOSKPARANCS blokk kiírása (ha kellett)
if [ "$AUTOSTART_NEEDS_UPDATE" = "y" ]; then
  if [ -n "$AUTOSTART_BLOCK" ]; then
    write_kiosk_block "$LABWC_AUTOSTART_FILE" "$AUTOSTART_BLOCK"
    echo -e "\e[32m✔\e[0m labwc autostart frissítve (KIOSKPARANCS blokk): $LABWC_AUTOSTART_FILE"
  else
    remove_kiosk_block "$LABWC_AUTOSTART_FILE"
    echo -e "\e[32m✔\e[0m labwc autostart KIOSKPARANCS blokk eltávolítva: $LABWC_AUTOSTART_FILE"
  fi
fi

# 2) config.txt KIOSKPARANCS blokk kiírása (ha kellett)
if [ "$CONFIG_NEEDS_UPDATE" = "y" ]; then
  write_kiosk_block "$BOOT_CONFIG" "$CONFIG_BLOCK"
  echo -e "\e[32m✔\e[0m boot config frissítve (KIOSKPARANCS blokk): $BOOT_CONFIG"
fi

# 3) cmdline.txt paraméter-szintű módosítások (ha kellett)
if [ "$CMDLINE_NEEDS_SPLASH" = "y" ] || [ "$CMDLINE_NEEDS_CONSOLE_TTY3" = "y" ] || [ -n "$CMDLINE_VIDEO_VALUE" ]; then
  if [ -f "$BOOT_CMDLINE" ]; then
    if [ "$CMDLINE_NEEDS_SPLASH" = "y" ]; then
      cmdline_ensure_flag "$BOOT_CMDLINE" "quiet"
      cmdline_ensure_flag "$BOOT_CMDLINE" "splash"
      cmdline_ensure_flag "$BOOT_CMDLINE" "plymouth.ignore-serial-consoles"
    fi
    if [ "$CMDLINE_NEEDS_CONSOLE_TTY3" = "y" ]; then
      cmdline_set_key_value "$BOOT_CMDLINE" "console" "tty3"
    fi
    if [ -n "$CMDLINE_VIDEO_VALUE" ]; then
      cmdline_set_key_value "$BOOT_CMDLINE" "video" "$CMDLINE_VIDEO_VALUE"
    fi
    echo -e "\e[32m✔\e[0m cmdline.txt frissítve (paraméter-szinten): $BOOT_CMDLINE"
  else
    echo -e "\e[33mFigyelmeztetés: $BOOT_CMDLINE nem található, cmdline módosítás kihagyva.\e[0m"
  fi
fi

# =========================
# apt gyorsítótárak takarítása
# =========================
echo -e "\e[90mAPT gyorsítótárak takarítása, kérlek várj...\e[0m"
sudo apt clean > /dev/null 2>&1 &
spinner $! "APT gyorsítótárak takarítása..."

# =========================
# Befejezés + újraindítás felajánlása
# =========================
echo -e "\e[32m✔\e[0m \e[32mA beállítás sikeresen befejeződött!\e[0m"
echo
if ask_user "Szeretnéd most újraindítani a rendszert?" "y"; then
  echo -e "\e[90mRendszer újraindítása...\e[0m"
  sudo reboot
else
  echo -e "\e[33mNe felejtsd el manuálisan újraindítani a rendszert, hogy minden változás érvénybe lépjen.\e[0m"
fi
