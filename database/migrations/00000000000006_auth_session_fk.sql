BEGIN;

DO $$
BEGIN
    -- auth.sessions is created by the Auth service after PostgreSQL's
    -- entrypoint migrations finish, so this cross-service constraint cannot
    -- be part of the baseline dump.
    IF to_regclass('public.user_session_devices') IS NOT NULL THEN
        IF to_regclass('auth.sessions') IS NULL THEN
            RAISE EXCEPTION 'Supabase Auth sessions table is not ready';
        END IF;

        IF NOT EXISTS (
            SELECT 1
            FROM pg_catalog.pg_constraint
            WHERE conrelid = 'public.user_session_devices'::regclass
              AND conname = 'user_session_devices_session_id_fkey'
        ) THEN
            ALTER TABLE public.user_session_devices
                ADD CONSTRAINT user_session_devices_session_id_fkey
                FOREIGN KEY (session_id)
                REFERENCES auth.sessions(id)
                ON DELETE CASCADE;
        END IF;
    END IF;

    IF to_regclass('public.watch_progress_events') IS NOT NULL THEN
        -- The production schema predates this ownership constraint. Remove
        -- any already-orphaned deltas before enforcing account deletion.
        DELETE FROM public.watch_progress_events AS event
        WHERE NOT EXISTS (
            SELECT 1
            FROM auth.users
            WHERE id = event.user_id
        );

        IF NOT EXISTS (
            SELECT 1
            FROM pg_catalog.pg_constraint
            WHERE conrelid = 'public.watch_progress_events'::regclass
              AND conname = 'watch_progress_events_user_id_fkey'
        ) THEN
            ALTER TABLE public.watch_progress_events
                ADD CONSTRAINT watch_progress_events_user_id_fkey
                FOREIGN KEY (user_id)
                REFERENCES auth.users(id)
                ON DELETE CASCADE;
        END IF;
    END IF;
END
$$;

CREATE OR REPLACE FUNCTION public.record_library_item_delta_event()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        -- A cascading account deletion must not create a child row that
        -- references the auth.users row currently being removed.
        IF NOT EXISTS (
            SELECT 1
            FROM auth.users
            WHERE id = OLD.user_id
        ) THEN
            RETURN OLD;
        END IF;

        INSERT INTO public.library_item_events (
            user_id,
            profile_id,
            operation,
            content_id,
            content_type,
            name,
            poster,
            poster_shape,
            background,
            description,
            release_info,
            imdb_rating,
            genres,
            addon_base_url,
            added_at
        ) VALUES (
            OLD.user_id,
            OLD.profile_id,
            'delete',
            OLD.content_id,
            OLD.content_type,
            COALESCE(OLD.name, ''),
            OLD.poster,
            COALESCE(OLD.poster_shape, 'POSTER'),
            OLD.background,
            OLD.description,
            OLD.release_info,
            OLD.imdb_rating,
            COALESCE(OLD.genres, '{}'::text[]),
            OLD.addon_base_url,
            COALESCE(OLD.added_at, 0)
        );
        RETURN OLD;
    END IF;

    INSERT INTO public.library_item_events (
        user_id,
        profile_id,
        operation,
        content_id,
        content_type,
        name,
        poster,
        poster_shape,
        background,
        description,
        release_info,
        imdb_rating,
        genres,
        addon_base_url,
        added_at
    ) VALUES (
        NEW.user_id,
        NEW.profile_id,
        'upsert',
        NEW.content_id,
        NEW.content_type,
        COALESCE(NEW.name, ''),
        NEW.poster,
        COALESCE(NEW.poster_shape, 'POSTER'),
        NEW.background,
        NEW.description,
        NEW.release_info,
        NEW.imdb_rating,
        COALESCE(NEW.genres, '{}'::text[]),
        NEW.addon_base_url,
        COALESCE(NEW.added_at, 0)
    );
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.record_watch_progress_delta_event()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        -- Avoid retaining a progress tombstone when the whole account is
        -- being removed through the auth.users cascade.
        IF NOT EXISTS (
            SELECT 1
            FROM auth.users
            WHERE id = OLD.user_id
        ) THEN
            RETURN OLD;
        END IF;

        INSERT INTO public.watch_progress_events (
            user_id,
            profile_id,
            operation,
            progress_key,
            content_id,
            content_type,
            video_id,
            season,
            episode,
            position,
            duration,
            last_watched
        ) VALUES (
            OLD.user_id,
            OLD.profile_id,
            'delete',
            OLD.progress_key,
            OLD.content_id,
            OLD.content_type,
            OLD.video_id,
            OLD.season,
            OLD.episode,
            OLD.position,
            OLD.duration,
            OLD.last_watched
        );
        RETURN OLD;
    END IF;

    INSERT INTO public.watch_progress_events (
        user_id,
        profile_id,
        operation,
        progress_key,
        content_id,
        content_type,
        video_id,
        season,
        episode,
        position,
        duration,
        last_watched
    ) VALUES (
        NEW.user_id,
        NEW.profile_id,
        'upsert',
        NEW.progress_key,
        NEW.content_id,
        NEW.content_type,
        NEW.video_id,
        NEW.season,
        NEW.episode,
        NEW.position,
        NEW.duration,
        NEW.last_watched
    );
    RETURN NEW;
END;
$$;

INSERT INTO nuvio_migrations.schema_migrations (version)
VALUES ('00000000000006')
ON CONFLICT (version) DO NOTHING;

COMMIT;
