# GRG

Management software for vehicle-repair garages: clients and their vehicles, service visits from
drop-off to hand-back, repair work and parts, payments and invoicing, staff roles, and reporting.

Run it on your own server. One command, a few questions, about five minutes.

## Install

On a fresh Ubuntu or Debian server:

```bash
curl -fsSL https://raw.githubusercontent.com/gravestone-codes/grg-public/main/install.sh | sudo bash
```

It asks you a few things — your web address, your email, the first sign-in account — then installs
everything that's missing, sets it all up, and starts it. When it finishes it prints the address to
open and the password for your first login.

**You need:** a server with 1 GB of memory running Ubuntu or Debian, 64-bit Intel or AMD, and two
web addresses pointing at it (below).

### Web addresses

Set up two DNS "A" records at your domain provider, both pointing at your server's IP address,
**before** you install. The installer checks them and tells you if something's wrong.

| Address | What it's for |
|---|---|
| `garage.yourcompany.com` | the system itself |
| `media.garage.yourcompany.com` | photos and videos |

Photos are served from a separate address for technical reasons — the security signatures on image
links are tied to the exact address they were created for. The installer suggests
`media.` + your main address, and you can change it.

If you'd rather answer everything up front instead of being asked:

```bash
sudo ./install.sh --domain garage.yourcompany.com --email you@yourcompany.com --yes
```

Run `./install.sh --help` for all options.

## What gets installed

Everything runs in containers on your server. Nothing is sent anywhere else, and there is no
telemetry.

| | |
|---|---|
| **The application** | the garage system itself, and its web interface |
| **PostgreSQL** | your data |
| **ZITADEL** | handles sign-in and passwords securely |
| **Garage** | stores photos and videos (S3-compatible) |
| **Caddy** | serves the site and gets your HTTPS certificate automatically |

Only the web server is reachable from the internet. The database, sign-in system and file storage
are only reachable from inside your server.

Passwords and encryption keys are generated on your machine during install and never leave it.

## After installing

The installer prints a password for your first account **once**. Write it down — GRG asks you to
change it the first time you sign in.

**Back up `/opt/grg/.env`.** It holds the key that unlocks your data. A backup of your database
restored without this file cannot be read. Keep a copy somewhere safe and separate.

## Updating

Run the installer again. It fetches the latest version and restarts, and never touches your
settings or data:

```bash
sudo /opt/grg/install.sh --yes
```

To go back to a previous version, or pin a specific one:

```bash
sudo /opt/grg/install.sh --yes --version sha-1a2b3c4
```

## Day to day

```bash
cd /opt/grg
docker compose logs -f     # watch what's happening
docker compose ps          # what's running
docker compose restart     # restart everything
```

## Notes

- **64-bit Intel/AMD servers only** (x86_64).
- **Ubuntu and Debian.** On another system, install Docker yourself and use the
  `docker-compose.yml` here directly.
- The application images are `ghcr.io/gravestone-codes/grg-backend` (~124 MB to download) and
  `grg-frontend` (~5 MB). Every published version is started against a real database in CI and has
  to serve traffic before it is released.
- Updates are small. The Java runtime and the libraries sit in their own layers that rarely change,
  so a normal update downloads only a few MB rather than the whole image again.

## License

MIT — see [LICENSE](LICENSE).
