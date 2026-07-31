# Architecture

Nuvio Self-Hosted runs as one Docker Compose deployment.

```text
Nuvio client
    |
    +-- Caddy (HTTPS deployment)
            |
            +-- Kong API gateway
                    +-- Auth
                    +-- PostgREST --------> PostgreSQL
                    +-- Realtime ---------> PostgreSQL
                    +-- Storage ----------> PostgreSQL + local files
                    +-- Edge Runtime -----> Nuvio Edge Functions
                    +-- Studio -----------> postgres-meta

Nuvio CLI
    +-- migrations ------------> PostgreSQL
    +-- backup and restore ----> PostgreSQL + local files
```

## Request Flow

Kong exposes Auth, REST, Realtime, Storage, Edge Functions, and Studio through
one backend URL. In an HTTPS deployment, Caddy terminates TLS and forwards
requests to Kong. In a local deployment, Kong listens on
`http://localhost:8000` by default.

## Database

PostgreSQL stores Nuvio accounts, profiles, addons, plugins, library items,
watch progress, settings, tracker connections, login sessions, and sync state.
Row Level Security and authenticated RPC functions isolate each account's data.

Database migrations live in `database/migrations/`. `./nuvio up` and
`./nuvio migrate` apply pending migrations in order and record them in
`nuvio_migrations.schema_migrations`.

## Storage

Storage metadata is kept in PostgreSQL. Files are stored under
`volumes/storage/` and served by the Storage API. The `avatars` and `covers`
buckets are created by the Nuvio storage migration. The public avatar catalog
metadata is seeded by a database migration, and the matching bundled files in
`assets/avatars/` are uploaded idempotently through the Storage API by
`./nuvio up` and `./nuvio migrate`. User-uploaded objects are not bundled.

## Edge Functions

Nuvio Edge Functions run in the Supabase Edge Runtime and provide health
checks, account deletion, TV login exchange, and tracker login exchange.
Functions that use the service-role key verify the caller or validate the
one-time exchange credentials before performing privileged operations.

## Network Ports

| Port | Use |
| --- | --- |
| `80` and `443` | Caddy HTTP validation and HTTPS traffic |
| `8000` | Local Kong API and Studio |
| `5432` | Local PostgreSQL session pooling |
| `6543` | Local PostgreSQL transaction pooling |

Published database and pooler ports bind to `127.0.0.1`.
