# Nuvio Self-Hosted

Run the Nuvio backend on a Linux server with Docker Compose. The deployment
includes PostgreSQL, authentication, the Nuvio sync API, Storage, Realtime,
Edge Functions, Studio, and automatic HTTPS.

## Requirements

- A 64-bit Linux host using `amd64` or `arm64`
- Docker Engine with Docker Compose v2
- Git, OpenSSL, and curl
- A domain pointed at the server for an HTTPS deployment

Use at least 4 GB RAM, 2 CPU cores, and 40 GB SSD storage. For a production
server, 8 GB RAM, 4 cores, and 80 GB SSD storage are recommended.

## Quick Start

Clone and start a local deployment:

```sh
git clone https://github.com/NuvioMedia/nuvio-self-hosted
cd nuvio-self-hosted
./nuvio setup
./nuvio up
./nuvio credentials
```

The backend and Studio are available at `http://localhost:8000`. Open that URL
in a browser and sign in with the Studio username and password printed by
`./nuvio credentials`.

## HTTPS Deployment

Create an `A` or `AAAA` DNS record for the backend, allow inbound TCP ports 80
and 443, then run:

```sh
./nuvio setup --domain backend.example.com --app-url https://nuvio.tv
./nuvio up
./nuvio credentials
```

Caddy obtains and renews the TLS certificate. PostgreSQL and its connection
pooler remain bound to localhost.

`--app-url` configures the allowed authentication redirect origin. To use a
different default Nuvio catalog, add `--catalog-url` during setup:

```sh
./nuvio setup \
  --domain backend.example.com \
  --app-url https://nuvio.tv \
  --catalog-url https://catalog.example.com/manifest.json
```

## Connect Nuvio

Configure the Nuvio client with the two values shown by `./nuvio credentials`:

- **Backend URL**
- **Publishable key**

The publishable key is intended for client applications. Never place the
service-role key, Supabase secret key, database password, or Studio password in
a client.

See [Configure Nuvio Clients](docs/client-configuration.md) for the exact
settings used by Android TV, Mobile, Desktop, Web, Tizen, and webOS builds.

## Commands

| Command | Description |
| --- | --- |
| `./nuvio setup` | Generate secrets and configure the deployment |
| `./nuvio up` | Start services, apply migrations, seed catalog assets, and run health checks |
| `./nuvio down` | Stop services while preserving data |
| `./nuvio restart` | Restart all services |
| `./nuvio status` | Show service status |
| `./nuvio logs [SERVICE]` | Follow logs for all services or one service |
| `./nuvio doctor` | Check Auth, REST, Storage, and Edge Functions |
| `./nuvio credentials` | Show the backend, client, and Studio credentials |
| `./nuvio migrate` | Apply pending migrations and seed catalog assets |
| `./nuvio configure` | Apply instance settings from `.env` |
| `./nuvio backup` | Back up PostgreSQL data and local Storage files |
| `./nuvio restore BACKUP --yes` | Restore a backup after creating a safety backup |
| `./nuvio pull` | Pull the configured container images |

## Configuration

`./nuvio setup` creates an ignored `.env` file with unique deployment secrets.
Common settings include:

| Setting | Purpose |
| --- | --- |
| `DEFAULT_CATALOG_URL` | Catalog added to new Nuvio profiles |
| `SITE_URL` | Default authentication redirect URL |
| `ADDITIONAL_REDIRECT_URLS` | Additional allowed authentication redirects |
| `ENABLE_EMAIL_AUTOCONFIRM` | Automatically confirm new email accounts |
| `SMTP_*` | SMTP server and sender configuration |
| `KONG_HTTP_PORT` | Local backend and Studio port |
| `POSTGRES_PORT` | Local PostgreSQL session-pooler port |
| `POOLER_PROXY_PORT_TRANSACTION` | Local PostgreSQL transaction-pooler port |

After changing `DEFAULT_CATALOG_URL`, run `./nuvio configure`. After changing a
service setting, run `./nuvio up`.

## Backups

Create a backup with:

```sh
./nuvio backup
```

The command briefly stops API services, captures PostgreSQL and local Storage
consistently, restarts the stack, and runs health checks. Backups are written to
`backups/` with a manifest and checksums.

Restore a backup directory with:

```sh
./nuvio restore backups/nuvio-20260711T120000Z-a1b2c3 --yes
```

Restore verifies checksums and creates a safety backup before replacing data.

## Updating

```sh
git pull --ff-only
./nuvio pull
./nuvio up
```

`./nuvio up` applies pending migrations before checking the deployment.
It also uploads any missing bundled avatar catalog assets through the Storage
API. User-uploaded production objects are never included in this seed.

## Data

- PostgreSQL data: `volumes/db/data/`
- Storage files: `volumes/storage/`
- Bundled avatar seed assets: `assets/avatars/`
- Backups: `backups/`
- Deployment configuration and secrets: `.env`

`./nuvio down` preserves these files.

## Security

Review [SECURITY.md](SECURITY.md) before exposing the backend to the internet.

## Architecture

See [docs/architecture.md](docs/architecture.md) for the service layout and
request flow.

## License

Licensed under the Apache License 2.0. See [LICENSE](LICENSE) and
[NOTICE](NOTICE).
