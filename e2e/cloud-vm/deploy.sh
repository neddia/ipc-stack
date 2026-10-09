#!/usr/bin/env bash
# Deploy the local toops-cloud working tree to the disposable e2e Cloud VM.
# Development only; see e2e/README.md.
#   e2e/cloud-vm/deploy.sh <vm-ip>            full deploy (first run: secrets, Stripe CLI, Tailscale)
#   E2E_CODE_ONLY=1 e2e/cloud-vm/deploy.sh <vm-ip>   ship api/app and restart the API
set -euo pipefail

IP="${1:?VM IP required}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLOUD_SRC="${TOOPS_CLOUD_DIR:-$HOME/toops-cloud}"
PRIVATE_DIR="${IPC_E2E_PRIVATE_DIR:-$HOME/.config/toops-e2e}"
RELAY="${E2E_SSH_RELAY:-/mnt/c/msys64/ucrt64/bin/python.exe C:/Users/Aidden/AppData/Local/toops-e2e/win-relay.py %h %p}"
SSH=(ssh -i "$PRIVATE_DIR/id_ed25519" -o "ProxyCommand=$RELAY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
     -o LogLevel=ERROR -o ConnectTimeout=10 "toops@$IP")
BASE="https://$IP"
log() { echo "[cloud-e2e] $*"; }

ship_tree() {
  log "shipping $CLOUD_SRC"
  tar -C "$CLOUD_SRC" -czf - --mode=a+rX --exclude=.git --exclude=.env --exclude=.secrets --exclude=archive \
      --exclude=__pycache__ --exclude='*.pyc' --exclude=.pytest_cache --exclude=node_modules . \
    | "${SSH[@]}" 'sudo mkdir -p /opt/toops-cloud && sudo chown toops: /opt/toops-cloud && tar -C /opt/toops-cloud -xzf -'
  "${SSH[@]}" "cat > /opt/toops-cloud/compose.e2e.yml" <"$HERE/compose.e2e.yml"
  "${SSH[@]}" "cat > /opt/toops-cloud/caddy-e2e.Caddyfile" <"$HERE/caddy-e2e.Caddyfile"
}

COMPOSE="E2E_IP=$IP docker compose -f compose.yml -f compose.e2e.yml"

if [ "${E2E_CODE_ONLY:-0}" = "1" ]; then
  ship_tree
  "${SSH[@]}" "cd /opt/toops-cloud && ./scripts/migrate.sh >/dev/null && $COMPOSE restart api >/dev/null"
  log "code shipped, migrations applied, api restarted"
  exit 0
fi

ship_tree

log "writing .env (dev values, test-Cloud URLs; secrets are never printed)"
CLOUD_ENV_SRC="$CLOUD_SRC/.env" BASE="$BASE" python3 - <<'PY' | "${SSH[@]}" 'umask 077; cat > /opt/toops-cloud/.env'
import os, re
base = os.environ["BASE"]
overrides = {
    "CLOUD_ENV": "development", "COOKIE_SECURE": "0", "COOKIE_DOMAIN": "",
    "STRIPE_CHECKOUT_SUCCESS_URL": f"{base}/app?tab=billing&billing=success",
    "STRIPE_CHECKOUT_CANCEL_URL": f"{base}/app?tab=billing&billing=cancel",
    "STRIPE_BILLING_PORTAL_RETURN_URL": f"{base}/app?tab=billing",
    "SUPABASE_INVITE_REDIRECT_URL": f"{base}/signup",
    "ALERTS_CLOUD_UI_URL": f"{base}/app",
    "ALERTS_DELIVERY_WORKER_ENABLED": "1",
    # One Telegram bot can have one webhook: leave it with production.
    "ALERTS_TELEGRAM_BOT_TOKEN": "disabled", "ALERTS_TELEGRAM_WEBHOOK_SECRET": "",
    # No ops-channel noise from a disposable Cloud.
    "OPS_DISCORD_WEBHOOK_URL": "", "OPS_TELEGRAM_CHAT_ID": "", "GRAFANA_OPS_DISCORD_WEBHOOK_URL": "",
    "SITE_AGENT_PUBLIC_URL_TEMPLATE": "",
    "STRIPE_WEBHOOK_SECRET": "pending-stripe-listen",
    "DEV_ROLE_PREVIEW_ENABLED": "0",
}
seen, out = set(), []
for line in open(os.environ["CLOUD_ENV_SRC"]).read().splitlines():
    m = re.match(r"^([A-Z0-9_]+)=", line)
    if m and m.group(1) in overrides:
        if m.group(1) in seen:
            continue
        seen.add(m.group(1))
        out.append(f"{m.group(1)}={overrides[m.group(1)]}")
    else:
        out.append(line)
out += [f"{k}={v}" for k, v in overrides.items() if k not in seen]
print("\n".join(out))
PY

log "installing Stripe CLI and Tailscale (idempotent)"
"${SSH[@]}" 'bash -se' <<'REMOTE'
set -euo pipefail
if ! command -v stripe >/dev/null; then
  curl -fsSL https://packages.stripe.dev/api/security/keypair/stripe-cli-gpg/public | gpg --dearmor | sudo tee /usr/share/keyrings/stripe.gpg >/dev/null
  echo "deb [signed-by=/usr/share/keyrings/stripe.gpg] https://packages.stripe.dev/stripe-cli-debian-local stable main" | sudo tee /etc/apt/sources.list.d/stripe.list >/dev/null
  sudo apt-get update -qq && sudo apt-get install -y -qq stripe >/dev/null
fi
command -v tailscale >/dev/null || curl -fsSL https://tailscale.com/install.sh | sudo sh >/dev/null
REMOTE

if [ -s "$PRIVATE_DIR/cloud-gateway.authkey" ]; then
  log "joining the tailnet as tag:gateway"
  "${SSH[@]}" 'read -r key; sudo tailscale up --authkey="$key" --hostname=cloud-e2e --advertise-tags=tag:gateway --accept-dns=false' \
    <"$PRIVATE_DIR/cloud-gateway.authkey" || log "WARNING: tailscale up failed"
else
  log "WARNING: no $PRIVATE_DIR/cloud-gateway.authkey; remote access over the tailnet will not work"
fi

log "Stripe webhook forwarding (stripe listen as a systemd unit)"
"${SSH[@]}" 'bash -se' <<'REMOTE'
set -euo pipefail
cd /opt/toops-cloud
key="$(grep -E '^STRIPE_SECRET_KEY=' .env | tail -1 | cut -d= -f2-)"
secret="$(stripe listen --api-key "$key" --print-secret 2>/dev/null)"
sed -i -E "s|^STRIPE_WEBHOOK_SECRET=.*|STRIPE_WEBHOOK_SECRET=$secret|" .env
sudo install -m 600 /dev/null /etc/stripe-listen.env
echo "STRIPE_API_KEY=$key" | sudo tee /etc/stripe-listen.env >/dev/null
sudo tee /etc/systemd/system/stripe-listen.service >/dev/null <<'UNIT'
[Unit]
Description=Forward Stripe sandbox events to the e2e Cloud
After=network-online.target docker.service
[Service]
EnvironmentFile=/etc/stripe-listen.env
ExecStart=/usr/bin/stripe listen --events checkout.session.completed,customer.subscription.created,customer.subscription.updated,customer.subscription.deleted,invoice.created,invoice.paid,invoice.payment_failed --forward-to http://127.0.0.1:8001/stripe/webhook --skip-verify
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
UNIT
sudo systemctl daemon-reload && sudo systemctl enable --now stripe-listen >/dev/null 2>&1
REMOTE

log "secrets, images, database"
"${SSH[@]}" "bash -se" <<REMOTE
set -euo pipefail
cd /opt/toops-cloud
./scripts/gen-cloud-secrets.sh >/dev/null
chmod 755 .secrets; chmod 644 .secrets/.env.grafana 2>/dev/null || true
$COMPOSE build -q api
$COMPOSE up -d --wait postgres pgbouncer influxdb >/dev/null
./scripts/migrate.sh >/dev/null
$COMPOSE run --rm influx-init >/dev/null 2>&1 || true
export FORWARDED_ALLOW_IPS="\$(python3 ./scripts/proxy-peers.py "\$($COMPOSE ps -q postgres)")"
$COMPOSE up -d --wait api caddy-e2e >/dev/null
for _ in \$(seq 1 30); do $COMPOSE exec -T caddy-e2e test -s /data/caddy/pki/authorities/local/root.crt && break; sleep 1; done
REMOTE
mkdir -p "$PRIVATE_DIR/cloud-e2e"
"${SSH[@]}" "cd /opt/toops-cloud && $COMPOSE exec -T caddy-e2e cat /data/caddy/pki/authorities/local/root.crt" >"$PRIVATE_DIR/cloud-e2e/ca-root.pem"
"${SSH[@]}" "cat /opt/toops-cloud/.secrets/cloud.license.ed25519.pub" >"$PRIVATE_DIR/cloud-e2e/cloud.license.ed25519.pub"
# Trust bundle for e2e clients: public roots plus the test Cloud's CA.
cat "$(python3 -c 'import certifi; print(certifi.where())' 2>/dev/null || echo /etc/ssl/certs/ca-certificates.crt)" \
  "$PRIVATE_DIR/cloud-e2e/ca-root.pem" >"$PRIVATE_DIR/cloud-e2e/ca-bundle.pem"
"${SSH[@]}" "curl -fsS --cacert /dev/stdin $BASE/health" <"$PRIVATE_DIR/cloud-e2e/ca-root.pem"
echo
log "Cloud up at $BASE"
