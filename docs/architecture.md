# How Your Deployment Works

Nuvio Self-Hosted runs as one Docker Compose deployment. This page explains
which services hold your data and which ports your server uses.

```text
Nuvio client
    |
    +-- Caddy (HTTPS deployment)
            |
            +-- Kong API gateway
                    +-- Auth
                    +-- PostgREST --------> PostgreSQL
                    +-- Storage ----------> PostgreSQL + local files
                    +-- Edge Runtime -----> Nuvio Edge Functions
                    +-- Realtime ---------> PostgreSQL (optional)
                    +-- Studio -----------> postgres-meta (optional)

./nuvio commands
    +-- migrations ------------> PostgreSQL
    +-- backup and restore ----> PostgreSQL + local files
```

## Request Flow

Your apps reach account sign-in, synchronization, file storage, and supporting
functions through one backend URL. If you enable Realtime or Studio, they use
the same deployment. On a public server, Caddy manages HTTPS and forwards
requests to the API gateway. For local use, the backend listens on
`http://localhost:8000` by default.

## Database

PostgreSQL stores your accounts, profiles, add-ons, plugins, library items,
watch progress, settings, tracker connections, login sessions, and sync state.
Database access rules keep each account's data separate.

`./nuvio up` applies required database updates automatically. You can also run
`./nuvio migrate` after updating the installation. Applied updates are tracked
so they are not run twice.

## Storage

Information about stored files is kept in PostgreSQL, while the files
themselves are kept under `volumes/storage/`. Nuvio creates `avatars` and
`covers` storage areas automatically. `./nuvio up` and `./nuvio migrate` add
any missing built-in avatars without replacing your uploaded files.

## Edge Functions

Supporting functions provide health checks, account deletion, TV sign-in, and
tracker sign-in. Operations that need administrative access first verify the
signed-in account or a one-time sign-in code.

## Network Ports

| Port | Use |
| --- | --- |
| `80` and `443` | Caddy HTTP validation and HTTPS traffic |
| `8000` | Local Kong API and optional Studio |
| `5432` | Local PostgreSQL session pooling |
| `6543` | Local PostgreSQL transaction pooling |

The database ports bind to `127.0.0.1`, so they are available only on your
server. For an HTTPS installation, expose ports `80` and `443` to the internet
and keep the other ports private.
