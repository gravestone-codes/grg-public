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

**You need:** a server with 1 GB of memory running Ubuntu or Debian, 64-bit Intel or AMD. A domain
name is optional — without one it runs on your network address and everyone on the network can
reach it.

### If you have a domain name

Set up two DNS "A" records at your domain provider, both pointing at your server's IP address,
**before** you install. The installer checks them, and waits while you fix them if they're wrong.
You get HTTPS automatically.

Skip this entirely if you don't have a domain — see below.

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

### No domain name? That's fine

Press Enter when it asks for the web address and it uses the server's own network address. Everyone
on the same network can reach it immediately — no domain, no DNS, nothing to configure on anyone
else's computer.

    Web address
    What people will type to open GRG. Use your domain name if you have one. If this
    is a server on your own network, press Enter to use its network address.
    [192.168.1.50]
    >

You'd then open `http://192.168.1.50`. Photos are served from port 8081 of the same address
automatically, so there's nothing else to set up.

This mode uses plain HTTP, because certificates can't be issued for private addresses. That's fine
on a network you control. Don't expose it to the internet that way — use a real domain, and the
installer will set up HTTPS for you.

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

- **Broken IPv6 is handled for you.** Some servers have an IPv6 address but no route out over it.
  Downloads then resolve to IPv6 and fail halfway through, while everything else looks fine. The
  installer detects this and turns IPv6 off before downloading. Pass `--keep-ipv6` to skip that,
  and undo it any time with
  `sudo rm /etc/sysctl.d/99-grg-no-ipv6.conf && sudo sysctl --system`.

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
