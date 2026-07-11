# Architecture

The default deployment is a single Docker Compose project.

```text
Nuvio client
    |
    +-- Caddy (server mode only, HTTPS)
            |
            +-- Kong API gateway
                    +-- Auth
                    +-- PostgREST -> PostgreSQL
                    +-- Realtime -> PostgreSQL
                    +-- Storage -> PostgreSQL + local files
                    +-- Edge Runtime -> Nuvio Edge Functions
                    +-- Studio -> postgres-meta
```

The database image initializes Supabase's internal schemas first, then applies
the Nuvio baseline and integration migrations from `database/migrations`.
Subsequent migrations can also be applied with `./nuvio migrate`.

Application data is protected by PostgreSQL Row Level Security. Edge Functions
that use the service-role key authenticate or validate their caller in function
code because the self-hosted Edge Runtime exposes one global JWT verification
setting.
