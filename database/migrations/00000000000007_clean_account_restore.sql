BEGIN;

-- A replace-mode account restore must reproduce the backup exactly. Profile
-- inserts normally seed instance defaults, which can collide with backed-up
-- addon URLs and can also make an intentionally empty backup non-empty.
CREATE OR REPLACE FUNCTION public.handle_new_profile_default_addons()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
    catalog_url text := public.nuvio_default_catalog_url();
BEGIN
    IF current_setting('nuvio.skip_profile_defaults', true) = 'on' THEN
        RETURN new;
    END IF;

    IF new.uses_primary_addons = false THEN
        INSERT INTO public.addons (user_id, profile_id, url, name, enabled, sort_order)
        SELECT new.user_id, new.profile_index, catalog_url, 'Nuvio Catalog Addon', true, 0
        WHERE NOT EXISTS (
            SELECT 1
            FROM public.addons
            WHERE user_id = new.user_id
              AND profile_id = new.profile_index
              AND md5(url) = md5(catalog_url)
        );

        INSERT INTO public.addons (user_id, profile_id, url, name, enabled, sort_order)
        SELECT new.user_id, new.profile_index, 'https://opensubtitles-v3.strem.io', 'OpenSubtitles v3', true, 1
        WHERE NOT EXISTS (
            SELECT 1
            FROM public.addons
            WHERE user_id = new.user_id
              AND profile_id = new.profile_index
              AND md5(url) = md5('https://opensubtitles-v3.strem.io')
        );
    END IF;

    RETURN new;
END;
$$;

-- Function-level settings are scoped to each invocation and restored on exit,
-- so concurrent profile creation retains the normal default-seeding behavior.
ALTER FUNCTION public.sync_restore_account_backup(jsonb, text)
    SET nuvio.skip_profile_defaults = 'on';

INSERT INTO nuvio_migrations.schema_migrations (version)
VALUES ('00000000000007')
ON CONFLICT (version) DO NOTHING;

COMMIT;
