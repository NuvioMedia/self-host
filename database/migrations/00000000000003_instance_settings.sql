BEGIN;

CREATE SCHEMA IF NOT EXISTS nuvio_private;
REVOKE ALL ON SCHEMA nuvio_private FROM PUBLIC;

CREATE TABLE IF NOT EXISTS nuvio_private.instance_settings (
    key text PRIMARY KEY,
    value text NOT NULL,
    updated_at timestamp with time zone NOT NULL DEFAULT now()
);

REVOKE ALL ON TABLE nuvio_private.instance_settings FROM PUBLIC;

INSERT INTO nuvio_private.instance_settings (key, value)
VALUES ('default_catalog_url', 'https://catalog.nuvio.tv/manifest.json')
ON CONFLICT (key) DO NOTHING;

CREATE OR REPLACE FUNCTION public.nuvio_default_catalog_url()
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT COALESCE(
        (
            SELECT value
            FROM nuvio_private.instance_settings
            WHERE key = 'default_catalog_url'
        ),
        'https://catalog.nuvio.tv/manifest.json'
    );
$$;

REVOKE ALL ON FUNCTION public.nuvio_default_catalog_url() FROM PUBLIC;

CREATE OR REPLACE FUNCTION public.handle_new_profile_default_addons()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
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

CREATE OR REPLACE FUNCTION public.handle_new_user_default_addons()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    catalog_url text := public.nuvio_default_catalog_url();
BEGIN
    INSERT INTO public.addons (user_id, profile_id, url, name, enabled, sort_order)
    SELECT new.id, 1, catalog_url, 'Nuvio Catalog Addon', true, 0
    WHERE NOT EXISTS (
        SELECT 1
        FROM public.addons
        WHERE user_id = new.id
          AND profile_id = 1
          AND md5(url) = md5(catalog_url)
    );

    INSERT INTO public.addons (user_id, profile_id, url, name, enabled, sort_order)
    SELECT new.id, 1, 'https://opensubtitles-v3.strem.io', 'OpenSubtitles v3', true, 1
    WHERE NOT EXISTS (
        SELECT 1
        FROM public.addons
        WHERE user_id = new.id
          AND profile_id = 1
          AND md5(url) = md5('https://opensubtitles-v3.strem.io')
    );

    RETURN new;
END;
$$;

INSERT INTO nuvio_migrations.schema_migrations (version)
VALUES ('00000000000003')
ON CONFLICT (version) DO NOTHING;

COMMIT;
