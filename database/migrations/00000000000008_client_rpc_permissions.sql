BEGIN;

-- These client RPCs were added to the refreshed baseline after the explicit
-- authenticated-function allowlist. Migration 00000000000004 consequently
-- revoked their baseline grants without restoring them.
REVOKE ALL ON FUNCTION public.list_my_sessions() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.register_current_device(text, text, text, text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.register_current_session(text, text, text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.revoke_my_session(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.sync_delete_library_items(jsonb, integer, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.sync_get_library_delta_cursor(integer) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.sync_pull_library_delta(integer, bigint, integer) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.sync_push_library_items(jsonb, integer, text) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.list_my_sessions() TO authenticated;
GRANT EXECUTE ON FUNCTION public.register_current_device(text, text, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.register_current_session(text, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.revoke_my_session(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.sync_delete_library_items(jsonb, integer, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.sync_get_library_delta_cursor(integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.sync_pull_library_delta(integer, bigint, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.sync_push_library_items(jsonb, integer, text) TO authenticated;

INSERT INTO nuvio_migrations.schema_migrations (version)
VALUES ('00000000000008')
ON CONFLICT (version) DO NOTHING;

COMMIT;
