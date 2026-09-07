#!/usr/bin/env bash
#
# Prepares a fresh Hetzner Ubuntu box to serve nefwarehouse.com.
# Run it once, as root, on the server:
#
#   ssh root@37.27.95.82
#   bash bootstrap.sh 'ssh-ed25519 AAAA... deploy@github'
#
# Safe to run twice: every step checks before it acts.

set -euo pipefail

DEPLOY_KEY="${1:-}"
DEPLOY_USER="deploy"
ROOT_DIR="/srv/nefwarehouse"

if [[ -z "$DEPLOY_KEY" ]]; then
  echo "Give me the deploy public key as the first argument." >&2
  echo "Generate it on your own machine with:" >&2
  echo "  ssh-keygen -t ed25519 -C 'deploy@github' -f ~/.ssh/nefwarehouse_deploy" >&2
  exit 1
fi

echo "==> Packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg rsync ufw unattended-upgrades

echo "==> Swap"
# 4 GB of RAM is plenty to serve this and tight to build the warehouse system
# on later. Swap costs a couple of gigabytes of a 40 GB disk and turns "the
# build was killed" into "the build was slow", which is a much better problem.
if [[ ! -f /swapfile ]]; then
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  # Lean on swap only when genuinely short, rather than pre-emptively.
  sysctl -w vm.swappiness=10 >/dev/null
  grep -q '^vm.swappiness' /etc/sysctl.conf || echo 'vm.swappiness=10' >> /etc/sysctl.conf
fi

echo "==> Docker"
if ! command -v docker >/dev/null; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
systemctl enable --now docker

echo "==> Deploy user"
id -u "$DEPLOY_USER" >/dev/null 2>&1 || adduser --disabled-password --gecos "" "$DEPLOY_USER"
usermod -aG docker "$DEPLOY_USER"
install -d -m 700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "/home/$DEPLOY_USER/.ssh"
touch "/home/$DEPLOY_USER/.ssh/authorized_keys"
grep -qxF "$DEPLOY_KEY" "/home/$DEPLOY_USER/.ssh/authorized_keys" \
  || echo "$DEPLOY_KEY" >> "/home/$DEPLOY_USER/.ssh/authorized_keys"
chown "$DEPLOY_USER:$DEPLOY_USER" "/home/$DEPLOY_USER/.ssh/authorized_keys"
chmod 600 "/home/$DEPLOY_USER/.ssh/authorized_keys"

echo "==> Folders"
install -d -o "$DEPLOY_USER" -g "$DEPLOY_USER" \
  "$ROOT_DIR" "$ROOT_DIR/site" "$ROOT_DIR/infra" "$ROOT_DIR/infra/env" \
  "$ROOT_DIR/wms" "$ROOT_DIR/backups"

echo "==> Database password"
# Generated, not chosen. A password nobody has ever typed cannot be reused
# anywhere else, and nothing needs to know it except these two files.
ENV_DIR="$ROOT_DIR/infra/env"
if [[ ! -f "$ENV_DIR/postgres.env" ]]; then
  PG_PASS="$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 32)"

  cat > "$ENV_DIR/postgres.env" <<EOF
POSTGRES_USER=namdhari
POSTGRES_PASSWORD=$PG_PASS
POSTGRES_DB=namdhari
EOF

  cat > "$ENV_DIR/wms.env" <<EOF
DATABASE_URL="postgresql://namdhari:$PG_PASS@postgres:5432/namdhari?schema=public"

# Sending paperwork and quality reports. Fill these in and restart the wms
# container; until then the send buttons say email is not set up rather than
# failing quietly.
SMTP_HOST=""
SMTP_PORT="587"
SMTP_USER=""
SMTP_PASS=""
SMTP_FROM="Namdhari's Euro Fresh <warehouse@namdharithaifresh.com>"
EOF

  chmod 600 "$ENV_DIR"/*.env
  chown "$DEPLOY_USER:$DEPLOY_USER" "$ENV_DIR"/*.env
  echo "  Generated a database password into infra/env/."
else
  echo "  Already there; left alone."
fi

echo "==> Firewall"
# Nothing but ssh and the web. The database, when it arrives, talks to the app
# over Docker's own network and never needs a port on the outside.
ufw allow OpenSSH >/dev/null
ufw allow 80/tcp  >/dev/null
ufw allow 443/tcp >/dev/null
ufw allow 443/udp >/dev/null
ufw --force enable >/dev/null

echo "==> Unattended security updates"
dpkg-reconfigure -f noninteractive unattended-upgrades >/dev/null 2>&1 || true

echo
echo "  Done. Next:"
echo "    1. Point nefwarehouse.com and www at this machine in Cloudflare, proxy OFF."
echo "    2. Push the nefwarehouse repo to main  (landing page, Caddy, compose)."
echo "    3. Push the warehouse system repo to main  (builds and starts the app)."
echo ""
echo "  Nightly backups, once both are up:"
echo "    (crontab -l 2>/dev/null; echo '"'"'0 2 * * * bash /srv/nefwarehouse/infra/backup.sh >> /srv/nefwarehouse/backups/log 2>&1'"'"') | crontab -"
echo
echo "  The fingerprint to put in the SSH_KNOWN_HOSTS secret:"
ssh-keyscan -t ed25519 "$(curl -fsS4 https://icanhazip.com 2>/dev/null || echo localhost)" 2>/dev/null || true
echo
