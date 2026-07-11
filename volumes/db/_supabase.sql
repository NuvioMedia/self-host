-- Adapted from Supabase self-hosting configuration and modified for Nuvio.
\set pguser `echo "$POSTGRES_USER"`

CREATE DATABASE _supabase WITH OWNER :pguser;
