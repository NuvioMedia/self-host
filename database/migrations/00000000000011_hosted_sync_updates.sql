BEGIN;

-- Client sync changes that shipped on the hosted backend after
-- 00000000000010. Hosted-only features (memberships, profile backgrounds,
-- supporter tooling) stay out of self-hosted Nuvio.

-------------------------------------------------------------------------------
-- Profile pushes must never delete profiles.
--
-- A profile payload can be empty or incomplete after a failed pull, a stale
-- client cache, or a retry from another device. The previous implementation
-- deleted every profile missing from the payload, and the profile cleanup
-- trigger then removed all of that profile's data. Treat the payload as a set
-- of upserts. Deleting a profile goes through sync_delete_profile_data.
-------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.sync_push_profiles(
    p_profiles jsonb,
    p_client_max_profiles integer
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $function$
declare
    v_user_id uuid := get_sync_owner();
begin
    if p_client_max_profiles < 1 or p_client_max_profiles > 6 then
        raise exception 'Invalid client max profiles';
    end if;

    with incoming as (
        select
            row_number() over () as payload_order,
            (e->>'profile_index')::integer as profile_index,
            coalesce((e->>'name')::text, '') as name,
            coalesce((e->>'avatar_color_hex')::text, '#1E88E5') as avatar_color_hex,
            case when (e->>'profile_index')::integer = 1 then false
                 else coalesce((e->>'uses_primary_addons')::boolean, false)
            end as uses_primary_addons,
            case when (e->>'profile_index')::integer = 1 then false
                 else coalesce((e->>'uses_primary_plugins')::boolean, false)
            end as uses_primary_plugins,
            nullif(trim(coalesce(e->>'avatar_id', '')), '') as avatar_id,
            e ? 'avatar_url' as avatar_url_provided,
            nullif(trim(coalesce(e->>'avatar_url', '')), '') as avatar_url
        from jsonb_array_elements(coalesce(p_profiles, '[]'::jsonb)) as e
    ),
    validated as (
        select distinct on (profile_index) *
        from incoming
        where profile_index between 1 and 6
        order by profile_index, payload_order desc
    )
    insert into public.profiles (
        user_id,
        profile_index,
        profile_id,
        name,
        avatar_color_hex,
        uses_primary_addons,
        uses_primary_plugins,
        avatar_id,
        avatar_url,
        pin_enabled,
        pin_hash,
        pin_updated_at,
        failed_pin_attempts,
        pin_locked_until
    )
    select
        v_user_id,
        v.profile_index,
        v.profile_index,
        v.name,
        v.avatar_color_hex,
        v.uses_primary_addons,
        v.uses_primary_plugins,
        case when v.avatar_url is not null then null else v.avatar_id end,
        v.avatar_url,
        false,
        null,
        null,
        0,
        null
    from validated v
    on conflict (user_id, profile_index)
    do update set
        profile_id = excluded.profile_id,
        name = excluded.name,
        avatar_color_hex = excluded.avatar_color_hex,
        uses_primary_addons = excluded.uses_primary_addons,
        uses_primary_plugins = excluded.uses_primary_plugins,
        avatar_url = case
            when excluded.avatar_url is not null then excluded.avatar_url
            when exists (
                select 1
                from validated v
                where v.profile_index = excluded.profile_index
                  and v.avatar_url_provided
            ) then null
            else profiles.avatar_url
        end,
        avatar_id = case
            when excluded.avatar_url is not null then null
            when exists (
                select 1
                from validated v
                where v.profile_index = excluded.profile_index
                  and v.avatar_url_provided
            ) then excluded.avatar_id
            else coalesce(excluded.avatar_id, profiles.avatar_id)
        end,
        updated_at = now();
end;
$function$;

COMMENT ON FUNCTION public.sync_push_profiles(jsonb, integer) IS
    'Upserts supplied profiles without deleting omitted profiles. Use sync_delete_profile_data(integer) for explicit deletion.';

-------------------------------------------------------------------------------
-- Report settings conflicts as HTTP 409.
--
-- SQLSTATE 40001 (serialization_failure) makes PostgREST retry the whole
-- transaction, so a stale dashboard save retried forever and held pool
-- connections. PT409 returns the same message as HTTP 409 and is not retried.
-------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.sync_push_profile_settings_blob_guarded(
    p_profile_id integer,
    p_settings_json jsonb,
    p_platform text,
    p_expected_updated_at timestamptz
)
RETURNS timestamptz
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
    v_user_id uuid := public.get_sync_owner();
    v_current_updated_at timestamptz;
    v_saved_updated_at timestamptz;
BEGIN
    IF p_profile_id < 1 OR p_profile_id > 6 THEN
        RAISE EXCEPTION 'Invalid profile id' USING ERRCODE = '22023';
    END IF;

    SELECT settings.updated_at
    INTO v_current_updated_at
    FROM public.profile_settings_blobs AS settings
    WHERE settings.user_id = v_user_id
      AND settings.profile_id = p_profile_id
      AND settings.platform = p_platform
    FOR UPDATE;

    IF FOUND THEN
        IF p_expected_updated_at IS NULL
           OR v_current_updated_at IS DISTINCT FROM p_expected_updated_at THEN
            RAISE EXCEPTION 'Settings changed on another device. Reload and try again.'
                USING ERRCODE = 'PT409';
        END IF;
    ELSIF p_expected_updated_at IS NOT NULL THEN
        RAISE EXCEPTION 'Settings changed on another device. Reload and try again.'
            USING ERRCODE = 'PT409';
    END IF;

    PERFORM public.sync_push_profile_settings_blob(
        p_profile_id,
        p_settings_json,
        p_platform
    );

    SELECT settings.updated_at
    INTO v_saved_updated_at
    FROM public.profile_settings_blobs AS settings
    WHERE settings.user_id = v_user_id
      AND settings.profile_id = p_profile_id
      AND settings.platform = p_platform;

    RETURN v_saved_updated_at;
END;
$$;

-------------------------------------------------------------------------------
-- Ignore stale watch-progress pushes.
--
-- A client with an old cache must not move progress backwards, resurrect
-- progress that another device removed, or reopen an item that was marked
-- watched after the pushed position was recorded.
-------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.sync_push_watch_progress(p_entries jsonb, p_profile_id integer DEFAULT 1)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $function$
declare
  v_uid uuid := (select auth.uid());
  v_owner uuid;
  v_headers jsonb := coalesce(nullif(current_setting('request.headers', true), '')::jsonb, '{}'::jsonb);
  v_min_position_delta_ms constant bigint := 15000;
  v_min_progress_update_interval_ms constant bigint := 30000;
  v_min_watched_update_interval_ms constant bigint := 60000;
  v_incoming_count integer := 0;
  v_normalized_count integer := 0;
  v_inserted_progress_count integer := 0;
  v_updated_progress_count integer := 0;
  v_inserted_watched_count integer := 0;
  v_updated_watched_count integer := 0;
  v_inserted_watched_event_count integer := 0;
  v_payload_hash text;
begin
  set local statement_timeout = '30s';

  v_owner := public.get_sync_owner();

  with normalized as (
    select
      incoming.content_id,
      incoming.content_type,
      incoming.video_id,
      incoming.season,
      incoming.episode,
      incoming.position,
      incoming.duration,
      incoming.last_watched,
      coalesce(
        nullif(incoming.payload_progress_key, ''),
        case
          when incoming.season is not null and incoming.episode is not null
            then incoming.content_id || '_s' || incoming.season || 'e' || incoming.episode
          else incoming.content_id
        end
      ) as progress_key
    from (
      select
        (e->>'content_id')::text as content_id,
        coalesce((e->>'content_type')::text, '') as content_type,
        coalesce((e->>'video_id')::text, '') as video_id,
        nullif(e->>'season', '')::integer as season,
        nullif(e->>'episode', '')::integer as episode,
        coalesce(nullif(e->>'position', '')::bigint, 0) as position,
        coalesce(nullif(e->>'duration', '')::bigint, 0) as duration,
        coalesce(nullif(e->>'last_watched', '')::bigint, 0) as last_watched,
        nullif((e->>'progress_key')::text, '') as payload_progress_key
      from jsonb_array_elements(coalesce(p_entries, '[]'::jsonb)) as e
      where coalesce((e->>'content_id')::text, '') <> ''
    ) incoming
  ), dedup as (
    select distinct on (progress_key)
      content_id,
      content_type,
      video_id,
      season,
      episode,
      position,
      duration,
      last_watched,
      progress_key
    from normalized
    where coalesce(progress_key, '') <> ''
    order by progress_key, last_watched desc
  ), dedup_count as (
    select count(*)::integer as count from dedup
  ), eligible as (
    select d.*
    from dedup d
    cross join lateral (
      select case
        when d.content_id in ('tmdb', 'kitsu')
          and d.content_type = 'movie'
          and d.video_id ~ '^\d+$'
          then d.content_id || ':' || d.video_id
        else d.content_id
      end as content_id
    ) identity
    cross join lateral (
      select case
        when d.season is not null and d.episode is not null
          then identity.content_id || '_s' || d.season || 'e' || d.episode
        else identity.content_id
      end as progress_key
    ) canonical
    left join public.watch_progress current_progress
      on current_progress.user_id = v_owner
      and current_progress.profile_id = p_profile_id
      and current_progress.progress_key = canonical.progress_key
    where (
      current_progress.progress_key is null
      or d.last_watched >= current_progress.last_watched
    )
      and (
        (d.duration > 0 and d.position >= d.duration * 0.9)
        or not exists (
          select 1
          from public.watched_items watched
          where watched.user_id = v_owner
            and watched.profile_id = p_profile_id
            and watched.content_id = identity.content_id
            and coalesce(watched.season, -1) = coalesce(d.season, -1)
            and coalesce(watched.episode, -1) = coalesce(d.episode, -1)
            and watched.watched_at >= d.last_watched
        )
      )
      and case
        when current_progress.progress_key is not null then true
        else not exists (
          select 1
          from public.watch_progress_events event
          where event.user_id = v_owner
            and event.profile_id = p_profile_id
            and event.progress_key = canonical.progress_key
            and event.operation = 'delete'
            and event.created_at >= to_timestamp(d.last_watched / 1000.0)
        )
      end
  ), inserted_progress as (
    insert into public.watch_progress (
      user_id,
      content_id,
      content_type,
      video_id,
      season,
      episode,
      position,
      duration,
      last_watched,
      progress_key,
      profile_id
    )
    select
      v_owner,
      d.content_id,
      d.content_type,
      d.video_id,
      d.season,
      d.episode,
      d.position,
      d.duration,
      d.last_watched,
      d.progress_key,
      p_profile_id
    from eligible d
    on conflict (user_id, profile_id, progress_key) do nothing
    returning 1
  ), updated_progress as (
    update public.watch_progress wp
    set
      content_id = d.content_id,
      content_type = d.content_type,
      video_id = d.video_id,
      season = d.season,
      episode = d.episode,
      position = d.position,
      duration = d.duration,
      last_watched = d.last_watched
    from eligible d
    where wp.user_id = v_owner
      and wp.profile_id = p_profile_id
      and wp.progress_key = d.progress_key
      and d.last_watched >= wp.last_watched
      and (
        wp.content_id is distinct from d.content_id
        or wp.content_type is distinct from d.content_type
        or wp.video_id is distinct from d.video_id
        or wp.season is distinct from d.season
        or wp.episode is distinct from d.episode
        or wp.duration is distinct from d.duration
        or (
          (
            wp.position is distinct from d.position
            or wp.last_watched is distinct from d.last_watched
          )
          and (
            abs(wp.position - d.position) >= v_min_position_delta_ms
            or d.last_watched >= wp.last_watched + v_min_progress_update_interval_ms
            or (
              d.duration >= 60000
              and d.position >= (d.duration * 0.9)
              and not (
                wp.duration >= 60000
                and wp.position >= (wp.duration * 0.9)
              )
            )
          )
        )
      )
    returning 1
  ), completed as (
    select distinct on (content_id, coalesce(season, -1), coalesce(episode, -1))
      content_id,
      case
        when coalesce(nullif(content_type, ''), '') <> '' then content_type
        when season is not null and episode is not null then 'series'
        else 'movie'
      end as content_type,
      season,
      episode,
      case
        when last_watched between 946684800000
          and (extract(epoch from (now() + interval '1 day')) * 1000)::bigint
          then last_watched
        else (extract(epoch from now()) * 1000)::bigint
      end as watched_at
    from eligible
    where duration >= 60000
      and position >= (duration * 0.9)
    order by content_id, coalesce(season, -1), coalesce(episode, -1), last_watched desc
  ), inserted_watched as (
    insert into public.watched_items (
      user_id,
      content_id,
      content_type,
      title,
      season,
      episode,
      watched_at,
      profile_id
    )
    select
      v_owner,
      c.content_id,
      c.content_type,
      '',
      c.season,
      c.episode,
      c.watched_at,
      p_profile_id
    from completed c
    on conflict (user_id, content_id, coalesce(season, -1), coalesce(episode, -1), profile_id) do nothing
    returning
      user_id,
      profile_id,
      content_id,
      content_type,
      title,
      season,
      episode,
      watched_at
  ), updated_watched as (
    update public.watched_items wi
    set
      content_type = c.content_type,
      watched_at = greatest(wi.watched_at, c.watched_at)
    from completed c
    where wi.user_id = v_owner
      and wi.profile_id = p_profile_id
      and wi.content_id = c.content_id
      and coalesce(wi.season, -1) = coalesce(c.season, -1)
      and coalesce(wi.episode, -1) = coalesce(c.episode, -1)
      and (
        wi.content_type is distinct from c.content_type
        or c.watched_at >= wi.watched_at + v_min_watched_update_interval_ms
      )
    returning
      wi.user_id,
      wi.profile_id,
      wi.content_id,
      wi.content_type,
      wi.title,
      wi.season,
      wi.episode,
      wi.watched_at
  ), watched_changes as (
    select * from inserted_watched
    union all
    select * from updated_watched
  ), inserted_watched_events as (
    insert into public.watched_item_events (
      user_id,
      profile_id,
      operation,
      content_id,
      content_type,
      title,
      season,
      episode,
      watched_at
    )
    select
      w.user_id,
      w.profile_id,
      'upsert',
      w.content_id,
      w.content_type,
      w.title,
      w.season,
      w.episode,
      w.watched_at
    from watched_changes w
    returning 1
  )
  select
    (select count from dedup_count),
    (select count(*)::integer from inserted_progress),
    (select count(*)::integer from updated_progress),
    (select count(*)::integer from inserted_watched),
    (select count(*)::integer from updated_watched),
    (select count(*)::integer from inserted_watched_events)
  into
    v_normalized_count,
    v_inserted_progress_count,
    v_updated_progress_count,
    v_inserted_watched_count,
    v_updated_watched_count,
    v_inserted_watched_event_count;
end;
$function$;

-------------------------------------------------------------------------------
-- Sync library title logos.
-------------------------------------------------------------------------------
ALTER TABLE public.library_items ADD COLUMN IF NOT EXISTS logo text;
ALTER TABLE public.library_item_events ADD COLUMN IF NOT EXISTS logo text;

CREATE OR REPLACE FUNCTION public.record_library_item_delta_event()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $function$
begin
    if tg_op = 'DELETE' then
        if not exists (
            select 1
            from auth.users
            where id = old.user_id
        ) then
            return old;
        end if;

        insert into public.library_item_events (
            user_id,
            profile_id,
            operation,
            content_id,
            content_type,
            name,
            poster,
            poster_shape,
            background,
            logo,
            description,
            release_info,
            imdb_rating,
            genres,
            addon_base_url,
            added_at
        ) values (
            old.user_id,
            old.profile_id,
            'delete',
            old.content_id,
            old.content_type,
            coalesce(old.name, ''),
            old.poster,
            coalesce(old.poster_shape, 'POSTER'),
            old.background,
            old.logo,
            old.description,
            old.release_info,
            old.imdb_rating,
            coalesce(old.genres, '{}'::text[]),
            old.addon_base_url,
            coalesce(old.added_at, 0)
        );
        return old;
    end if;

    insert into public.library_item_events (
        user_id,
        profile_id,
        operation,
        content_id,
        content_type,
        name,
        poster,
        poster_shape,
        background,
        logo,
        description,
        release_info,
        imdb_rating,
        genres,
        addon_base_url,
        added_at
    ) values (
        new.user_id,
        new.profile_id,
        'upsert',
        new.content_id,
        new.content_type,
        coalesce(new.name, ''),
        new.poster,
        coalesce(new.poster_shape, 'POSTER'),
        new.background,
        new.logo,
        new.description,
        new.release_info,
        new.imdb_rating,
        coalesce(new.genres, '{}'::text[]),
        new.addon_base_url,
        coalesce(new.added_at, 0)
    );
    return new;
end;
$function$;

CREATE OR REPLACE FUNCTION public.sync_push_library(p_items jsonb, p_profile_id integer DEFAULT 1)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $function$
DECLARE v_user_id uuid := get_sync_owner();
BEGIN
    INSERT INTO library_items (
        user_id, content_id, content_type, name, poster, poster_shape,
        background, logo, description, release_info, imdb_rating, genres,
        addon_base_url, added_at, profile_id
    )
    SELECT
        v_user_id,
        (e->>'content_id')::text,
        (e->>'content_type')::text,
        COALESCE((e->>'name')::text, ''),
        (e->>'poster')::text,
        COALESCE((e->>'poster_shape')::text, 'POSTER'),
        (e->>'background')::text,
        NULLIF(BTRIM(e->>'logo'), ''),
        (e->>'description')::text,
        (e->>'release_info')::text,
        (e->>'imdb_rating')::real,
        COALESCE(ARRAY(SELECT jsonb_array_elements_text(e->'genres')), '{}'::text[]),
        (e->>'addon_base_url')::text,
        COALESCE((e->>'added_at')::bigint, 0),
        p_profile_id
    FROM jsonb_array_elements(p_items) AS e
    ON CONFLICT ON CONSTRAINT library_items_user_id_content_id_content_type_profile_id_key
    DO UPDATE SET
        name           = EXCLUDED.name,
        poster         = EXCLUDED.poster,
        poster_shape   = EXCLUDED.poster_shape,
        background     = EXCLUDED.background,
        logo           = COALESCE(EXCLUDED.logo, library_items.logo),
        description    = EXCLUDED.description,
        release_info   = EXCLUDED.release_info,
        imdb_rating    = EXCLUDED.imdb_rating,
        genres         = EXCLUDED.genres,
        addon_base_url = EXCLUDED.addon_base_url,
        added_at       = EXCLUDED.added_at
    WHERE library_items.name IS DISTINCT FROM EXCLUDED.name
       OR library_items.poster IS DISTINCT FROM EXCLUDED.poster
       OR library_items.poster_shape IS DISTINCT FROM EXCLUDED.poster_shape
       OR library_items.background IS DISTINCT FROM EXCLUDED.background
       OR library_items.logo IS DISTINCT FROM COALESCE(EXCLUDED.logo, library_items.logo)
       OR library_items.description IS DISTINCT FROM EXCLUDED.description
       OR library_items.release_info IS DISTINCT FROM EXCLUDED.release_info
       OR library_items.imdb_rating IS DISTINCT FROM EXCLUDED.imdb_rating
       OR library_items.genres IS DISTINCT FROM EXCLUDED.genres
       OR library_items.addon_base_url IS DISTINCT FROM EXCLUDED.addon_base_url
       OR library_items.added_at IS DISTINCT FROM EXCLUDED.added_at;

    DELETE FROM library_items li
    WHERE li.user_id    = v_user_id
      AND li.profile_id = p_profile_id
      AND NOT EXISTS (
          SELECT 1 FROM jsonb_array_elements(p_items) AS e
          WHERE (e->>'content_id')::text   = li.content_id
            AND (e->>'content_type')::text = li.content_type
      );
END;
$function$;

CREATE OR REPLACE FUNCTION public.sync_push_library_items(p_items jsonb, p_profile_id integer DEFAULT 1, p_origin_client_id text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $function$
declare
    v_user_id uuid := public.get_sync_owner();
begin
    if p_profile_id is null or p_profile_id < 1 or p_profile_id > 6 then
        raise exception 'Invalid profile id';
    end if;

    perform public.sync_set_origin_client_id(p_origin_client_id);

    with normalized as (
        select
            e.ordinality,
            (e.item->>'content_id')::text as content_id,
            (e.item->>'content_type')::text as content_type,
            coalesce((e.item->>'name')::text, '') as name,
            (e.item->>'poster')::text as poster,
            coalesce((e.item->>'poster_shape')::text, 'POSTER') as poster_shape,
            (e.item->>'background')::text as background,
            nullif(btrim(e.item->>'logo'), '') as logo,
            (e.item->>'description')::text as description,
            (e.item->>'release_info')::text as release_info,
            nullif(e.item->>'imdb_rating', '')::real as imdb_rating,
            case
                when jsonb_typeof(e.item->'genres') = 'array'
                    then array(select jsonb_array_elements_text(e.item->'genres'))
                else '{}'::text[]
            end as genres,
            (e.item->>'addon_base_url')::text as addon_base_url,
            coalesce(nullif(e.item->>'added_at', '')::bigint, 0) as added_at
        from jsonb_array_elements(coalesce(p_items, '[]'::jsonb))
            with ordinality as e(item, ordinality)
        where btrim(coalesce(e.item->>'content_id', '')) <> ''
          and btrim(coalesce(e.item->>'content_type', '')) <> ''
    ), deduplicated as (
        select distinct on (content_id, content_type)
            content_id,
            content_type,
            name,
            poster,
            poster_shape,
            background,
            logo,
            description,
            release_info,
            imdb_rating,
            genres,
            addon_base_url,
            added_at
        from normalized
        order by content_id, content_type, ordinality desc
    )
    insert into public.library_items (
        user_id,
        profile_id,
        content_id,
        content_type,
        name,
        poster,
        poster_shape,
        background,
        logo,
        description,
        release_info,
        imdb_rating,
        genres,
        addon_base_url,
        added_at
    )
    select
        v_user_id,
        p_profile_id,
        d.content_id,
        d.content_type,
        d.name,
        d.poster,
        d.poster_shape,
        d.background,
        d.logo,
        d.description,
        d.release_info,
        d.imdb_rating,
        d.genres,
        d.addon_base_url,
        d.added_at
    from deduplicated d
    on conflict on constraint library_items_user_id_content_id_content_type_profile_id_key
    do update set
        name = excluded.name,
        poster = excluded.poster,
        poster_shape = excluded.poster_shape,
        background = excluded.background,
        logo = coalesce(excluded.logo, library_items.logo),
        description = excluded.description,
        release_info = excluded.release_info,
        imdb_rating = excluded.imdb_rating,
        genres = excluded.genres,
        addon_base_url = excluded.addon_base_url,
        added_at = excluded.added_at,
        updated_at = now()
    where library_items.name is distinct from excluded.name
       or library_items.poster is distinct from excluded.poster
       or library_items.poster_shape is distinct from excluded.poster_shape
       or library_items.background is distinct from excluded.background
       or library_items.logo is distinct from coalesce(excluded.logo, library_items.logo)
       or library_items.description is distinct from excluded.description
       or library_items.release_info is distinct from excluded.release_info
       or library_items.imdb_rating is distinct from excluded.imdb_rating
       or library_items.genres is distinct from excluded.genres
       or library_items.addon_base_url is distinct from excluded.addon_base_url
       or library_items.added_at is distinct from excluded.added_at;
end;
$function$;

-- The delta result gains a column, which CREATE OR REPLACE cannot change.
DROP FUNCTION IF EXISTS public.sync_pull_library_delta(integer, bigint, integer);

CREATE FUNCTION public.sync_pull_library_delta(
    p_profile_id integer DEFAULT 1,
    p_since_event_id bigint DEFAULT 0,
    p_limit integer DEFAULT 1000
)
RETURNS TABLE (
    event_id bigint,
    operation text,
    content_id text,
    content_type text,
    name text,
    poster text,
    poster_shape text,
    background text,
    description text,
    release_info text,
    imdb_rating real,
    genres text[],
    addon_base_url text,
    added_at bigint,
    logo text
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $function$
    select
        e.event_id,
        e.operation,
        e.content_id,
        e.content_type,
        e.name,
        e.poster,
        e.poster_shape,
        e.background,
        e.description,
        e.release_info,
        e.imdb_rating,
        e.genres,
        e.addon_base_url,
        e.added_at,
        e.logo
    from public.library_item_events e
    where e.user_id = public.get_sync_owner()
      and e.profile_id = p_profile_id
      and e.event_id > greatest(coalesce(p_since_event_id, 0), 0)
    order by e.event_id asc
    limit least(greatest(coalesce(p_limit, 1000), 1), 1000);
$function$;

REVOKE ALL ON FUNCTION public.sync_pull_library_delta(integer, bigint, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.sync_pull_library_delta(integer, bigint, integer) TO authenticated, service_role;

-------------------------------------------------------------------------------
-- Store TV subtitle colors in the integer format the TV app reads.
--
-- Other clients may write #RRGGBB or #AARRGGBB strings into TV settings.
-------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.normalize_tv_subtitle_colors(p_settings jsonb)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE STRICT
SET search_path = ''
AS $function$
DECLARE
    v_settings jsonb := p_settings;
    v_key text;
    v_entry jsonb;
    v_text text;
    v_color bigint;
BEGIN
    IF jsonb_typeof(p_settings #> '{features,player_settings}') IS DISTINCT FROM 'object' THEN
        RETURN p_settings;
    END IF;
    FOREACH v_key IN ARRAY ARRAY['subtitle_text_color', 'subtitle_background_color', 'subtitle_outline_color']
    LOOP
        v_entry := p_settings #> ARRAY['features', 'player_settings', v_key];
        IF v_entry->>'type' IS NULL THEN
            CONTINUE;
        END IF;
        IF v_entry->>'type' NOT IN ('int', 'string') THEN
            RAISE EXCEPTION 'Invalid TV subtitle color type for %', v_key USING ERRCODE = '22023';
        END IF;
        v_text := btrim(v_entry->>'value');
        IF v_text ~ '^#[0-9A-Fa-f]{8}$' THEN
            v_color := ('x' || substr(v_text, 2))::bit(32)::bigint;
        ELSIF v_text ~ '^#[0-9A-Fa-f]{6}$' THEN
            v_color := ('xFF' || substr(v_text, 2))::bit(32)::bigint;
        ELSIF v_text ~ '^-?[0-9]{1,10}$' THEN
            v_color := v_text::bigint;
        ELSE
            RAISE EXCEPTION 'Invalid TV subtitle color value for %', v_key USING ERRCODE = '22023';
        END IF;
        IF v_color < -2147483648 OR v_color > 4294967295 THEN
            RAISE EXCEPTION 'TV subtitle color out of range for %', v_key USING ERRCODE = '22023';
        END IF;
        IF v_color > 2147483647 THEN
            v_color := v_color - 4294967296;
        END IF;
        v_settings := jsonb_set(
            v_settings,
            ARRAY['features', 'player_settings', v_key],
            v_entry || jsonb_build_object('type', 'int', 'value', v_color::integer),
            false
        );
    END LOOP;
    RETURN v_settings;
END;
$function$;

CREATE OR REPLACE FUNCTION public.normalize_tv_profile_settings_colors()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $function$
BEGIN
    NEW.settings_json := public.normalize_tv_subtitle_colors(NEW.settings_json);
    RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION public.normalize_tv_subtitle_colors(jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.normalize_tv_profile_settings_colors() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS normalize_tv_subtitle_colors ON public.profile_settings_blobs;
CREATE TRIGGER normalize_tv_subtitle_colors
BEFORE INSERT OR UPDATE OF settings_json, platform ON public.profile_settings_blobs
FOR EACH ROW
WHEN (NEW.platform = 'tv')
EXECUTE FUNCTION public.normalize_tv_profile_settings_colors();

-------------------------------------------------------------------------------
-- Sync Jellyfin and Emby servers per profile.
-------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.media_servers (
    user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    profile_id integer NOT NULL,
    servers_json jsonb NOT NULL DEFAULT '[]'::jsonb,
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT media_servers_pkey PRIMARY KEY (user_id, profile_id),
    CONSTRAINT media_servers_profile_id_range CHECK (profile_id BETWEEN 1 AND 6),
    CONSTRAINT media_servers_servers_json_array CHECK (jsonb_typeof(servers_json) = 'array')
);

ALTER TABLE public.media_servers ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can manage own media servers" ON public.media_servers;
CREATE POLICY "Users can manage own media servers"
ON public.media_servers
TO authenticated
USING ((SELECT auth.uid()) = user_id)
WITH CHECK ((SELECT auth.uid()) = user_id);

-- Server entries include access tokens. Clients use the RPCs below.
REVOKE ALL ON TABLE public.media_servers FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.sync_normalize_media_server(p_server jsonb)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
SET search_path = ''
AS $function$
declare
    v_field text;
    v_limit integer;
    v_value text;
    v_result jsonb := '{}'::jsonb;
    v_libraries jsonb := '[]'::jsonb;
    v_library jsonb;
    v_library_id text;
    v_library_ids text[] := array[]::text[];
begin
    if p_server is null or jsonb_typeof(p_server) <> 'object' then
        raise exception 'Invalid media server entry'
            using errcode = '22023';
    end if;

    for v_field, v_limit in
        select field, max_length
        from (values
            ('id', 64),
            ('provider_id', 32),
            ('name', 256),
            ('address', 2048),
            ('remote_server_id', 256),
            ('remote_user_id', 256),
            ('user_name', 256),
            ('token', 1024)
        ) as fields(field, max_length)
    loop
        if jsonb_typeof(p_server -> v_field) is distinct from 'string' then
            raise exception 'Invalid media server field: %', v_field
                using errcode = '22023';
        end if;
        v_value := btrim(p_server ->> v_field);
        if length(v_value) > v_limit or (v_value = '' and v_field <> 'name') then
            raise exception 'Invalid media server field: %', v_field
                using errcode = '22023';
        end if;
        v_result := v_result || jsonb_build_object(v_field, v_value);
    end loop;

    if v_result ->> 'provider_id' not in ('jellyfin', 'emby') then
        raise exception 'Unsupported media server provider: %', v_result ->> 'provider_id'
            using errcode = '22023';
    end if;

    if jsonb_typeof(p_server -> 'enabled') is distinct from 'boolean'
        or jsonb_typeof(p_server -> 'use_catalog_metadata') is distinct from 'boolean'
        or jsonb_typeof(p_server -> 'libraries') is distinct from 'array'
    then
        raise exception 'Invalid media server settings'
            using errcode = '22023';
    end if;

    if jsonb_array_length(p_server -> 'libraries') > 500 then
        raise exception 'Too many media server libraries'
            using errcode = '22023';
    end if;

    for v_library in
        select value
        from jsonb_array_elements(p_server -> 'libraries')
    loop
        if jsonb_typeof(v_library) <> 'object'
            or jsonb_typeof(v_library -> 'id') is distinct from 'string'
            or jsonb_typeof(v_library -> 'name') is distinct from 'string'
            or jsonb_typeof(v_library -> 'kind') is distinct from 'string'
            or jsonb_typeof(v_library -> 'selected') is distinct from 'boolean'
            or v_library ->> 'kind' not in ('movie', 'series', 'collection', 'mixed')
        then
            raise exception 'Invalid media server library'
                using errcode = '22023';
        end if;

        v_library_id := btrim(v_library ->> 'id');
        if v_library_id = ''
            or length(v_library_id) > 256
            or length(v_library ->> 'name') > 256
            or v_library_id = any(v_library_ids)
        then
            raise exception 'Invalid media server library'
                using errcode = '22023';
        end if;
        v_library_ids := array_append(v_library_ids, v_library_id);

        v_libraries := v_libraries || jsonb_build_array(jsonb_build_object(
            'id', v_library_id,
            'name', btrim(v_library ->> 'name'),
            'kind', v_library ->> 'kind',
            'selected', v_library -> 'selected'
        ));
    end loop;

    return v_result || jsonb_build_object(
        'libraries', v_libraries,
        'enabled', p_server -> 'enabled',
        'use_catalog_metadata', p_server -> 'use_catalog_metadata'
    ) || case
        when jsonb_typeof(p_server -> 'import_watch_state') = 'boolean'
            then jsonb_build_object('import_watch_state', p_server -> 'import_watch_state')
        else '{}'::jsonb
    end;
end;
$function$;

CREATE OR REPLACE FUNCTION public.sync_push_media_servers(
    p_profile_id integer,
    p_servers jsonb,
    p_origin_client_id text
)
RETURNS timestamptz
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $function$
declare
    v_user_id uuid := public.get_sync_owner();
    v_item jsonb;
    v_key text;
    v_keys text[] := array[]::text[];
    v_servers jsonb := '[]'::jsonb;
    v_updated_at timestamptz;
begin
    if p_profile_id < 1 or p_profile_id > 6 then
        raise exception 'Invalid profile id'
            using errcode = '22023';
    end if;

    if p_servers is null or jsonb_typeof(p_servers) <> 'array' then
        raise exception 'Media servers must be an array'
            using errcode = '22023';
    end if;

    if jsonb_array_length(p_servers) > 16 then
        raise exception 'Too many media servers'
            using errcode = '22023';
    end if;

    perform public.sync_set_origin_client_id(p_origin_client_id);

    for v_item in
        select value
        from jsonb_array_elements(p_servers)
    loop
        v_item := public.sync_normalize_media_server(v_item);
        v_key := (v_item ->> 'provider_id') || '|' || (v_item ->> 'remote_server_id') || '|' || (v_item ->> 'remote_user_id');
        if v_key = any(v_keys) then
            raise exception 'Duplicate media server'
                using errcode = '22023';
        end if;
        v_keys := array_append(v_keys, v_key);
        v_servers := v_servers || jsonb_build_array(v_item);
    end loop;

    insert into public.media_servers (user_id, profile_id, servers_json, updated_at)
    values (v_user_id, p_profile_id, v_servers, now())
    on conflict (user_id, profile_id)
    do update set
        servers_json = excluded.servers_json,
        updated_at = now()
    where public.media_servers.servers_json is distinct from excluded.servers_json
    returning public.media_servers.updated_at into v_updated_at;

    if v_updated_at is null then
        select ms.updated_at into v_updated_at
        from public.media_servers ms
        where ms.user_id = v_user_id
          and ms.profile_id = p_profile_id;
    end if;

    return v_updated_at;
end;
$function$;

CREATE OR REPLACE FUNCTION public.sync_pull_media_servers(p_profile_id integer)
RETURNS TABLE (servers_json jsonb, updated_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $function$
declare
    v_user_id uuid := public.get_sync_owner();
begin
    if p_profile_id < 1 or p_profile_id > 6 then
        raise exception 'Invalid profile id'
            using errcode = '22023';
    end if;

    return query
    select ms.servers_json, ms.updated_at
    from public.media_servers ms
    where ms.user_id = v_user_id
      and ms.profile_id = p_profile_id;
end;
$function$;

REVOKE ALL ON FUNCTION public.sync_normalize_media_server(jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.sync_push_media_servers(integer, jsonb, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.sync_pull_media_servers(integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.sync_push_media_servers(integer, jsonb, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.sync_pull_media_servers(integer) TO authenticated, service_role;

-- Remove a deleted profile's media servers together with its other data.
CREATE OR REPLACE FUNCTION public.delete_profile_scoped_data(
    p_user_id uuid,
    p_profile_id integer
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $function$
begin
    if p_user_id is null or p_profile_id is null then
        return;
    end if;

    -- Delete source rows before their delta-event rows. Source-row triggers may
    -- emit tombstones, which are removed by the event-table deletes below.
    delete from public.addons
    where user_id = p_user_id and profile_id = p_profile_id;

    delete from public.plugins
    where user_id = p_user_id and profile_id = p_profile_id;

    delete from public.collections
    where user_id = p_user_id and profile_id = p_profile_id;

    delete from public.home_catalog_settings
    where user_id = p_user_id and profile_id = p_profile_id;

    delete from public.media_servers
    where user_id = p_user_id and profile_id = p_profile_id;

    delete from public.profile_settings_blobs
    where user_id = p_user_id and profile_id = p_profile_id;

    delete from public.profile_tracker_settings
    where user_id = p_user_id and profile_id = p_profile_id;

    delete from public.provider_credentials
    where user_id = p_user_id and profile_id = p_profile_id;

    delete from public.user_tracker_tokens
    where user_id = p_user_id and profile_id = p_profile_id;

    delete from public.watch_progress
    where user_id = p_user_id and profile_id = p_profile_id;

    delete from public.library_items
    where user_id = p_user_id and profile_id = p_profile_id;

    delete from public.watched_items
    where user_id = p_user_id and profile_id = p_profile_id;

    delete from public.library_item_events
    where user_id = p_user_id and profile_id = p_profile_id;

    delete from public.watch_progress_events
    where user_id = p_user_id and profile_id = p_profile_id;

    delete from public.watched_item_events
    where user_id = p_user_id and profile_id = p_profile_id;

    delete from public.sync_push_audit_logs
    where user_id = p_user_id and profile_id = p_profile_id;

    delete from public.user_activity_events
    where user_id = p_user_id and profile_id = p_profile_id;
end;
$function$;

-------------------------------------------------------------------------------
-- Device linking with short user codes.
--
-- A device shows a six-character code and polls with poll_tv_login_session as
-- before. A signed-in account looks up and approves the code.
-------------------------------------------------------------------------------
ALTER TABLE public.tv_login_sessions
    ADD COLUMN IF NOT EXISTS user_code text,
    ADD COLUMN IF NOT EXISTS device_type text;

CREATE UNIQUE INDEX IF NOT EXISTS idx_tv_login_sessions_pending_user_code
    ON public.tv_login_sessions (user_code)
    WHERE status = 'pending' AND user_code IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.device_login_code_attempts (
    id bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    attempted_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_device_login_code_attempts_user_time
    ON public.device_login_code_attempts (user_id, attempted_at DESC);

ALTER TABLE public.device_login_code_attempts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.device_login_code_attempts FROM PUBLIC, anon, authenticated;
REVOKE ALL ON SEQUENCE public.device_login_code_attempts_id_seq FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.normalize_device_login_user_code(p_code text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = public
AS $$
    SELECT regexp_replace(upper(coalesce(p_code, '')), '[^A-Z0-9]', '', 'g');
$$;

CREATE OR REPLACE FUNCTION public.random_device_login_user_code()
RETURNS text
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
    v_alphabet CONSTANT TEXT := '23456789ABCDEFGHJKMNPQRSTUVWXYZ';
    v_bytes BYTEA := extensions.gen_random_bytes(6);
    v_code TEXT := '';
    v_index INTEGER;
BEGIN
    FOR v_index IN 0..5 LOOP
        v_code := v_code || substr(
            v_alphabet,
            (get_byte(v_bytes, v_index) % length(v_alphabet)) + 1,
            1
        );
    END LOOP;

    RETURN v_code;
END;
$$;

CREATE OR REPLACE FUNCTION public.assert_device_login_code_attempt_allowed(p_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
BEGIN
    PERFORM pg_advisory_xact_lock(hashtextextended(p_user_id::TEXT, 14873));

    DELETE FROM public.device_login_code_attempts
    WHERE user_id = p_user_id
      AND attempted_at < NOW() - INTERVAL '1 day';

    IF (
        SELECT count(*)
        FROM public.device_login_code_attempts
        WHERE user_id = p_user_id
          AND attempted_at >= NOW() - INTERVAL '5 minutes'
    ) >= 5 THEN
        RAISE EXCEPTION 'Too many device code attempts. Try again in five minutes.';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.start_device_login_session(
    p_device_nonce text,
    p_redirect_base_url text,
    p_device_name text DEFAULT NULL,
    p_device_type text DEFAULT 'device'
)
RETURNS TABLE (
    device_code text,
    user_code text,
    verification_uri text,
    verification_uri_complete text,
    expires_at timestamptz,
    poll_interval_seconds integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
    v_device_code TEXT;
    v_user_code TEXT;
    v_redirect_base_url TEXT;
    v_device_name TEXT;
    v_device_type TEXT;
    v_expires_at TIMESTAMPTZ;
    v_created BOOLEAN := false;
    v_attempt INTEGER;
BEGIN
    IF p_device_nonce IS NULL OR length(trim(p_device_nonce)) < 12 THEN
        RAISE EXCEPTION 'Invalid device nonce';
    END IF;

    v_redirect_base_url := rtrim(trim(coalesce(p_redirect_base_url, '')), '/');
    IF (
        v_redirect_base_url = ''
        OR (
            left(lower(v_redirect_base_url), 8) <> 'https://'
            AND left(lower(v_redirect_base_url), 7) <> 'http://'
        )
        OR position('/link' IN lower(v_redirect_base_url)) = 0
        OR position('?' IN v_redirect_base_url) > 0
        OR position('#' IN v_redirect_base_url) > 0
    ) THEN
        RAISE EXCEPTION 'Invalid device login redirect base URL';
    END IF;

    v_device_name := left(nullif(trim(p_device_name), ''), 120);
    v_device_type := left(coalesce(nullif(lower(trim(p_device_type)), ''), 'device'), 32);

    PERFORM public.expire_old_tv_login_sessions();

    IF (
        SELECT count(*)
        FROM public.tv_login_sessions
        WHERE created_at >= NOW() - INTERVAL '1 minute'
    ) > 200 THEN
        RAISE EXCEPTION 'Rate limit exceeded';
    END IF;

    v_expires_at := NOW() + INTERVAL '5 minutes';

    FOR v_attempt IN 1..10 LOOP
        v_device_code := public.random_tv_login_code();
        v_user_code := public.random_device_login_user_code();

        BEGIN
            INSERT INTO public.tv_login_sessions (
                code,
                user_code,
                device_nonce,
                device_name,
                device_type,
                status,
                expires_at,
                poll_interval_seconds
            )
            VALUES (
                v_device_code,
                v_user_code,
                trim(p_device_nonce),
                v_device_name,
                v_device_type,
                'pending',
                v_expires_at,
                3
            );

            v_created := true;
        EXCEPTION
            WHEN unique_violation THEN
                v_created := false;
        END;

        EXIT WHEN v_created;
    END LOOP;

    IF NOT v_created THEN
        RAISE EXCEPTION 'Unable to create a unique device login code';
    END IF;

    RETURN QUERY
    SELECT
        v_device_code,
        v_user_code,
        v_redirect_base_url,
        v_redirect_base_url || '?code=' || v_user_code,
        v_expires_at,
        3;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_device_login_session(p_user_code text)
RETURNS TABLE (
    success boolean,
    message text,
    user_code text,
    device_name text,
    device_type text,
    expires_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
    v_user_id UUID;
    v_user_code TEXT;
    v_device_name TEXT;
    v_device_type TEXT;
    v_expires_at TIMESTAMPTZ;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Not authenticated';
    END IF;

    PERFORM public.assert_device_login_code_attempt_allowed(v_user_id);
    PERFORM public.expire_old_tv_login_sessions();

    v_user_code := public.normalize_device_login_user_code(p_user_code);

    SELECT s.device_name, s.device_type, s.expires_at
    INTO v_device_name, v_device_type, v_expires_at
    FROM public.tv_login_sessions s
    WHERE s.user_code = v_user_code
      AND s.status = 'pending'
      AND s.expires_at > NOW()
    ORDER BY s.created_at DESC
    LIMIT 1;

    IF NOT FOUND THEN
        INSERT INTO public.device_login_code_attempts (user_id)
        VALUES (v_user_id);

        RETURN QUERY
        SELECT false, 'Invalid or expired device code'::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT, NULL::TIMESTAMPTZ;
        RETURN;
    END IF;

    RETURN QUERY
    SELECT true, 'Device is ready to link'::TEXT, v_user_code, v_device_name, v_device_type, v_expires_at;
END;
$$;

CREATE OR REPLACE FUNCTION public.approve_device_login_session(p_user_code text)
RETURNS TABLE (
    success boolean,
    message text,
    device_name text,
    device_type text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
    v_user_id UUID;
    v_user_code TEXT;
    v_device_name TEXT;
    v_device_type TEXT;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Not authenticated';
    END IF;

    PERFORM public.assert_device_login_code_attempt_allowed(v_user_id);
    PERFORM public.expire_old_tv_login_sessions();

    v_user_code := public.normalize_device_login_user_code(p_user_code);

    UPDATE public.tv_login_sessions s
    SET
        status = 'approved',
        approved_user_id = v_user_id,
        approved_at = NOW()
    WHERE s.user_code = v_user_code
      AND s.status = 'pending'
      AND s.expires_at > NOW()
    RETURNING s.device_name, s.device_type
    INTO v_device_name, v_device_type;

    IF NOT FOUND THEN
        INSERT INTO public.device_login_code_attempts (user_id)
        VALUES (v_user_id);

        RETURN QUERY
        SELECT false, 'Invalid or expired device code'::TEXT, NULL::TEXT, NULL::TEXT;
        RETURN;
    END IF;

    DELETE FROM public.device_login_code_attempts
    WHERE user_id = v_user_id;

    RETURN QUERY
    SELECT true, 'Device login approved'::TEXT, v_device_name, v_device_type;
END;
$$;

REVOKE ALL ON FUNCTION public.normalize_device_login_user_code(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.random_device_login_user_code() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.assert_device_login_code_attempt_allowed(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.start_device_login_session(text, text, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.get_device_login_session(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.approve_device_login_session(text) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.start_device_login_session(text, text, text, text) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_device_login_session(text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.approve_device_login_session(text) TO authenticated, service_role;

-- Existing PostgREST containers should expose the new RPCs immediately after
-- an upgrade, without requiring operators to restart the stack.
NOTIFY pgrst, 'reload schema';

INSERT INTO nuvio_migrations.schema_migrations (version)
VALUES ('00000000000011')
ON CONFLICT (version) DO NOTHING;

COMMIT;
