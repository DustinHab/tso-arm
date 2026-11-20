#!/bin/sh
# Fetches FEX's Ubuntu 24.04 x86-64 root file system (from FEX's servers) and extracts it.
export PATH=$HOME/opt/fex/bin:$PATH
cd ~
timeout 3000 FEXRootFSFetcher -y -x --distro-name=ubuntu --distro-version=24.04 --force-ui=tty >~/tso-arm/out/rootfs.log 2>&1
echo "rc=$?"
tail -n 8 ~/tso-arm/out/rootfs.log
# FEX keeps them in ~/.fex-emu if that exists, else in ~/.local/share/fex-emu and ~/.config/fex-emu
ls -la ~/.fex-emu/RootFS ~/.local/share/fex-emu/RootFS 2>/dev/null
cat ~/.fex-emu/Config.json ~/.config/fex-emu/Config.json 2>/dev/null
