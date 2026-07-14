# Hyper-V end-to-end qualification

This development-only harness boots a blank Generation 2 Hyper-V VM through
the real Ubuntu autoinstall and IPC first-boot flow. It never belongs in an
appliance image.

Private input lives outside the repository at
`~/.config/toops-e2e/seed.env`. Generated media and disks live under
`~/.cache/toops-e2e/` and must be deleted after testing because the CIDATA ISO
contains temporary credentials.

Build media from the exact local ipc-stack working tree:

```bash
switch_ip="$(powershell.exe -NoProfile -NonInteractive -Command \
  "(Get-NetIPAddress -InterfaceAlias 'vEthernet (Default Switch)' -AddressFamily IPv4).IPAddress" \
  | tr -d '\r')"
IPC_E2E_CLOUD_BASE_URL="http://${switch_ip}:18001" \
IPC_E2E_IMAGE_DIR="$HOME/.cache/toops-e2e/images" \
IPC_E2E_IMAGE_TAG=e2e-local-<commit> \
  ./provision/hyperv/build-media.sh
```

After the changes are published, set `IPC_E2E_LOCAL_STACK=0` and omit the
image preload variables to exercise the literal GitHub clone and GHCR pull
path using the pinned release tags in the private seed.

The cloud API remains loopback-only. During a Hyper-V test, use Windows Python
to expose it only on the Hyper-V Default Switch. Windows localhost forwarding
then carries the connection into WSL; this avoids depending on production
tailnet ACLs granting an IPC access to a developer workstation:

```bash
python.exe "$(wslpath -w "$PWD/provision/hyperv/cloud-proxy.py")" \
  --listen-host "$switch_ip" --listen-port 18001 \
  --target-host 127.0.0.1 --target-port 8001
```

Do not change the normal cloud bind or expose the proxy on a public interface.

Create and boot the VM from WSL:

```bash
media="$HOME/.cache/toops-e2e/media"
windows_root="/mnt/c/Users/Aidden/AppData/Local/toops-e2e"
mkdir -p "$windows_root/media" "$windows_root/vm"
cp "$media/ubuntu-ipc-autoinstall.iso" "$media/cidata.iso" "$windows_root/media/"
powershell.exe -NoProfile -ExecutionPolicy Bypass \
  -File "$(wslpath -w "$PWD/provision/hyperv/New-IpcE2EVM.ps1")" \
  -InstallerIso "$(wslpath -w "$windows_root/media/ubuntu-ipc-autoinstall.iso")" \
  -SeedIso "$(wslpath -w "$windows_root/media/cidata.iso")" \
  -VhdPath "$(wslpath -w "$windows_root/vm/ipc-e2e-x86-01.vhdx")"
```

The test autoinstall powers off when the OS is complete. Eject both virtual
DVDs and start the VM so the installed OS performs its one-time first boot.
The production template retains its normal reboot behavior.

Automate that transition and print the Hyper-V address:

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
