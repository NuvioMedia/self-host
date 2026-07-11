BEGIN;

DO $$
BEGIN
    IF to_regclass('storage.objects') IS NULL OR to_regclass('storage.buckets') IS NULL THEN
        RAISE EXCEPTION 'Supabase Storage tables are not ready';
    END IF;
END
$$;

DROP POLICY IF EXISTS "Public avatar read access" ON storage.objects;
CREATE POLICY "Public avatar read access"
ON storage.objects
FOR SELECT
TO PUBLIC
USING (bucket_id = 'avatars');

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES
    ('avatars', 'avatars', true, 5242880, ARRAY['image/png', 'image/jpeg', 'image/webp']),
    ('covers', 'covers', true, 5242880, NULL)
ON CONFLICT (id) DO NOTHING;

INSERT INTO nuvio_migrations.schema_migrations (version)
VALUES ('00000000000002')
ON CONFLICT (version) DO NOTHING;

COMMIT;
