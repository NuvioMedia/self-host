-- Adapted from Supabase self-hosting configuration and modified for Nuvio.
\set pguser `echo "$POSTGRES_USER"`

create schema if not exists _realtime;
alter schema _realtime owner to :pguser;
