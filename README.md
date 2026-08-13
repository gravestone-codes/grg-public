# GRG — deploy

Everything needed to run **GRG**, a garage management system for vehicle-repair operations, on
your own server. This repository holds the deployment bundle only — the application ships as
prebuilt container images, so nothing is compiled on your host.

## Install

On a fresh Ubuntu or Debian server, as root:

```bash
curl -fsSL https://raw.githubusercontent.com/gravestone-codes/grg-public/main/install.sh \
  | sudo bash -s -- --domain garage.example.com --email you@example.com
```

That installs Docker, generates every secret, configures the firewall, pulls the images, obtains
TLS certificates, and starts the stack. It prints the admin sign-in details when it finishes.

Requirements: a 1 GB x86_64 VPS, ports 80 and 443 reachable, and the two DNS records below.

### DNS — two records, before you install

Both must point at the server and resolve *before* the first run. Caddy proves domain ownership
over HTTP to obtain Let's Encrypt certificates, which fails without working DNS.

| Record | Serves |
|---|---|
| `garage.example.com` | the app — SPA and API |
| `media.garage.example.com` | images and video, via presigned URLs |

Media needs its own hostname rather than a path under the first: those URLs are S3 SigV4-signed
over the `Host` header, so any host or path rewrite invalidates the signature. Use
`--media-domain` if you want a different name for it.

## What gets installed

| Component | Role |
|---|---|
| **Caddy** | the only thing exposed to the network; TLS, static SPA, API proxy |
| **Spring Boot API** | all business logic |
| **PostgreSQL 18** | application and identity data |
| **ZITADEL** | identity provider — headless, no public hostname, users never see it |
| **Garage** | S3-compatible object storage for photos, video, and client logos |

Only Caddy publishes ports. Postgres, ZITADEL, and Garage stay on the internal Docker network.

Images are built and published from the application repository on every change, tagged by commit,
and smoke-tested — booted against a real database and required to serve traffic — before `latest`
moves to them.

- `ghcr.io/gravestone-codes/grg-backend`
- `ghcr.io/gravestone-codes/grg-frontend`

## After installing

The installer prints a generated admin email and password **once**. The application forces a
password change at first sign-in.

**Back up `/opt/grg/.env` together with the Postgres volume.** The `ZITADEL_MASTERKEY` in that file
encrypts everything the identity provider stores; a database restored without its matching
masterkey cannot be read. This is the one irreversible way to lose your data.

## Updating

Re-run the installer. It pulls the current images and restarts, and never overwrites an existing
`.env`, so your secrets and masterkey survive:

```bash
sudo /opt/grg/install.sh --domain garage.example.com
```

### Pinning and rolling back

Every build is tagged with its commit. Deploy a specific one, or go back to a previous one:

```bash
sudo /opt/grg/install.sh --domain garage.example.com --version sha-1a2b3c4
```

The chosen tag is written to `.env` as `GRG_VERSION`, so later re-runs stay there rather than
drifting back to `latest`.

## Operating

```bash
cd /opt/grg
docker compose logs -f            # follow everything
docker compose logs -f backend    # just the API
docker compose ps                 # what's running
docker compose restart            # restart in place
```

## Configuration

`install.sh` generates `.env` for you. `.env.example` documents every setting if you want to write
it yourself — the domains, the database credentials, the ZITADEL masterkey, the first admin, and
the Garage storage keys.

Run `install.sh --help` for the full flag list.

## Notes

- **x86_64 only.** The published images are `linux/amd64`.
- **Debian and Ubuntu.** The installer uses `apt-get`. On another distribution, install Docker
  yourself, then use the compose file here directly.
- **Each installation is independent.** Secrets are generated per host; nothing is shared, and no
  telemetry is sent anywhere.
