# Preparing a shelf spare

This requires the compatible setpoint site-agent and gatewayd images, cloud migration `045_hardware_replacement.sql` and replacement API/UI. See `~/setpoint/docs/hardware-replacement.md` for restored/excluded data and the state machine.

1. Install/bench-boot the appliance normally at `/opt/ipc-stack`. Finish Tailscale enrollment while its enrollment auth key is valid. Verify its node stays enrolled after reboot and its node-key expiry policy is appropriate for an unattended tagged device. Each physical box needs its own appliance key, Tailscale identity and local service secrets.
2. Bench-test the software/network. Before shelving, leave the install-safe empty site configuration and **no cloud IPC pairing**. Never shelve a cloned controller disk or a test config that will command drives on startup.
3. On the bench, obtain the public-only manifest:

   ```sh
   cd /opt/ipc-stack
   docker compose run --rm --no-deps -T site-agent /app/.venv/bin/python -m app.services.cloud.replacement identity
   ```

4. In cloud Platform, select the receiving customer. Under Shipped replacement hardware, enter a friendly name and paste that JSON. Assign spare. The device's signed poll must make it appear online in the customer's replacement dialog before shipping. The friendly name is cloud metadata; no physical sticker is required.
5. Confirm `systemctl status ipc-replacement.timer`, reboot, verify the spare comes online again, then power down for shipping. Keep approved firmware versions and compatible network/cabling requirements in the shipment record.

The installer/update script installs the host oneshot service/timer only for `/opt/ipc-stack`. It checks every 30 seconds. Paired or fully completed devices are skipped without starting extra containers. Nothing installs a system service in the WSL development checkout.

The supervisor requires Python 3, Docker Compose, `IPC_STORAGE_DIR`, normal mapped service ports, and shared `storage/ipc` placement. It intentionally exposes no new inbound port, Docker socket, or remote shell to the site web app. The cloud gateway still needs only the site application port.

## Customer instructions

Disconnect old controller power or drive-network cable; connect the compatible spare; choose Replace Agent in cloud Sites; select the online spare and confirm disconnection. Owners/admins of the site can do this without platform-operator involvement. Old hardware does not need to boot or release a token.

## Diagnosis without losing state

```sh
systemctl status ipc-replacement.timer
journalctl -u ipc-replacement.service --since '1 hour ago'
cd /opt/ipc-stack
docker compose run --rm --no-deps -T site-agent /app/.venv/bin/python -m app.services.cloud.replacement status
```

The phase persists in the storage volume. Retrying the service is safe; deleting its marker or restoring an older image mid-commissioning is not. Logs omit configuration contents and private keys. Normal Docker logs remain available over your existing ops access for troubleshooting. Once active, cloud loss or license expiry does not cause the supervisor to shut off local control.

Do not enable this on a production controller until compatible images have passed a bench swap, including interruption/resume. Recovery requires a previous full cloud recovery bundle; legacy YAML-only snapshots do not contain sweep maps. OS static networking, DHCP reservations, VLANs and changed serial-adapter device paths still need a compatible installation; the supervisor does not rewrite them.

Tests: `python3 -m unittest discover -s tests -p test_replacement_supervisor.py`.
