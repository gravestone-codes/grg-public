#!/usr/bin/env bash
#
# GRG installer — takes a bare Ubuntu/Debian host to a running, TLS-terminated deployment.
# Installs Docker, generates every secret, opens the firewall, pulls the images, and starts up.
#
#   curl -fsSL https://raw.githubusercontent.com/gravestone-codes/grg-public/main/install.sh \
#     | sudo bash -s -- --domain garage.example.com --email you@example.com
#
# Nothing is compiled here: the images are prebuilt and published, so a 1GB VPS is enough and the
# whole thing takes about a minute plus certificate issuance.
#
# Safe to re-run — that is how you update. It never overwrites an existing .env, because
# ZITADEL_MASTERKEY encrypts the identity database and rotating it would make that data unreadable.
#
# Usage:
#   install.sh --domain <host> [--media-domain <host>] [--email <addr>]
#              [--dir <path>] [--version <tag>] [--ref <branch>]
#              [--skip-dns-check] [--no-firewall]
set -euo pipefail

# ── Defaults ────────────────────────────────────────────────────────────────────────────────────
APP_DOMAIN="${APP_DOMAIN:-}"
MEDIA_DOMAIN="${MEDIA_DOMAIN:-}"          # defaults to media.<APP_DOMAIN>
ACME_EMAIL="${ACME_EMAIL:-}"              # defaults to admin@<registrable part of APP_DOMAIN>
INSTALL_DIR="${INSTALL_DIR:-/opt/grg}"
GRG_VERSION="${GRG_VERSION:-}"
BUNDLE_REF="${BUNDLE_REF:-main}"
BUNDLE_REPO="${BUNDLE_REPO:-gravestone-codes/grg-public}"
SKIP_DNS_CHECK=0
CONFIGURE_FIREWALL=1

while [ $# -gt 0 ]; do
  case "$1" in
    --domain)         APP_DOMAIN="$2"; shift 2 ;;
    --media-domain)   MEDIA_DOMAIN="$2"; shift 2 ;;
    --email)          ACME_EMAIL="$2"; shift 2 ;;
    --dir)            INSTALL_DIR="$2"; shift 2 ;;
    --version)        GRG_VERSION="$2"; shift 2 ;;
    --ref)            BUNDLE_REF="$2"; shift 2 ;;
    --skip-dns-check) SKIP_DNS_CHECK=1; shift ;;
    --no-firewall)    CONFIGURE_FIREWALL=0; shift ;;
    -h|--help)        sed -n '2,/^set -euo/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1 (try --help)" >&2; exit 2 ;;
  esac
done

# ── Output helpers ──────────────────────────────────────────────────────────────────────────────
if [ -t 1 ]; then B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; N=$'\033[0m'
else B=""; G=""; Y=""; R=""; N=""; fi
step() { printf '\n%s==>%s %s%s%s\n' "$G" "$N" "$B" "$*" "$N"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '%s !! %s%s\n' "$Y" "$*" "$N" >&2; }
die()  { printf '%s !! %s%s\n' "$R" "$*" "$N" >&2; exit 1; }

# ── Preflight ───────────────────────────────────────────────────────────────────────────────────
step "Checking the host"
[ "$(id -u)" -eq 0 ] || die "Run this as root (prefix with sudo)."
[ -n "$APP_DOMAIN" ] || die "--domain is required, e.g. --domain garage.example.com"
command -v apt-get >/dev/null 2>&1 || die "This installer targets Debian/Ubuntu (needs apt-get)."
case "$(uname -m)" in
  x86_64) ;;
  *) die "The published images are linux/amd64 only; this host is $(uname -m)." ;;
esac

MEDIA_DOMAIN="${MEDIA_DOMAIN:-media.${APP_DOMAIN}}"
ACME_EMAIL="${ACME_EMAIL:-admin@${APP_DOMAIN#*.}}"

info "OS: $( . /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || echo unknown ) · arch $(uname -m)"
info "App:   https://${APP_DOMAIN}"
info "Media: https://${MEDIA_DOMAIN}"

mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
[ "$mem_mb" -ge 900 ] 2>/dev/null || warn "Only ${mem_mb}MB RAM detected — 1GB+ recommended."

# ── Base packages ───────────────────────────────────────────────────────────────────────────────
step "Installing base packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg openssl tar ufw >/dev/null
info "ca-certificates, curl, gnupg, openssl, tar, ufw"

# ── Docker ──────────────────────────────────────────────────────────────────────────────────────
step "Installing Docker"
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  info "Already present: $(docker --version)"
else
  # Official Docker apt repo — the distro's docker.io package ships without the compose v2 plugin.
  install -m 0755 -d /etc/apt/keyrings
  . /etc/os-release
  distro_id="${ID:-debian}"
  curl -fsSL "https://download.docker.com/linux/${distro_id}/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${distro_id} ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
  info "Installed: $(docker --version)"
fi
systemctl enable --now docker >/dev/null 2>&1 || true
docker compose version >/dev/null 2>&1 || die "'docker compose' still unavailable after install."

# ── Deployment bundle ───────────────────────────────────────────────────────────────────────────
step "Fetching the deployment files"
# Piped from curl there is no local checkout to detect, so the bundle is always downloaded unless
# this script is sitting next to a compose file already.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "")"
if [ -n "$script_dir" ] && [ -f "${script_dir}/docker-compose.yml" ]; then
  INSTALL_DIR="$script_dir"
  info "Using the bundle next to this script: ${INSTALL_DIR}"
else
  mkdir -p "$INSTALL_DIR"
  info "Downloading ${BUNDLE_REPO}@${BUNDLE_REF} → ${INSTALL_DIR}"
  # --strip-components=1 drops the repo-name-and-ref wrapper directory the tarball adds.
  curl -fsSL "https://codeload.github.com/${BUNDLE_REPO}/tar.gz/refs/heads/${BUNDLE_REF}" \
    | tar -xz -C "$INSTALL_DIR" --strip-components=1 \
    || die "Couldn't download the deployment bundle. Check network access to github.com."
fi
cd "$INSTALL_DIR"
[ -f docker-compose.yml ] || die "docker-compose.yml missing from ${INSTALL_DIR}."

# ── Secrets ─────────────────────────────────────────────────────────────────────────────────────
step "Configuring secrets"
rand_hex() { openssl rand -hex "$1"; }
# ZITADEL's default policy wants upper + lower + digit + symbol; the fixed tail guarantees all four
# regardless of what the random part happens to contain.
gen_admin_password() { printf '%sAa1!' "$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | cut -c1-20)"; }

if [ -f .env ]; then
  info ".env already exists — keeping it (secrets and the ZITADEL masterkey are preserved)."
  ADMIN_EMAIL="$(grep -E '^FIRST_ADMIN_EMAIL=' .env | cut -d= -f2- || true)"
  APP_DOMAIN="$(grep -E '^APP_DOMAIN=' .env | cut -d= -f2- || echo "$APP_DOMAIN")"
  MEDIA_DOMAIN="$(grep -E '^MEDIA_DOMAIN=' .env | cut -d= -f2- || echo "$MEDIA_DOMAIN")"
  FRESH_INSTALL=0
else
  # Docker volumes are named after the compose project (grg_*), not this directory, so they outlive
  # a re-download into a new path. Pairing a fresh masterkey with an existing ZITADEL database makes
  # that database permanently unreadable — refuse rather than quietly destroy it.
  if docker volume ls -q 2>/dev/null | grep -qE '^grg_(pg_data|machinekey)$'; then
    die "Existing GRG data volumes found, but there's no .env in $(pwd).

A previous install's data is still on this host. Generating a new ZITADEL masterkey now would
permanently lock it.

  - Updating an existing install? Re-run from its original directory, or copy its .env here first.
  - Starting over, and the old data is disposable?
      docker compose -p grg down -v     # DESTROYS all GRG data
    then re-run this script."
  fi

  ADMIN_EMAIL="admin@${APP_DOMAIN#*.}"
  ADMIN_PASSWORD="$(gen_admin_password)"
  umask 077
  cat > .env <<EOF
# Generated by install.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ). Never commit or share this file.
#
# ZITADEL_MASTERKEY encrypts everything ZITADEL stores — back it up together with the Postgres
# volume. Restoring a database without its matching masterkey is unrecoverable.

APP_DOMAIN=${APP_DOMAIN}
MEDIA_DOMAIN=${MEDIA_DOMAIN}
ACME_EMAIL=${ACME_EMAIL}

DB_NAME=grg
DB_USER=grg
DB_PASSWORD=$(rand_hex 24)

ZITADEL_MASTERKEY=$(rand_hex 16)

FIRST_ADMIN_EMAIL=${ADMIN_EMAIL}
FIRST_ADMIN_PASSWORD=${ADMIN_PASSWORD}
FIRST_ADMIN_FULL_NAME=GRG Admin

GARAGE_RPC_SECRET=$(rand_hex 32)
GARAGE_ADMIN_TOKEN=$(rand_hex 32)
GARAGE_ACCESS_KEY_ID=GK$(rand_hex 12)
GARAGE_SECRET_ACCESS_KEY=$(rand_hex 32)
EOF
  chmod 600 .env
  info "Wrote .env with freshly generated secrets (mode 600)."
  FRESH_INSTALL=1
fi

# Pin the image tag if one was asked for, so later bare re-runs stay put instead of drifting.
if [ -n "$GRG_VERSION" ]; then
  if grep -q '^GRG_VERSION=' .env; then
    sed -i "s|^GRG_VERSION=.*|GRG_VERSION=${GRG_VERSION}|" .env
  else
    printf '\n# Image tag to deploy (latest, or a sha-xxxxxxx build).\nGRG_VERSION=%s\n' "$GRG_VERSION" >> .env
  fi
  info "Pinned to ${GRG_VERSION}."
fi

# ── DNS ─────────────────────────────────────────────────────────────────────────────────────────
step "Checking DNS"
if [ "$SKIP_DNS_CHECK" -eq 1 ]; then
  info "Skipped (--skip-dns-check)."
else
  public_ip="$(curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
  [ -n "$public_ip" ] && info "This server's public IP: ${public_ip}"
  dns_ok=1
  for host in "$APP_DOMAIN" "$MEDIA_DOMAIN"; do
    resolved="$(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1; exit}')"
    if [ -z "$resolved" ]; then
      warn "${host} does not resolve — add a DNS A record → ${public_ip:-this server}."
      dns_ok=0
    elif [ -n "$public_ip" ] && [ "$resolved" != "$public_ip" ]; then
      warn "${host} resolves to ${resolved}, not ${public_ip}."
      dns_ok=0
    else
      info "${host} → ${resolved} ✓"
    fi
  done
  if [ "$dns_ok" -eq 0 ]; then
    warn "Let's Encrypt validates over HTTP on these names; certificates will fail until DNS is correct."
    warn "Fix the records and re-run this script — everything else is already done."
  fi
fi

# ── Firewall ────────────────────────────────────────────────────────────────────────────────────
if [ "$CONFIGURE_FIREWALL" -eq 1 ] && command -v ufw >/dev/null 2>&1; then
  step "Configuring the firewall"
  # SSH first and explicitly — enabling ufw without it locks you out of your own server.
  ufw allow OpenSSH >/dev/null 2>&1 || ufw allow 22/tcp >/dev/null 2>&1 || true
  ufw allow 80/tcp  >/dev/null 2>&1 || true
  ufw allow 443/tcp >/dev/null 2>&1 || true
  if ufw status | head -1 | grep -q inactive; then
    ufw --force enable >/dev/null 2>&1 || warn "Couldn't enable ufw; configure the firewall yourself."
  fi
  info "Allowed 22 (SSH), 80, 443. Postgres, ZITADEL, and Garage stay on the Docker network only."
fi

# ── Pull and start ──────────────────────────────────────────────────────────────────────────────
step "Pulling images"
docker compose pull || die "Pull failed — check network access to ghcr.io."

step "Starting the stack"
docker compose up -d

step "Waiting for the application"
ready=0
for _ in $(seq 1 60); do
  # 401 is the correct, healthy answer: /api/auth/me is authenticated-only, so a clean
  # unauthorized response proves the backend is up and routing rather than Caddy 502-ing.
  code="$(curl -fsS -o /dev/null -w '%{http_code}' -m 5 -k "https://${APP_DOMAIN}/api/auth/me" 2>/dev/null || echo 000)"
  case "$code" in
    401|200) ready=1; break ;;
  esac
  sleep 5
done

if [ "$ready" -eq 1 ]; then
  step "GRG is up"
else
  step "Stack started, but the app didn't answer yet"
  warn "Containers are running; the app hasn't responded on https://${APP_DOMAIN} yet."
  warn "This is normal for a few more minutes on first boot, or means DNS/certs aren't ready."
  warn "Watch it with:  cd ${INSTALL_DIR} && docker compose logs -f backend proxy"
fi

cat <<EOF

  ${B}URL${N}         https://${APP_DOMAIN}
  ${B}Media${N}       https://${MEDIA_DOMAIN}
  ${B}Directory${N}   ${INSTALL_DIR}
  ${B}Secrets${N}     ${INSTALL_DIR}/.env  (mode 600)
EOF

if [ "${FRESH_INSTALL:-0}" -eq 1 ]; then
  cat <<EOF
  ${B}Sign in${N}     ${ADMIN_EMAIL}
  ${B}Password${N}    ${ADMIN_PASSWORD}

  ${Y}Save that password now — it is shown once, and the app forces a change at first sign-in.${N}
  ${Y}Back up ${INSTALL_DIR}/.env together with the Postgres volume: the ZITADEL masterkey inside${N}
  ${Y}it is required to read that database back.${N}
EOF
else
  info "Existing install updated; credentials unchanged."
fi

cat <<EOF

  Logs      cd ${INSTALL_DIR} && docker compose logs -f
  Restart   cd ${INSTALL_DIR} && docker compose restart
  Update    sudo ${INSTALL_DIR}/install.sh --domain ${APP_DOMAIN}

EOF
