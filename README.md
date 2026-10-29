# pad6-lab
Termux + Termux:X11 one-shot installer (Xiaomi Pad 6).

    pkg install -y git && git clone https://github.com/niteshbagde/automatic-install-os-in-turmux.git && cd automatic-install-os-in-turmux && bash setup.sh

Menu: install Linux / Windows / both, or start either. Non-interactive: `bash setup.sh linux|windows|both|run-linux|run-windows`.
Config: `~/.padlab.conf` (ISO_URL, WIN_RAM, WIN_CORES, WIN_DISK, WIN_ARCH, UNATTENDED).
Windows needs an ISO (ISO_URL, or drop an .iso in ~/winvm or /sdcard/Download). Login after unattended install: User / User.
Windows runs in software emulation (slow). Linux has VS Code, conda, Jupyter, PySD.
