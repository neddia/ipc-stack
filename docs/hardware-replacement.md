# Preparing a shelf spare

This requires compatible setpoint site-agent and gatewayd images, cloud migrations through `048_device_enrollment.sql` and enrollment/replacement API/UI. See `~/setpoint/docs/hardware-replacement.md` for restored/excluded data and the state machine.

1. Install/bench-boot the appliance normally at `/opt/ipc-stack`. Finish Tailscale enrollment while its enrollment auth key is valid. Verify its node stays enrolled after reboot and its node-key expiry policy is appropriate for an unattended tagged device. Each physical box needs its own appliance key, Tailscale identity and local service secrets.
2. Bench-test the software/network. Before shelving, leave the install-safe empty site configuration and **no cloud IPC pairing**. Never shelve a cloned controller disk or a test config that will command drives on startup.
3. First boot generates a unique local key and claims the image's one-use cloud enrollment ticket. The device appears in Platform → Hardware as unassigned, with online status from signed check-ins. It stays locally held and receives no customer/site configuration yet.
4. In cloud Platform, select the receiving customer, then assign the online box. The cloud challenges the box on Tailscale port 8000 to verify its key before assigning it. Customer owners/admins then select it under Accept device (new agent) or Replace Agent (existing agent).
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

## One-time image-builder authorization

In cloud Platform → Hardware, verify MFA and download an installer configuration. Save it on the build computer as `~/.config/toops-e2e/cloud-enrollment.json`, mode `600`. `provision/hyperv/build-media.sh` automatically uses it; override the path with `IPC_E2E_CLOUD_ENROLLMENT_CONFIG`. The HTTPS cloud URL in that file also configures the image; conflicting cloud overrides fail.

The 90-day installer credential can only mint unassigned tickets. It never goes on an IPC or into Git. Every image build gets a separate 14-day, first-key-bound ticket: build media per device, not one reusable USB image for a fleet. Bench-boot before ticket and Tailscale auth-key expiry. Once claimed, retries with the same key remain valid after ticket expiry. Revoking an installer prevents new/unclaimed enrollments, without disabling already enrolled controllers. `IPC_E2E_SKIP_CLOUD_ENROLLMENT=1` explicitly retains the legacy/manual build path for offline development only.

The first-boot ticket is persisted in the existing read-only secrets mount as `cloud.enrollment.json`; the root staging copy is removed after successful installation. The non-secret receipt is `storage/ipc/hardware.json`. Do not delete these or identity/hold state to reset a box. A missing original private key requires investigation/reprovisioning as new hardware, not silent regeneration. Missing public files can be rebuilt from the original private key. A recorded host mismatch blocks install/update to catch cloned enrolled disks; this is not TPM-backed anti-cloning protection.

All enrollment/acceptance code still needs a simulated-drive bench run before production rollout. No customer control depends on keeping a ticket or subscription valid after commissioning.
