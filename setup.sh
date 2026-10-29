#!/data/data/com.termux/files/usr/bin/bash
# pad6-lab: one-shot, no-typing installer for Termux + Termux:X11
#   Linux  : Debian + XFCE + VS Code + Miniforge(conda/Jupyter)
#   Windows: QEMU VM (unattended install from an ISO)
# Usage: bash setup.sh [menu|linux|windows|both|run-linux|run-windows]
# Config (optional): ~/.padlab.conf   (ISO_URL, WIN_RAM, WIN_CORES, WIN_DISK, WIN_ARCH, UNATTENDED)

LAB="$HOME/.padlab"; CONF="$HOME/.padlab.conf"; WIN="$HOME/winvm"; SHARE="$HOME/winshare"
mkdir -p "$LAB" "$WIN" "$SHARE"
if [ ! -f "$CONF" ]; then cat > "$CONF" <<'C'
# Direct link to a Windows ISO (7/10/Tiny/Atom...). Leave empty to use an ISO you copied
# into ~/winvm or /sdcard/Download.
#ISO_URL=""
#WIN_RAM=2048
#WIN_CORES=4
#WIN_DISK=32G
#WIN_ARCH=amd64     # use x86 for 32-bit ISOs
#UNATTENDED=1       # 1 = auto-answer Windows setup (user "User", password "User")
C
fi
# shellcheck disable=SC1090
. "$CONF"
: "${ISO_URL:=}" "${WIN_RAM:=2048}" "${WIN_CORES:=4}" "${WIN_DISK:=32G}" "${WIN_ARCH:=amd64}" "${UNATTENDED:=1}"

log()   { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn()  { printf '\033[1;33m!! %s\033[0m\n' "$*"; }
retry() { local n=0; until "$@"; do n=$((n+1)); [ $n -ge 4 ] && return 1; warn "retry $n: $*"; sleep 5; done; }
aptq()  { DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::=--force-confnew "$@"; }

# download with resume + retries; skips if file already there
dl() {
  local url="$1" out="$2" i
  [ -s "$out" ] && return 0
  mkdir -p "$(dirname "$out")"
  for i in 1 2 3 4 5; do
    if curl -fL --retry 3 -C - -o "$out.part" "$url"; then mv "$out.part" "$out"; return 0; fi
    rm -f "$out.part"; sleep 4
  done
  return 1
}

prep_termux() {
  [ -f "$LAB/.base" ] && return 0
  log "Preparing Termux packages"
  termux-wake-lock 2>/dev/null
  retry aptq update
  retry aptq upgrade
  retry aptq install x11-repo
  retry aptq update
  retry aptq install termux-x11-nightly pulseaudio curl wget proot-distro && touch "$LAB/.base"
}

has_x11_app() {
  local out; out="$( (pm list packages 2>/dev/null || cmd package list packages 2>/dev/null) )"
  [ -z "$out" ] && return 0            # cannot tell -> assume installed
  echo "$out" | grep -q com.termux.x11
}
ensure_x11_app() {
  has_x11_app && return 0
  log "Termux:X11 app missing - downloading APK (tap Install when prompted)"
  local apk="$HOME/termux-x11.apk"
  dl "https://github.com/termux/termux-x11/releases/download/nightly/app-arm64-v8a-debug.apk" "$apk" \
    || { warn "Could not download Termux:X11 APK. Install it manually."; return 1; }
  termux-open "$apk" 2>/dev/null
  local t=0; while [ $t -lt 120 ]; do has_x11_app && return 0; sleep 3; t=$((t+3)); done
  warn "Termux:X11 still not installed."; return 1
}
start_x11() {
  ensure_x11_app
  pkill -f "termux.x11" 2>/dev/null; sleep 1
  nohup termux-x11 :0 >"$LAB/x11.log" 2>&1 &
  sleep 3
  am start --user 0 -n com.termux.x11/com.termux.x11.MainActivity >/dev/null 2>&1
  export DISPLAY=:0
}
start_audio() {
  pgrep pulseaudio >/dev/null 2>&1 || pulseaudio --start --exit-idle-time=-1 \
    --load="module-native-protocol-tcp auth-ip-acl=127.0.0.1 auth-anonymous=1" 2>/dev/null
}

# ---------------------------------------------------------------- LINUX
ROOT="$PREFIX/var/lib/proot-distro/installed-rootfs/debian"

install_linux() {
  prep_termux || { warn "Termux prep failed (network?)"; return 1; }
  if [ ! -d "$ROOT/etc" ]; then
    log "Installing Debian rootfs"
    retry proot-distro install debian || { warn "Debian download failed"; return 1; }
  fi
  if [ -f "$ROOT/home/dev/.padlab-done" ]; then log "Linux already configured"; return 0; fi
  log "Configuring Debian (10-25 min, ~3-4 GB)"
  cat > "$ROOT/root/inner.sh" <<'INNER'
#!/bin/bash
export DEBIAN_FRONTEND=noninteractive
APT="apt-get -y -o Dpkg::Options::=--force-confold"
r() { for i in 1 2 3 4; do "$@" && return 0; sleep 5; done; return 1; }
r $APT update; r $APT full-upgrade
r $APT install sudo wget curl git nano ca-certificates dbus-x11 xfce4 xfce4-terminal thunar mousepad \
  fonts-noto firefox-esr build-essential libgbm1 libasound2 libnss3 libxss1 libgtk-3-0 gnupg
id dev >/dev/null 2>&1 || useradd -m -s /bin/bash -G sudo dev
echo "dev ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/dev
# VS Code (arm64 .deb) - re-download if missing/incomplete
if ! command -v code >/dev/null; then
  for i in 1 2 3 4 5; do
    curl -fL --retry 3 -C - -o /tmp/code.deb "https://code.visualstudio.com/sha/download?build=stable&os=linux-deb-arm64" && break; sleep 4
  done
  r $APT install /tmp/code.deb; rm -f /tmp/code.deb
fi
mkdir -p /home/dev/.config
printf -- '--no-sandbox\n--disable-gpu\n--password-store=basic\n' > /home/dev/.config/code-flags.conf
sed -i 's#^Exec=/usr/share/code/code#Exec=/usr/share/code/code --no-sandbox --disable-gpu#' /usr/share/applications/code*.desktop 2>/dev/null
# Miniforge (conda) for user dev
su - dev -c '
if [ ! -x $HOME/miniforge3/bin/conda ]; then
  for i in 1 2 3 4 5; do curl -fL --retry 3 -C - -o /tmp/mf.sh https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-aarch64.sh && break; sleep 4; done
  bash /tmp/mf.sh -b -p $HOME/miniforge3; rm -f /tmp/mf.sh
  $HOME/miniforge3/bin/conda init bash
fi
$HOME/miniforge3/bin/conda install -y jupyterlab notebook numpy pandas matplotlib scikit-learn ipykernel
$HOME/miniforge3/bin/pip install pysd
code --install-extension ms-python.python --no-sandbox >/dev/null 2>&1
touch $HOME/.padlab-done'
chown -R dev:dev /home/dev
INNER
  proot-distro login debian -- bash /root/inner.sh
  [ -f "$ROOT/home/dev/.padlab-done" ] || { warn "Linux setup incomplete - re-run to resume"; return 1; }
}

run_linux() {
  [ -d "$ROOT/etc" ] || { warn "Linux not installed. Choose install first."; return 1; }
  start_x11; start_audio
  log "Starting Linux desktop in Termux:X11"
  proot-distro login debian --user dev --shared-tmp -- bash -c \
    "export DISPLAY=:0 PULSE_SERVER=127.0.0.1 XDG_RUNTIME_DIR=/tmp; dbus-launch --exit-with-session startxfce4"
}

# -------------------------------------------------------------- WINDOWS
find_iso() {
  local f
  for f in "$WIN"/*.iso "$HOME"/storage/downloads/*.iso /sdcard/Download/*.iso; do
    [ -f "$f" ] && { echo "$f"; return 0; }
  done; return 1
}
write_unattend() {
  cat > "$SHARE/autounattend.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
 <settings pass="windowsPE">
  <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="$WIN_ARCH" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"><SetupUILanguage><UILanguage>en-US</UILanguage></SetupUILanguage><InputLocale>en-US</InputLocale><SystemLocale>en-US</SystemLocale><UILanguage>en-US</UILanguage><UserLocale>en-US</UserLocale></component>
  <component name="Microsoft-Windows-Setup" processorArchitecture="$WIN_ARCH" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
   <DiskConfiguration><WillShowUI>OnError</WillShowUI><Disk wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"><DiskID>0</DiskID><WillWipeDisk>true</WillWipeDisk>
    <CreatePartitions><CreatePartition wcm:action="add"><Order>1</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition></CreatePartitions>
    <ModifyPartitions><ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Active>true</Active><Format>NTFS</Format><Label>Windows</Label></ModifyPartition></ModifyPartitions></Disk></DiskConfiguration>
   <ImageInstall><OSImage><InstallTo><DiskID>0</DiskID><PartitionID>1</PartitionID></InstallTo></OSImage></ImageInstall>
   <UserData><AcceptEula>true</AcceptEula></UserData>
  </component>
 </settings>
 <settings pass="oobeSystem">
  <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="$WIN_ARCH" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
   <OOBE><HideEULAPage>true</HideEULAPage><HideLocalAccountScreen>true</HideLocalAccountScreen><HideOnlineAccountScreens>true</HideOnlineAccountScreens><HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE><ProtectYourPC>3</ProtectYourPC><NetworkLocation>Work</NetworkLocation><SkipMachineOOBE>true</SkipMachineOOBE><SkipUserOOBE>true</SkipUserOOBE></OOBE>
   <UserAccounts><LocalAccounts><LocalAccount wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"><Name>User</Name><Group>Administrators</Group><Password><Value>User</Value><PlainText>true</PlainText></Password></LocalAccount></LocalAccounts></UserAccounts>
   <AutoLogon><Enabled>true</Enabled><Username>User</Username><Password><Value>User</Value><PlainText>true</PlainText></Password><LogonCount>999</LogonCount></AutoLogon>
  </component>
 </settings>
</unattend>
XML
}

install_windows() {
  prep_termux || { warn "Termux prep failed (network?)"; return 1; }
  log "Installing QEMU"
  command -v qemu-system-x86_64 >/dev/null || retry aptq install qemu-system-x86-64 qemu-utils \
    || { warn "QEMU install failed"; return 1; }
  [ -f "$WIN/win.qcow2" ] || qemu-img create -f qcow2 "$WIN/win.qcow2" "$WIN_DISK" >/dev/null
  [ "$UNATTENDED" = 1 ] && write_unattend
  if ! find_iso >/dev/null; then
    if [ -n "$ISO_URL" ]; then
      log "Downloading Windows ISO"
      dl "$ISO_URL" "$WIN/windows.iso" || warn "ISO download failed"
    fi
  fi
  find_iso >/dev/null || {
    warn "No Windows ISO found. Set ISO_URL in $CONF or copy an .iso into $WIN (or /sdcard/Download), then run again."
    return 1; }
  return 0
}

run_windows() {
  command -v qemu-system-x86_64 >/dev/null || { warn "Windows VM not installed."; return 1; }
  local iso disp args
  iso="$(find_iso)"
  case "$(qemu-system-x86_64 -display help 2>&1)" in *sdl*) disp=sdl;; *gtk*) disp=gtk;; *) disp=;; esac
  args=(-machine pc -cpu max -smp "$WIN_CORES" -m "$WIN_RAM" -accel tcg,thread=multi,tb-size=512
        -drive "file=$WIN/win.qcow2,if=ide,index=0,cache=unsafe"
        -drive "file=fat:rw:$SHARE,format=raw,if=ide,index=1"
        -vga std -device e1000,netdev=n -netdev user,id=n
        -usb -device usb-tablet -rtc base=localtime -boot order=cd)
  [ -n "$iso" ] && args+=(-drive "file=$iso,media=cdrom,if=ide,index=2")
  if [ -n "$disp" ]; then start_x11; args+=(-display "$disp")
  else warn "No SDL/GTK in this QEMU; using VNC -> connect a VNC app to localhost:5901"; args+=(-vnc :1); fi
  log "Starting Windows VM (first boot installs unattended - be patient, no input needed)"
  qemu-system-x86_64 "${args[@]}"
}

# ----------------------------------------------------------------- MAIN
menu() {
  while :; do
    clear
    cat <<M
 ===== pad6-lab (Termux + Termux:X11) =====
  1) Install Linux desktop  (Debian+XFCE+VS Code+conda)
  2) Install Windows VM     (QEMU, unattended)
  3) Install BOTH
  4) Start Linux desktop
  5) Start Windows VM
  q) Quit
M
    printf ' Choose: '; read -rn1 c </dev/tty; echo
    case "$c" in
      1) install_linux && run_linux ;;
      2) install_windows && run_windows ;;
      3) install_linux; install_windows && { run_linux & sleep 1; run_windows; } ;;
      4) run_linux ;;
      5) run_windows ;;
      q|Q) exit 0 ;;
    esac
    printf '\nPress any key...'; read -rn1 _ </dev/tty
  done
}

case "${1:-menu}" in
  menu)        menu ;;
  linux)       install_linux && run_linux ;;
  windows)     install_windows && run_windows ;;
  both)        install_linux; install_windows && run_windows ;;
  run-linux)   run_linux ;;
  run-windows) run_windows ;;
  *) echo "usage: bash setup.sh [menu|linux|windows|both|run-linux|run-windows]" ;;
esac
