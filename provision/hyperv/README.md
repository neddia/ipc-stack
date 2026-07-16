# Hyper-V end-to-end qualification

This development-only harness boots a blank Generation 2 Hyper-V VM through
the same one-ISO Ubuntu autoinstall and first-boot flow used by a physical IPC.
It never belongs in an appliance image.

For a local working-tree qualification, the builder accepts the same
`~/.config/toops-e2e/seed.env` inputs as the appliance workflow:

```bash
switch_ip="$(powershell.exe -NoProfile -NonInteractive -Command \
  "(Get-NetIPAddress -InterfaceAlias 'vEthernet (Default Switch)' -AddressFamily IPv4).IPAddress" \
  | tr -d '\r')"
IPC_E2E_CLOUD_BASE_URL="http://${switch_ip}:18001" \
IPC_E2E_IMAGE_DIR="$HOME/.cache/toops-e2e/images" \
IPC_E2E_IMAGE_TAG=e2e-local-<commit> \
  ./provision/hyperv/build-media.sh
```

The cloud API remains loopback-only. For a VM test, expose it only on the
Hyper-V Default Switch:

```bash
python.exe "$(wslpath -w "$PWD/provision/hyperv/cloud-proxy.py")" \
  --listen-host "$switch_ip" --listen-port 18001 \
  --target-host 127.0.0.1 --target-port 8001
```

Copy and boot the single installer ISO:

```bash
media="$HOME/.cache/toops-e2e/media"
windows_root="/mnt/c/Users/Aidden/AppData/Local/toops-e2e"
mkdir -p "$windows_root/media" "$windows_root/vm"
cp "$media/ubuntu-ipc-autoinstall.iso" "$windows_root/media/"
powershell.exe -NoProfile -ExecutionPolicy Bypass \
  -File "$(wslpath -w "$PWD/provision/hyperv/New-IpcE2EVM.ps1")" \
  -InstallerIso "$(wslpath -w "$windows_root/media/ubuntu-ipc-autoinstall.iso")" \
  -VhdPath "$(wslpath -w "$windows_root/vm/ipc-e2e-x86-01.vhdx")"
```

The qualification template powers off after OS installation. Eject the DVD
and start the VM so the installed OS performs its first boot:

```bash
powershell.exe -NoProfile -ExecutionPolicy Bypass \
  -File "$(wslpath -w "$PWD/provision/hyperv/Complete-IpcE2EInstall.ps1")"
```

Destroy the disposable VM and disk:

```bash
powershell.exe -NoProfile -ExecutionPolicy Bypass \
  -File "$(wslpath -w "$PWD/provision/hyperv/Remove-IpcE2EVM.ps1")" \
  -VhdPath "$(wslpath -w "$windows_root/vm/ipc-e2e-x86-01.vhdx")"
```

Generated installer media contains provisioning credentials and must be
removed after qualification.
