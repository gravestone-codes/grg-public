#!/usr/bin/env bash
#
# GRG installer.
#
# Run this on a fresh Ubuntu or Debian server and answer a few questions. It installs anything
# missing (Docker and a handful of small tools), sets up the whole system, and starts it.
#
#   curl -fsSL https://raw.githubusercontent.com/gravestone-codes/grg-public/main/install.sh | sudo bash
#
# You can also answer everything up front instead of being asked — useful for automation:
#
#   sudo ./install.sh --domain garage.example.com --email you@example.com --yes
#
# Safe to run again. That is how you update: it never overwrites the settings file it created,
# because the encryption key inside it is the only way to read your existing data.
#
# Options:
#   --domain <address>        web address people will use
#   --media-domain <address>  address photos and videos are served from
#   --email <address>         email for security-certificate notices
#   --admin-email <address>   the first sign-in account
#   --admin-name <name>       full name on that account
#   --version <tag>           deploy a specific build (default: latest)
#   --dir <path>              where to install (default: /opt/grg)
#   --yes                     don't ask anything; use defaults and flags
#   --skip-dns-check          install even if the addresses don't point here yet
#   --no-firewall             don't touch the firewall
set -euo pipefail

APP_DOMAIN="${APP_DOMAIN:-}"
MEDIA_DOMAIN="${MEDIA_DOMAIN:-}"
ACME_EMAIL="${ACME_EMAIL:-}"
ADMIN_EMAIL="${ADMIN_EMAIL:-}"
ADMIN_NAME="${ADMIN_NAME:-GRG Admin}"
INSTALL_DIR="${INSTALL_DIR:-/opt/grg}"
GRG_VERSION="${GRG_VERSION:-}"
BUNDLE_REF="${BUNDLE_REF:-main}"
BUNDLE_REPO="${BUNDLE_REPO:-gravestone-codes/grg-public}"
ASSUME_YES=0
SKIP_DNS_CHECK=0
CONFIGURE_FIREWALL=1

while [ $# -gt 0 ]; do
  case "$1" in
    --domain)         APP_DOMAIN="$2"; shift 2 ;;
    --media-domain)   MEDIA_DOMAIN="$2"; shift 2 ;;
    --email)          ACME_EMAIL="$2"; shift 2 ;;
    --admin-email)    ADMIN_EMAIL="$2"; shift 2 ;;
    --admin-name)     ADMIN_NAME="$2"; shift 2 ;;
    --version)        GRG_VERSION="$2"; shift 2 ;;
    --dir)            INSTALL_DIR="$2"; shift 2 ;;
    --ref)            BUNDLE_REF="$2"; shift 2 ;;
    -y|--yes)         ASSUME_YES=1; shift ;;
    --skip-dns-check) SKIP_DNS_CHECK=1; shift ;;
    --no-firewall)    CONFIGURE_FIREWALL=0; shift ;;
    -h|--help)        sed -n '2,/^set -euo/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Don't recognise that option: $1  (try --help)" >&2; exit 2 ;;
  esac
done

# ── Output ──────────────────────────────────────────────────────────────────────────────────────
if [ -t 1 ]; then B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; D=$'\033[2m'; N=$'\033[0m'
else B=""; G=""; Y=""; R=""; D=""; N=""; fi
step() { printf '\n%s==>%s %s%s%s\n' "$G" "$N" "$B" "$*" "$N"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '%s !! %s%s\n' "$Y" "$*" "$N" >&2; }
die()  { printf '\n%s !! %s%s\n\n' "$R" "$*" "$N" >&2; exit 1; }

# Piped through `curl | sudo bash`, this script arrives on stdin — so answers have to be read from
# the terminal directly, or every prompt would instantly consume the script itself and get EOF.
TTY_IN=""
if [ "$ASSUME_YES" -eq 0 ] && [ -r /dev/tty ]; then TTY_IN=/dev/tty; fi

valid_domain() {
  case "$1" in
    *' '*|'')        printf '    That can'\''t be blank or contain spaces.\n'; return 1 ;;
    http*)           printf '    Leave off the "http://" — just the address, like garage.example.com\n'; return 1 ;;
    *[!a-zA-Z0-9.-]*) printf '    Web addresses only contain letters, numbers, dots and hyphens.\n'; return 1 ;;
    # `localhost` has no dot but is perfectly valid, and is the obvious thing to type for a trial run.
    localhost)       return 0 ;;
    *.*)             return 0 ;;
    *)               printf '    That needs to be a full address like garage.example.com, or "localhost" to try it on this machine.\n'; return 1 ;;
  esac
}
valid_email() {
  case "$1" in
    ?*@?*.?*) return 0 ;;
    *) printf '    That doesn'\''t look like an email address.\n'; return 1 ;;
  esac
}
valid_any() { [ -n "$1" ] || { printf '    This one is needed.\n'; return 1; }; return 0; }

# Addresses that can never get a public certificate. Nobody on the internet can prove ownership of
# them, so Caddy would fall back to its own private authority and every browser would reject the
# result with ERR_CERT_AUTHORITY_INVALID. Plain HTTP is the right answer on a loopback address.
is_local_address() {
  case "$1" in
    localhost|*.localhost|0.0.0.0) return 0 ;;
    # Private ranges (RFC 1918) and loopback. A certificate authority will never issue for these,
    # so anything on a home or office network belongs here too, not just the machine itself.
    10.*|127.*|192.168.*) return 0 ;;
    172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 0 ;;
    # Names that only ever resolve inside a local network.
    *.local|*.lan|*.home|*.internal|*.localdomain|*.test|*.example) return 0 ;;
    *) return 1 ;;
  esac
}

# ask <var> <label> <description> <default> <validator>
ask() {
  local __var="$1" label="$2" desc="$3" def="$4" validator="$5" reply=""
  # Non-interactive: take the flag/default, and fail loudly if there isn't one.
  if [ -z "$TTY_IN" ]; then
    reply="${!__var:-$def}"
    [ -n "$reply" ] || die "Need a value for ${label}. Pass it as a flag, or run without --yes to be asked."
    printf -v "$__var" '%s' "$reply"
    return 0
  fi
  # Already supplied on the command line — don't ask again.
  if [ -n "${!__var:-}" ]; then return 0; fi
  while :; do
    printf '\n  %s%s%s\n' "$B" "$label" "$N"
    printf '  %s%s%s\n' "$D" "$desc" "$N"
    if [ -n "$def" ]; then printf '  %s[%s]%s\n  > ' "$D" "$def" "$N"; else printf '  > '; fi
    IFS= read -r reply < "$TTY_IN" || reply=""
    reply="${reply:-$def}"
    if "$validator" "$reply"; then printf -v "$__var" '%s' "$reply"; return 0; fi
  done
}

confirm() {
  [ -n "$TTY_IN" ] || return 0
  local reply=""
  printf '\n  %s%s%s [Y/n] ' "$B" "$1" "$N"
  IFS= read -r reply < "$TTY_IN" || reply=""
  case "${reply:-y}" in [Yy]*|"") return 0 ;; *) return 1 ;; esac
}

# ── Checks ──────────────────────────────────────────────────────────────────────────────────────
[ "$(id -u)" -eq 0 ] || die "Please run this with sudo."
command -v apt-get >/dev/null 2>&1 || die "This installer is for Ubuntu and Debian. On another system, install Docker yourself and use the docker-compose.yml in this repository."
[ "$(uname -m)" = "x86_64" ] || die "GRG is published for 64-bit Intel/AMD servers (x86_64). This machine is $(uname -m)."

cat <<EOF

  ${B}GRG installer${N}

  This sets up GRG on this server: the application, its database, sign-in, and
  storage for photos. It installs anything that's missing, so a clean server is fine.

  It takes about five minutes. You'll be asked a few questions first.
EOF

# ── Questions ───────────────────────────────────────────────────────────────────────────────────
ask APP_DOMAIN "Web address" \
  "The address people will type to open GRG. It must already point at this server." \
  "" valid_domain

# An IP address can't have a "media." prefix put in front of it, and photos need their own hostname
# (their links are signed against it). Caught here rather than letting images silently fail later.
case "$APP_DOMAIN" in
  *[!0-9.]*) ;;
  *.*.*.*)
    die "Please use a name rather than an IP address.

Photos are served from a second address — normally media.${APP_DOMAIN} — and
\"media.${APP_DOMAIN}\" isn't a valid name, so pictures would never load.

On a home or office network, pick any name ending in .lan and point it at this
server by adding two lines to /etc/hosts on each computer that will use GRG:

    ${APP_DOMAIN}   grg.lan
    ${APP_DOMAIN}   media.grg.lan

Then run:  sudo ./install.sh --domain grg.lan" ;;
esac

ask MEDIA_DOMAIN "Address for photos and videos" \
  "Photos and videos are served from a separate address for technical reasons. This one must point at this server too. Press Enter to accept." \
  "media.${APP_DOMAIN}" valid_domain

# A local install needs no certificate, no email, and no DNS — decided here so the questions below
# and every check further down can skip what doesn't apply.
if is_local_address "$APP_DOMAIN"; then
  SITE_SCHEME="http"
  SKIP_DNS_CHECK=1
  ACME_EMAIL="${ACME_EMAIL:-none@localhost}"
  info ""
  info "${APP_DOMAIN} is a local address, so GRG will be served over plain http://."
  info "No certificate is involved, and your browser won't warn about one."
else
  SITE_SCHEME="https"
  ask ACME_EMAIL "Your email address" \
    "Used only to warn you if the site's security certificate is about to expire. Never shown to anyone else." \
    "admin@${APP_DOMAIN#*.}" valid_email
fi

ask ADMIN_EMAIL "Sign-in email for the first account" \
  "The account you'll use to log in and create everyone else. A password is generated for you and shown at the end." \
  "${ACME_EMAIL}" valid_email

ask ADMIN_NAME "Name for that account" \
  "How this person's name appears inside GRG." \
  "GRG Admin" valid_any

cat <<EOF

  ${D}Everything else is generated automatically and stored on this server only:
  the database password, the encryption key for the sign-in system (ZITADEL),
  and the keys for photo storage (Garage, S3-compatible). You never need to
  choose or remember any of them.${N}

  ${B}Ready to install${N}
    Web address        ${SITE_SCHEME}://${APP_DOMAIN}
    Photos and videos  ${SITE_SCHEME}://${MEDIA_DOMAIN}
    First account      ${ADMIN_EMAIL}  (${ADMIN_NAME})
    Installing into    ${INSTALL_DIR}
EOF

# ── Basic tools ─────────────────────────────────────────────────────────────────────────────────
# Installed before the checks below because those need curl. Deliberately ahead of the "Continue?"
# confirmation: these are small, standard packages, and without them nothing can be verified.
step "Preparing"
export DEBIAN_FRONTEND=noninteractive
missing=""
for pkg in ca-certificates curl openssl; do
  case "$pkg" in
    ca-certificates) dpkg -s "$pkg" >/dev/null 2>&1 || missing="$missing $pkg" ;;
    *) command -v "$pkg" >/dev/null 2>&1 || missing="$missing $pkg" ;;
  esac
done
if [ -n "$missing" ]; then
  apt-get update -qq
  # shellcheck disable=SC2086
  apt-get install -y -qq $missing >/dev/null
fi

# ── Ports ───────────────────────────────────────────────────────────────────────────────────────
# Many server images ship Apache or nginx already listening on 80. Caddy needs both ports to serve
# the site AND to prove to Let's Encrypt that you own the address, so a conflict has to be resolved
# before anything else — otherwise the first run gets all the way to the end and then fails.
step "Checking ports 80 and 443"
busy=""
for port in 80 443; do
  if command -v ss >/dev/null 2>&1; then
    ss -Hltn "sport = :$port" 2>/dev/null | grep -q . && busy="$busy $port"
  elif command -v netstat >/dev/null 2>&1; then
    netstat -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}\$" && busy="$busy $port"
  fi
done
if [ -n "$busy" ]; then
  # ss reports the owner as users:(("nginx",pid=…)) — pull out just the quoted program name.
  holder="$(ss -Hltnp "sport = :80" 2>/dev/null | grep -oE '"[^"]+"' | head -1 | tr -d '"' || true)"
  die "Port${busy} already in use${holder:+ (by ${holder})}.

GRG needs ports 80 and 443. Another web server is probably already running.
If it's Apache or nginx and you don't need it:

    sudo systemctl disable --now apache2 2>/dev/null || true
    sudo systemctl disable --now nginx 2>/dev/null || true

Then run this again."
fi
info "Both ports are free."

# ── Web addresses ───────────────────────────────────────────────────────────────────────────────
# Checked BEFORE installing anything, and offered as something to fix right now, because this is
# the one prerequisite the installer can't do for you — and getting it wrong is the difference
# between the first run working and the first run needing a second run.
step "Checking your web addresses"
if [ "$SKIP_DNS_CHECK" -eq 1 ]; then
  info "Skipped."
else
  public_ip="$(curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
  if [ -z "$public_ip" ]; then
    warn "Couldn't work out this server's public address — skipping the check."
  else
    info "This server is ${public_ip}"
    while :; do
      bad=""
      for host in "$APP_DOMAIN" "$MEDIA_DOMAIN"; do
        # `|| true` is load-bearing: getent exits 2 for a name that doesn't resolve, and with
        # pipefail + set -e that would abort the installer instead of showing the instructions
        # below — exactly when someone's DNS isn't set up yet.
        resolved="$(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1; exit}' || true)"
        if [ "$resolved" = "$public_ip" ]; then
          info "${host} ✓"
        elif [ -z "$resolved" ]; then
          info "${host} — not set up yet"; bad="yes"
        else
          info "${host} — points at ${resolved} instead"; bad="yes"
        fi
      done
      [ -z "$bad" ] && break

      cat <<EOF

  ${Y}Both addresses need to point at this server before GRG can get its
  security certificate. Add these two records with whoever manages your
  domain, then come back to this window:${N}

      Type    Name                      Value
      A       ${APP_DOMAIN}    ${public_ip}
      A       ${MEDIA_DOMAIN}    ${public_ip}

  ${D}New records usually work within a few minutes.${N}
EOF
      if [ -z "$TTY_IN" ]; then
        die "Addresses aren't pointing here yet. Add the records above and run this again."
      fi
      printf '\n  %sPress Enter to check again, or type "skip" to carry on anyway:%s ' "$B" "$N"
      IFS= read -r again < "$TTY_IN" || again="skip"
      case "$again" in
        [Ss]*) warn "Carrying on. HTTPS won't work until the addresses point here."; break ;;
      esac
    done
  fi
fi

cat <<EOF

  ${B}Ready${N} — everything checks out. This takes about five minutes.
EOF
confirm "Continue?" || die "Nothing was changed."

# ── Dependencies ────────────────────────────────────────────────────────────────────────────────
step "Installing what's missing"
missing=""
for pkg in gnupg tar ufw; do
  case "$pkg" in
    ca-certificates|gnupg) dpkg -s "$pkg" >/dev/null 2>&1 || missing="$missing $pkg" ;;
    *) command -v "$pkg" >/dev/null 2>&1 || missing="$missing $pkg" ;;
  esac
done
if [ -n "$missing" ]; then
  info "Installing:$missing"
  apt-get update -qq
  # shellcheck disable=SC2086
  apt-get install -y -qq $missing >/dev/null
else
  info "Basic tools already present."
fi

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  info "Docker already present: $(docker --version)"
else
  info "Installing Docker…"
  # Docker's own repository — the version in Ubuntu/Debian omits the compose plugin this needs.
  install -m 0755 -d /etc/apt/keyrings
  . /etc/os-release
  curl -fsSL "https://download.docker.com/linux/${ID:-debian}/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${ID:-debian} ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
  info "Installed: $(docker --version)"
fi
systemctl enable --now docker >/dev/null 2>&1 || true
docker compose version >/dev/null 2>&1 || die "Docker installed but 'docker compose' isn't working. Try running this script again."

# ── Files ───────────────────────────────────────────────────────────────────────────────────────
step "Downloading GRG"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "")"
if [ -n "$script_dir" ] && [ -f "${script_dir}/docker-compose.yml" ]; then
  INSTALL_DIR="$script_dir"
  info "Using the files next to this script: ${INSTALL_DIR}"
else
  mkdir -p "$INSTALL_DIR"
  curl -fsSL "https://codeload.github.com/${BUNDLE_REPO}/tar.gz/refs/heads/${BUNDLE_REF}" \
    | tar -xz -C "$INSTALL_DIR" --strip-components=1 \
    || die "Couldn't download GRG. Check this server can reach github.com."
  info "Downloaded into ${INSTALL_DIR}"
fi
cd "$INSTALL_DIR"
[ -f docker-compose.yml ] || die "Something's wrong — docker-compose.yml is missing from ${INSTALL_DIR}."

# ── Settings file ───────────────────────────────────────────────────────────────────────────────
step "Writing settings"
rand_hex() { openssl rand -hex "$1"; }
# The sign-in system requires upper + lower + digit + symbol; the fixed tail guarantees all four.
gen_password() { printf '%sAa1!' "$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | cut -c1-20)"; }

if [ -f .env ]; then
  info "Settings already exist here — keeping them, including your encryption key."
  APP_DOMAIN="$(grep -E '^APP_DOMAIN=' .env | cut -d= -f2- || echo "$APP_DOMAIN")"
  MEDIA_DOMAIN="$(grep -E '^MEDIA_DOMAIN=' .env | cut -d= -f2- || echo "$MEDIA_DOMAIN")"
  SITE_SCHEME="$(grep -E '^SITE_SCHEME=' .env | cut -d= -f2- || echo "${SITE_SCHEME:-https}")"
  ADMIN_EMAIL="$(grep -E '^FIRST_ADMIN_EMAIL=' .env | cut -d= -f2- || echo "$ADMIN_EMAIL")"
  FRESH_INSTALL=0
else
  # Storage volumes are named after the project, not this folder, so they survive re-downloading
  # into a new path. A new encryption key against an existing database makes that data unreadable
  # forever — stop instead of destroying it.
  if docker volume ls -q 2>/dev/null | grep -qE '^grg_(pg_data|machinekey)$'; then
    die "There's already GRG data on this server, but no settings file in $(pwd).

Creating new settings now would generate a new encryption key, and your existing
data could never be read again.

  • Updating an existing install? Run the script from its original folder
    (usually ${INSTALL_DIR}), or copy its .env file here first.

  • Starting fresh, and the old data doesn't matter? Delete it with
      docker compose -p grg down -v
    then run this again."
  fi

  ADMIN_PASSWORD="$(gen_password)"
  umask 077
  cat > .env <<EOF
# GRG settings, created $(date -u +%Y-%m-%dT%H:%M:%SZ). Keep this file private.
#
# ZITADEL_MASTERKEY encrypts the sign-in database. Back this file up together with your data —
# without it, a restored backup cannot be read.

APP_DOMAIN=${APP_DOMAIN}
MEDIA_DOMAIN=${MEDIA_DOMAIN}
ACME_EMAIL=${ACME_EMAIL}
# http only for localhost-style addresses, which can't have a real certificate. https everywhere else.
SITE_SCHEME=${SITE_SCHEME}
GRG_VERSION=${GRG_VERSION:-latest}

DB_NAME=grg
DB_USER=grg
DB_PASSWORD=$(rand_hex 24)

ZITADEL_MASTERKEY=$(rand_hex 16)

FIRST_ADMIN_EMAIL=${ADMIN_EMAIL}
FIRST_ADMIN_PASSWORD=${ADMIN_PASSWORD}
FIRST_ADMIN_FULL_NAME=${ADMIN_NAME}

GARAGE_RPC_SECRET=$(rand_hex 32)
GARAGE_ADMIN_TOKEN=$(rand_hex 32)
GARAGE_ACCESS_KEY_ID=GK$(rand_hex 12)
GARAGE_SECRET_ACCESS_KEY=$(rand_hex 32)
EOF
  chmod 600 .env
  info "Created ${INSTALL_DIR}/.env — readable only by root."
  FRESH_INSTALL=1
fi

if [ -n "$GRG_VERSION" ]; then
  if grep -q '^GRG_VERSION=' .env; then
    sed -i "s|^GRG_VERSION=.*|GRG_VERSION=${GRG_VERSION}|" .env
  else
    printf '\nGRG_VERSION=%s\n' "$GRG_VERSION" >> .env
  fi
  info "Using version ${GRG_VERSION}."
fi

# ── Firewall ────────────────────────────────────────────────────────────────────────────────────
if [ "$CONFIGURE_FIREWALL" -eq 1 ] && command -v ufw >/dev/null 2>&1; then
  step "Securing the server"
  # Allow SSH first — turning the firewall on without it would lock you out of your own server.
  ufw allow OpenSSH >/dev/null 2>&1 || ufw allow 22/tcp >/dev/null 2>&1 || true
  ufw allow 80/tcp  >/dev/null 2>&1 || true
  ufw allow 443/tcp >/dev/null 2>&1 || true
  if ufw status | head -1 | grep -q inactive; then
    ufw --force enable >/dev/null 2>&1 || warn "Couldn't turn the firewall on — please configure it yourself."
  fi
  info "Only web traffic and SSH can reach this server. The database and storage stay internal."
fi

# ── Start ───────────────────────────────────────────────────────────────────────────────────────
step "Downloading the application"
docker compose pull || die "Couldn't download the application. Check this server can reach ghcr.io."

step "Starting GRG"
docker compose up -d

step "Waiting for it to come up"
ready=0
for _ in $(seq 1 60); do
  # 401 means "you're not signed in" — exactly right for a healthy server that's now serving.
  code="$(curl -fsS -o /dev/null -w '%{http_code}' -m 5 -k "${SITE_SCHEME}://${APP_DOMAIN}/api/auth/me" 2>/dev/null || echo 000)"
  case "$code" in 401|200) ready=1; break ;; esac
  sleep 5
done

if [ "$ready" -eq 1 ]; then
  step "GRG is ready"
else
  step "Started, but not answering yet"
  warn "The application is still starting, or the addresses aren't pointing here yet."
  warn "Check on it with:  cd ${INSTALL_DIR} && docker compose logs -f"
fi

cat <<EOF

  ${B}Open${N}        ${SITE_SCHEME}://${APP_DOMAIN}
  ${B}Installed${N}   ${INSTALL_DIR}
EOF

if [ "${FRESH_INSTALL:-0}" -eq 1 ]; then
  cat <<EOF
  ${B}Sign in${N}     ${ADMIN_EMAIL}
  ${B}Password${N}    ${ADMIN_PASSWORD}

  ${Y}Write that password down now — it isn't shown again. GRG will ask you to
  change it the first time you sign in.${N}

  ${Y}Back up ${INSTALL_DIR}/.env somewhere safe. It holds the key that unlocks
  your data; a backup restored without it can't be read.${N}
EOF
else
  info "Updated. Your sign-in details haven't changed."
fi

cat <<EOF

  See what's happening   cd ${INSTALL_DIR} && docker compose logs -f
  Restart                cd ${INSTALL_DIR} && docker compose restart
  Update to the latest   sudo ${INSTALL_DIR}/install.sh --yes

EOF
