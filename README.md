# Nuvio Self-Hosted

Host your own Nuvio backend on a Linux server with Docker Compose. Your
deployment includes PostgreSQL, account sign-in, synchronization, file
storage, and automatic HTTPS. Studio and Realtime are optional.

## Requirements

- A 64-bit Linux host using `amd64` or `arm64`
- Docker Engine with Docker Compose v2
- Git, OpenSSL, and curl (`jq` is also required for account imports)
- A domain pointed at the server for an HTTPS deployment

Use at least 4 GB RAM, 2 CPU cores, and 40 GB SSD storage. For a public server
used by several people, 8 GB RAM, 4 cores, and 80 GB SSD storage are
recommended.

## Quick Start

Clone and start a local deployment:

```sh
git clone https://github.com/NuvioMedia/nuvio-self-hosted
cd nuvio-self-hosted
./nuvio setup
./nuvio up
./nuvio credentials
```

The backend is available at `http://localhost:8000`.

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

## Optional Services

Fresh installations omit Studio, its postgres-meta sidecar, and Realtime to
reduce resource usage and exposed surface area. Enable either service during
initial setup only when it is needed:

```sh
./nuvio setup --with-studio
./nuvio setup --with-realtime
./nuvio setup --with-studio --with-realtime
```

The selected services are stored as a comma-separated list in
`COMPOSE_PROFILES`. To change an existing deployment, first run `./nuvio down`,
edit `COMPOSE_PROFILES` in `.env`, and then run `./nuvio up`. Use an empty value
for the minimal stack:

```env
COMPOSE_PROFILES=
```

Configurations created before optional profiles were introduced continue to
run Studio and Realtime until `COMPOSE_PROFILES` is explicitly added.

## Connect Nuvio

Connect your Nuvio apps with the two values shown by `./nuvio credentials`:

- **Backend URL**
- **Publishable key**

The publishable key is safe to enter in a Nuvio app. Never enter the
service-role key, Supabase secret key, database password, or Studio password in
an app.

If you build the apps yourself, see
[Connect Nuvio Apps](docs/client-configuration.md) for Android TV, Mobile,
Desktop, Web, Tizen, and webOS settings.

## Move Your Nuvio Cloud Account

During interactive setup, you can choose to move your existing Nuvio Cloud
account to this server. If you choose yes, the importer starts after the
backend passes its first health check. You can also request this directly:

```sh
./nuvio setup --import-account
./nuvio up
```

If your server is already set up, run:

```sh
./nuvio import-account
```

Enter the email and password you use with Nuvio Cloud. Your password is hidden
while you type and is never accepted as a command-line argument, logged, or
written to disk. The importer signs in as you, downloads only your account
backup, and creates a local sign-in with the same email and password.

Profiles, add-ons, plugins, library entries, watch progress, watched history,
settings, collections, and tracker preferences are restored. Your referenced
avatar and cover files are copied to this server and updated to use its
address. If the same email already exists locally, you can review the backup
counts before confirming that its local app data should be replaced.

For your security, password hashes and Cloud account IDs are never copied.
Signed-in sessions, MFA and passkey enrollments, profile PINs, linked devices,
tracker sign-ins, provider credentials, and login history stay behind. After
the import, reconnect those services and set up your security factors again.

## Commands

| Command | Description |
| --- | --- |
| `./nuvio setup` | Generate secrets and configure the deployment |
| `./nuvio up` | Start services, apply migrations, seed catalog assets, and run health checks |
| `./nuvio down` | Stop services while preserving data |
| `./nuvio restart` | Restart all services |
| `./nuvio status` | Show service status |
| `./nuvio logs [SERVICE]` | Follow logs for all services or one service |
| `./nuvio doctor` | Check that the backend services are healthy |
| `./nuvio credentials` | Show the values needed to connect your apps and, when enabled, Studio |
| `./nuvio import-account` | Move your authenticated Nuvio Cloud account to this server |
| `./nuvio migrate` | Apply database updates and add missing built-in avatars |
| `./nuvio configure` | Apply your settings from `.env` |
| `./nuvio backup` | Back up PostgreSQL data and local Storage files |
| `./nuvio restore BACKUP --yes` | Restore a backup after creating a safety backup |
| `./nuvio pull` | Pull the configured container images |

## Configuration

`./nuvio setup` creates an ignored `.env` file with unique deployment secrets.
Common settings include:

| Setting | Purpose |
| --- | --- |
| `COMPOSE_PROFILES` | Optional `studio` and `realtime` services |
| `DEFAULT_CATALOG_URL` | Catalog added to new Nuvio profiles |
| `NUVIO_CLOUD_URL` | Nuvio Cloud address used when moving an account |
| `NUVIO_CLOUD_PUBLISHABLE_KEY` | Public Nuvio Cloud key used to sign in during an import |
| `IMPORT_ACCOUNT_AFTER_UP` | Run the importer after the next successful startup |
| `SITE_URL` | Default authentication redirect URL |
| `ADDITIONAL_REDIRECT_URLS` | Additional allowed authentication redirects |
| `ENABLE_EMAIL_AUTOCONFIRM` | Automatically confirm new email accounts |
| `SMTP_*` | SMTP server and sender configuration |
| `KONG_HTTP_PORT` | Local backend and optional Studio port |
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

`./nuvio up` applies pending database updates before checking the deployment.
It also uploads any missing avatars included with Nuvio. This update does not
replace or remove files that you uploaded.

## Data

- PostgreSQL data: `volumes/db/data/`
- Storage files: `volumes/storage/`
- Bundled avatar seed assets: `assets/avatars/`
- Backups: `backups/`
- Deployment configuration and secrets: `.env`

`./nuvio down` stops Nuvio but preserves all of these files.

## Security

Review [SECURITY.md](SECURITY.md) before exposing the backend to the internet.

## Architecture

See [docs/architecture.md](docs/architecture.md) for the service layout and
request flow.

## License

Licensed under the Apache License 2.0. See [LICENSE](LICENSE) and
[NOTICE](NOTICE).
