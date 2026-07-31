BEGIN;

-- SECURITY DEFINER functions must resolve trusted schemas before any session
-- schema. Supabase's bootstrap grants are also explicit, so revoke API access
-- first and then grant only the RPC surface used by clients.
DO $$
DECLARE
    routine record;
BEGIN
    FOR routine IN
        SELECT
            format(
                '%I.%I(%s)',
                n.nspname,
                p.proname,
                pg_get_function_identity_arguments(p.oid)
            ) AS signature
        FROM pg_proc AS p
        JOIN pg_namespace AS n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.prosecdef
    LOOP
        EXECUTE 'ALTER FUNCTION ' || routine.signature ||
            ' SET search_path = pg_catalog, public, auth, extensions, pg_temp';
    END LOOP;
END;
$$;

REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC, anon, authenticated;

DO $$
DECLARE
    routine record;
BEGIN
    FOR routine IN
        SELECT
            format(
                '%I.%I(%s)',
                n.nspname,
                p.proname,
                pg_get_function_identity_arguments(p.oid)
            ) AS signature
        FROM pg_proc AS p
        JOIN pg_namespace AS n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = ANY (ARRAY[
              'approve_tv_login_session',
              'can_access_user_data',
              'clear_profile_pin',
              'clear_profile_pin_with_account_password',
              'clear_tracker_tokens',
              'get_avatar_catalog',
              'get_profile_tracker_settings',
              'get_sync_overview',
              'get_sync_owner',
              'get_tracker_tokens',
              'health_ping',
              'list_my_sessions',
              'poll_tracker_tv_login_session',
              'poll_tv_login_session',
              'record_activity_event',
              'register_current_device',
              'register_current_session',
              'revoke_my_session',
              'set_profile_pin',
              'start_tracker_tv_login_session',
              'start_tv_login_session',
              'sync_delete_library_items',
              'sync_delete_profile_data',
              'sync_delete_provider_credentials',
              'sync_delete_watch_progress',
              'sync_delete_watched_items',
              'sync_export_account_backup',
              'sync_get_library_delta_cursor',
              'sync_get_watch_progress_delta_cursor',
              'sync_get_watched_items_delta_cursor',
              'sync_pull_collections',
              'sync_pull_home_catalog_settings',
              'sync_pull_library',
              'sync_pull_library_delta',
              'sync_pull_profile_locks',
              'sync_pull_profile_settings_blob',
              'sync_pull_profiles',
              'sync_pull_provider_credentials',
              'sync_pull_watch_progress',
              'sync_pull_watch_progress_delta',
              'sync_pull_watched_items',
              'sync_pull_watched_items_delta',
              'sync_push_addons',
              'sync_push_collections',
              'sync_push_home_catalog_settings',
              'sync_push_library',
              'sync_push_library_items',
              'sync_push_plugins',
              'sync_push_profile_settings_blob',
              'sync_push_profiles',
              'sync_push_provider_credentials',
              'sync_push_watch_progress',
              'sync_push_watched_items',
              'sync_restore_account_backup',
              'upsert_profile_tracker_settings',
              'upsert_tracker_tokens',
              'verify_profile_pin'
          ])
    LOOP
        EXECUTE 'GRANT EXECUTE ON FUNCTION ' || routine.signature || ' TO authenticated';
    END LOOP;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_avatar_catalog() TO anon;
GRANT EXECUTE ON FUNCTION public.health_ping() TO anon;
GRANT EXECUTE ON FUNCTION public.poll_tv_login_session(text, text) TO anon;
GRANT EXECUTE ON FUNCTION public.start_tv_login_session(text, text, text) TO anon;

INSERT INTO nuvio_migrations.schema_migrations (version)
VALUES ('00000000000004')
ON CONFLICT (version) DO NOTHING;

COMMIT;
