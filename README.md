# Nuvio Self-Hosted

Run an empty, private Nuvio backend on your own Linux server. The stack packages
Nuvio's PostgreSQL schema, Row Level Security policies, RPC functions, Edge
Functions, Auth, Storage, Realtime, and Studio on top of self-hosted Supabase.

This repository is an early private beta. It contains no Nuvio production data,
user accounts, credentials, database backups, or storage objects.

## Quick Start

Requirements: Docker Engine, Docker Compose v2, OpenSSL, and curl.

For a local instance:

```sh
git clone https://github.com/tapframe/nuvio-self-hosted
cd nuvio-self-hosted
./nuvio setup
./nuvio up
./nuvio credentials
```

The API and Studio will be available at `http://localhost:8000`. Studio is
protected by the generated username and password shown by `./nuvio credentials`.

For an internet-facing server, point a DNS record at the server and open ports
80 and 443 before starting:

```sh
./nuvio setup --domain backend.example.com --app-url https://nuvio.tv
./nuvio up
```

Caddy obtains and renews HTTPS certificates automatically. The database and
connection-pooler ports remain bound to localhost.

## Connect Nuvio

The Nuvio client needs two values from `./nuvio credentials`:

- Backend URL
- Publishable key

The publishable key is the legacy Supabase `anon` key and is safe to place in a
client. Never place `SERVICE_ROLE_KEY`, `SUPABASE_SECRET_KEY`, or the database
password in a client.

## Operations

```sh
./nuvio status
./nuvio logs auth
./nuvio doctor
./nuvio backup
./nuvio down
```

`./nuvio down` preserves all data. There is intentionally no one-command data
reset in the initial release.

To update after pulling a new release:

```sh
./nuvio pull
./nuvio up
```

Pending database migrations are applied during `up` and recorded in the private
`nuvio_migrations` schema.

## Defaults And Boundaries

- Single-node Docker Compose is the only supported topology initially.
- PostgreSQL 17 and all service images are pinned in `compose.yml`.
- Storage uses the server filesystem by default.
- Email accounts are auto-confirmed until SMTP is configured in `.env`.
- Passkeys and phone authentication are disabled by default.
- New profiles receive the Nuvio Catalog and OpenSubtitles addon defaults. These
  are external services and are not hosted by this repository.
- Monitoring, Kubernetes, high availability, external S3, and managed migration
  tooling are outside the first release.

## Security

`./nuvio setup` generates unique secrets and writes them to the ignored `.env`
file with mode `0600`. Review [SECURITY.md](SECURITY.md) before exposing a server.

## License

Licensed under Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
