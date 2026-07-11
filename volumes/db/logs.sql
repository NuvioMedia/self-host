-- Adapted from Supabase self-hosting configuration and modified for Nuvio.
\set pguser `echo "$POSTGRES_USER"`

\c _supabase
create schema if not exists _analytics;
alter schema _analytics owner to :pguser;
\c postgres
