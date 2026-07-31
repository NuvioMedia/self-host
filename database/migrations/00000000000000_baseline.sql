--
-- PostgreSQL database dump
--

BEGIN;

CREATE SCHEMA IF NOT EXISTS nuvio_migrations;
REVOKE ALL ON SCHEMA nuvio_migrations FROM PUBLIC;

CREATE TABLE IF NOT EXISTS nuvio_migrations.schema_migrations (
    version text PRIMARY KEY,
    applied_at timestamp with time zone NOT NULL DEFAULT now()
);

REVOKE ALL ON TABLE nuvio_migrations.schema_migrations FROM PUBLIC;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_catalog.pg_roles
        WHERE rolname = 'supabase_monitor'
    ) THEN
        CREATE ROLE supabase_monitor NOLOGIN;
    END IF;
END;
$$;


-- Dumped from database version 17.6
-- Dumped by pg_dump version 17.6

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: public; Type: SCHEMA; Schema: -; Owner: -
--

--
-- Name: approve_tv_login_session(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.approve_tv_login_session(p_code text) RETURNS TABLE(success boolean, message text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
    v_user_id UUID;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Not authenticated';
    END IF;

    PERFORM expire_old_tv_login_sessions();

    UPDATE tv_login_sessions
    SET
        status = 'approved',
        approved_user_id = v_user_id,
        approved_at = NOW()
    WHERE code = p_code
      AND status = 'pending'
      AND expires_at > NOW();

    IF NOT FOUND THEN
        RETURN QUERY SELECT false, 'Invalid or expired TV login code';
        RETURN;
    END IF;

    RETURN QUERY SELECT true, 'TV login approved';
END;
$$;


--
-- Name: can_access_user_data(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.can_access_user_data(p_user_id uuid) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select coalesce(auth.uid() = p_user_id, false);
$$;


--
-- Name: cleanup_anonymous_users(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.cleanup_anonymous_users() RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'auth'
    AS $$
DECLARE
  batch_user_ids uuid[];
  deleted_count integer := 0;
BEGIN
  IF NOT pg_try_advisory_lock(hashtext('cleanup_anonymous_users')) THEN
    RETURN 0;
  END IF;

  LOOP
    SELECT array_agg(id) INTO batch_user_ids
    FROM (
      SELECT id FROM auth.users
      WHERE is_anonymous = true
        AND email IS NULL
        AND created_at < NOW() - INTERVAL '30 minutes'
      LIMIT 500
    ) sub;

    EXIT WHEN batch_user_ids IS NULL OR array_length(batch_user_ids, 1) = 0;

    DELETE FROM auth.sessions WHERE user_id = ANY(batch_user_ids);
    DELETE FROM auth.users WHERE id = ANY(batch_user_ids);

    deleted_count := deleted_count + array_length(batch_user_ids, 1);

    EXIT WHEN deleted_count >= 5000;
  END LOOP;

  PERFORM pg_advisory_unlock(hashtext('cleanup_anonymous_users'));
  RETURN deleted_count;
END;
$$;


--
-- Name: clear_profile_pin(integer, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.clear_profile_pin(p_profile_id integer, p_current_pin text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $_$
declare
    v_user_id uuid := get_sync_owner();
    v_updated_rows integer;
    v_pin_enabled boolean;
    v_pin_hash text;
begin
    if p_profile_id < 1 or p_profile_id > 6 then
        raise exception 'Invalid profile id';
    end if;

    select pin_enabled, pin_hash
    into v_pin_enabled, v_pin_hash
    from public.profiles
    where user_id = v_user_id
      and profile_index = p_profile_id;

    if not found then
        raise exception 'Profile not found for current user';
    end if;

    if v_pin_enabled is true and v_pin_hash is not null then
        if p_current_pin is null
           or p_current_pin !~ '^[0-9]{4}$'
           or extensions.crypt(p_current_pin, v_pin_hash) <> v_pin_hash then
            raise exception 'Current PIN is required to remove PIN';
        end if;
    end if;

    update public.profiles
    set
        pin_enabled = false,
        pin_hash = null,
        pin_updated_at = now(),
        failed_pin_attempts = 0,
        pin_locked_until = null,
        updated_at = now()
    where user_id = v_user_id
      and profile_index = p_profile_id;

    get diagnostics v_updated_rows = row_count;
    if v_updated_rows = 0 then
        raise exception 'Profile not found for current user';
    end if;
end;
$_$;


--
-- Name: clear_profile_pin_with_account_password(text, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.clear_profile_pin_with_account_password(p_account_password text, p_profile_id integer) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
    v_user_id uuid := get_sync_owner();
    v_encrypted_password text;
    v_updated_rows integer;
begin
    if v_user_id is null then
        raise exception 'Not authenticated';
    end if;

    if p_profile_id < 1 or p_profile_id > 6 then
        raise exception 'Invalid profile id';
    end if;

    if p_account_password is null or btrim(p_account_password) = '' then
        raise exception 'Account password is required';
    end if;

    select encrypted_password
    into v_encrypted_password
    from auth.users
    where id = v_user_id;

    if v_encrypted_password is null then
        raise exception 'Account password verification is unavailable for this account';
    end if;

    if extensions.crypt(p_account_password, v_encrypted_password) <> v_encrypted_password then
        raise exception 'Invalid account password';
    end if;

    update public.profiles
    set
        pin_enabled = false,
        pin_hash = null,
        pin_updated_at = now(),
        failed_pin_attempts = 0,
        pin_locked_until = null,
        updated_at = now()
    where user_id = v_user_id
      and profile_index = p_profile_id;

    get diagnostics v_updated_rows = row_count;
    if v_updated_rows = 0 then
        raise exception 'Profile not found for current user';
    end if;
end;
$$;


--
-- Name: clear_tracker_tokens(integer, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.clear_tracker_tokens(p_profile_id integer, p_tracker text) RETURNS void
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
    DELETE FROM public.user_tracker_tokens
    WHERE user_id = public.get_sync_owner()
      AND profile_id = p_profile_id
      AND tracker = p_tracker;
$$;


--
-- Name: consume_tv_login_session(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.consume_tv_login_session(p_code text, p_device_nonce text) RETURNS TABLE(approved_user_id uuid)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
    v_user_id UUID;
BEGIN
    PERFORM expire_old_tv_login_sessions();

    SELECT s.approved_user_id
    INTO v_user_id
    FROM tv_login_sessions s
    WHERE s.code = p_code
      AND s.device_nonce = p_device_nonce
      AND s.status = 'approved'
      AND s.expires_at > NOW()
    FOR UPDATE;

    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'TV login not approved or expired';
    END IF;

    UPDATE tv_login_sessions
    SET
        status = 'exchanged',
        exchanged_at = NOW()
    WHERE code = p_code
      AND device_nonce = p_device_nonce;

    RETURN QUERY SELECT v_user_id;
END;
$$;


--
-- Name: emit_sync_invalidation(uuid, integer, text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.emit_sync_invalidation(p_user_id uuid, p_profile_id integer, p_surface text, p_metadata jsonb DEFAULT '{}'::jsonb) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
    if p_user_id is null then
        return;
    end if;

    insert into public.sync_invalidations (user_id, profile_id, surface, metadata)
    values (
        p_user_id,
        p_profile_id,
        p_surface,
        coalesce(p_metadata, '{}'::jsonb)
    );
end;
$$;


--
-- Name: expire_old_tv_login_sessions(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.expire_old_tv_login_sessions() RETURNS void
    LANGUAGE sql
    AS $$
UPDATE tv_login_sessions
SET status = 'expired'
WHERE status = 'pending'
  AND expires_at <= NOW();
$$;


--
-- Name: fix_watch_progress_key(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fix_watch_progress_key() RETURNS trigger
    LANGUAGE plpgsql
    AS $_$
BEGIN
  -- Reject bare prefix content_ids (tmdb, kitsu without numeric part)
  IF NEW.content_id IN ('tmdb', 'kitsu') THEN
    -- For movies, try to recover from video_id
    IF NEW.content_type = 'movie' AND NEW.video_id ~ '^\d+$' THEN
      NEW.content_id := NEW.content_id || ':' || NEW.video_id;
      NEW.video_id := NEW.content_id;
    ELSE
      -- Cannot fix: skip the insert/update by returning NULL
      RETURN NULL;
    END IF;
  END IF;

  -- Fix progress_key corruption patterns
  IF NEW.season IS NOT NULL AND NEW.episode IS NOT NULL THEN
    -- Series episode: ensure progress_key = content_id_sXeY
    IF NEW.progress_key != (NEW.content_id || '_s' || NEW.season || 'e' || NEW.episode) THEN
      NEW.progress_key := NEW.content_id || '_s' || NEW.season || 'e' || NEW.episode;
    END IF;
  ELSE
    -- Movie / series-level: ensure progress_key = content_id
    IF NEW.progress_key != NEW.content_id THEN
      NEW.progress_key := NEW.content_id;
    END IF;
  END IF;

  RETURN NEW;
END;
$_$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: avatar_catalog; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.avatar_catalog (
    id text NOT NULL,
    display_name text NOT NULL,
    storage_path text NOT NULL,
    category text DEFAULT 'character'::text,
    sort_order integer DEFAULT 0,
    is_active boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now(),
    bg_color text
);


--
-- Name: get_avatar_catalog(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_avatar_catalog() RETURNS SETOF public.avatar_catalog
    LANGUAGE sql STABLE SECURITY DEFINER
    AS $$
  SELECT * FROM avatar_catalog WHERE is_active = true ORDER BY category, sort_order;
$$;


--
-- Name: profile_tracker_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.profile_tracker_settings (
    user_id uuid NOT NULL,
    profile_id integer NOT NULL,
    tracker text NOT NULL,
    enabled_statuses text[] DEFAULT '{}'::text[] NOT NULL,
    row_order text[] DEFAULT '{}'::text[] NOT NULL,
    send_progress boolean DEFAULT true NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT profile_tracker_settings_tracker_check CHECK ((tracker = ANY (ARRAY['mal'::text, 'anilist'::text, 'kitsu'::text])))
);


--
-- Name: get_profile_tracker_settings(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_profile_tracker_settings(p_profile_id integer) RETURNS SETOF public.profile_tracker_settings
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
    SELECT *
    FROM public.profile_tracker_settings
    WHERE user_id = public.get_sync_owner()
      AND profile_id = p_profile_id;
$$;


--
-- Name: get_sync_overview(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_sync_overview() RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  DECLARE
    v_user_id uuid := get_sync_owner();
    v_result jsonb;
  BEGIN
    SELECT jsonb_build_object(
      'addons', COALESCE((
        SELECT jsonb_object_agg(profile_id::text, cnt)
        FROM (SELECT profile_id, count(*)::int as cnt FROM addons WHERE user_id = v_user_id GROUP BY profile_id) t
      ), '{}'::jsonb),
      'plugins', COALESCE((
        SELECT jsonb_object_agg(profile_id::text, cnt)
        FROM (SELECT profile_id, count(*)::int as cnt FROM plugins WHERE user_id = v_user_id GROUP BY profile_id) t
      ), '{}'::jsonb),
      'library_items', COALESCE((
        SELECT jsonb_object_agg(profile_id::text, cnt)
        FROM (SELECT profile_id, count(*)::int as cnt FROM library_items WHERE user_id = v_user_id GROUP BY profile_id) t
      ), '{}'::jsonb),
      'watch_progress', COALESCE((
        SELECT jsonb_object_agg(profile_id::text, cnt)
        FROM (SELECT profile_id, count(DISTINCT content_id)::int as cnt FROM watch_progress WHERE user_id = v_user_id GROUP BY profile_id)
  t
      ), '{}'::jsonb),
      'watched_items', COALESCE((
        SELECT jsonb_object_agg(profile_id::text, cnt)
        FROM (SELECT profile_id, count(DISTINCT content_id)::int as cnt FROM watched_items WHERE user_id = v_user_id GROUP BY profile_id) t
      ), '{}'::jsonb),
      'profiles', COALESCE((
        SELECT jsonb_object_agg(profile_index::text, jsonb_build_object('name', name, 'color', avatar_color_hex))
        FROM profiles WHERE user_id = v_user_id
      ), '{}'::jsonb)
    ) INTO v_result;
    RETURN v_result;
  END; $$;


--
-- Name: get_sync_owner(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_sync_owner() RETURNS uuid
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_uid uuid;
begin
  v_uid := auth.uid();

  if v_uid is null then
    raise exception using
      errcode = '28000',
      message = 'Unauthorized: valid session required for sync.';
  end if;

  return v_uid;
end;
$$;


--
-- Name: user_tracker_tokens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_tracker_tokens (
    user_id uuid NOT NULL,
    profile_id integer NOT NULL,
    tracker text NOT NULL,
    access_token text NOT NULL,
    refresh_token text,
    expires_at timestamp with time zone,
    tracker_user_id text,
    tracker_username text,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT user_tracker_tokens_tracker_check CHECK ((tracker = ANY (ARRAY['mal'::text, 'anilist'::text, 'kitsu'::text])))
);


--
-- Name: get_tracker_tokens(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_tracker_tokens(p_profile_id integer) RETURNS SETOF public.user_tracker_tokens
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
    SELECT *
    FROM public.user_tracker_tokens
    WHERE user_id = public.get_sync_owner()
      AND profile_id = p_profile_id;
$$;


--
-- Name: handle_new_profile_default_addons(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.handle_new_profile_default_addons() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
begin
  if new.uses_primary_addons = false then
    insert into public.addons (user_id, profile_id, url, name, enabled, sort_order)
    select new.user_id, new.profile_index, 'https://v3-cinemeta.strem.io/manifest.json', 'Cinemeta', true, 0
    where not exists (
      select 1
      from public.addons
      where user_id = new.user_id
        and profile_id = new.profile_index
        and md5(url) = md5('https://v3-cinemeta.strem.io/manifest.json')
    );

    insert into public.addons (user_id, profile_id, url, name, enabled, sort_order)
    select new.user_id, new.profile_index, 'https://opensubtitles-v3.strem.io', 'OpenSubtitles v3', true, 1
    where not exists (
      select 1
      from public.addons
      where user_id = new.user_id
        and profile_id = new.profile_index
        and md5(url) = md5('https://opensubtitles-v3.strem.io')
    );
  end if;

  return new;
end;
$$;


--
-- Name: handle_new_user_default_addons(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.handle_new_user_default_addons() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
begin
  insert into public.addons (user_id, profile_id, url, name, enabled, sort_order)
  select new.id, 1, 'https://v3-cinemeta.strem.io/manifest.json', 'Cinemeta', true, 0
  where not exists (
    select 1
    from public.addons
    where user_id = new.id
      and profile_id = 1
      and md5(url) = md5('https://v3-cinemeta.strem.io/manifest.json')
  );

  insert into public.addons (user_id, profile_id, url, name, enabled, sort_order)
  select new.id, 1, 'https://opensubtitles-v3.strem.io', 'OpenSubtitles v3', true, 1
  where not exists (
    select 1
    from public.addons
    where user_id = new.id
      and profile_id = 1
      and md5(url) = md5('https://opensubtitles-v3.strem.io')
  );

  return new;
end;
$$;


--
-- Name: health_ping(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.health_ping() RETURNS boolean
    LANGUAGE sql SECURITY DEFINER
    AS $$
  SELECT true;
$$;


--
-- Name: list_my_sessions(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.list_my_sessions() RETURNS TABLE(session_id uuid, created_at timestamp with time zone, last_active_at timestamp with time zone, client_name text, client_version text, platform text, device_name text, user_agent text, is_current boolean)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
    select
        sessions.id,
        sessions.created_at,
        greatest(
            devices.last_seen_at,
            sessions.refreshed_at at time zone 'UTC',
            sessions.updated_at,
            sessions.created_at
        ),
        devices.client_name,
        devices.client_version,
        devices.platform,
        devices.device_name,
        left(sessions.user_agent, 512),
        sessions.id = nullif(auth.jwt() ->> 'session_id', '')::uuid
    from public.user_session_devices as devices
    join auth.sessions as sessions
      on sessions.id = devices.session_id
     and sessions.user_id = devices.user_id
    where devices.user_id = auth.uid()
      and devices.client_name in (
          'Nuvio Web',
          'Nuvio Mobile',
          'Nuvio TV',
          'Nuvio Desktop'
      )
      and (sessions.not_after is null or sessions.not_after > now())
    order by
        sessions.id = nullif(auth.jwt() ->> 'session_id', '')::uuid desc,
        greatest(
            devices.last_seen_at,
            sessions.refreshed_at at time zone 'UTC',
            sessions.updated_at,
            sessions.created_at
        ) desc;
$$;


--
-- Name: poll_tracker_tv_login_session(text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.poll_tracker_tv_login_session(p_tracker text, p_code text, p_device_nonce text) RETURNS TABLE(status text, access_token text, refresh_token text, expires_in integer, user_id text, username text, poll_interval_seconds integer)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
    WITH picked AS (
        SELECT *
        FROM public.tracker_tv_login_sessions
        WHERE code = p_code
          AND tracker = p_tracker
          AND device_nonce = p_device_nonce
    ),
    classified AS (
        SELECT
            p.access_token,
            p.refresh_token,
            p.expires_in,
            p.tracker_user_id,
            p.tracker_username,
            CASE
                WHEN p.code IS NULL THEN 'expired'
                WHEN p.expires_at < now() THEN 'expired'
                WHEN p.status = 'ready' THEN 'ready'
                ELSE 'pending'
            END AS eff_status
        FROM (SELECT 1) AS base
        LEFT JOIN picked p ON TRUE
    ),
    deleted AS (
        DELETE FROM public.tracker_tv_login_sessions t
        WHERE t.code = p_code
          AND EXISTS (
              SELECT 1 FROM classified c WHERE c.eff_status IN ('expired','ready')
          )
        RETURNING t.code
    )
    SELECT
        c.eff_status::TEXT,
        CASE WHEN c.eff_status = 'ready' THEN c.access_token END::TEXT,
        CASE WHEN c.eff_status = 'ready' THEN c.refresh_token END::TEXT,
        CASE WHEN c.eff_status = 'ready' THEN c.expires_in END::INTEGER,
        CASE WHEN c.eff_status = 'ready' THEN c.tracker_user_id END::TEXT,
        CASE WHEN c.eff_status = 'ready' THEN c.tracker_username END::TEXT,
        3
    FROM classified c
    LEFT JOIN deleted d ON TRUE;
$$;


--
-- Name: poll_tv_login_session(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.poll_tv_login_session(p_code text, p_device_nonce text) RETURNS TABLE(status text, expires_at timestamp with time zone, poll_interval_seconds integer)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
    v_status TEXT;
    v_expires TIMESTAMPTZ;
    v_poll_interval INT;
    v_poll_count INT;
BEGIN
    PERFORM expire_old_tv_login_sessions();

    SELECT s.status, s.expires_at, s.poll_interval_seconds, s.poll_count
    INTO v_status, v_expires, v_poll_interval, v_poll_count
    FROM tv_login_sessions s
    WHERE s.code = p_code
      AND s.device_nonce = p_device_nonce
    FOR UPDATE;

    IF v_status IS NULL THEN
        RAISE EXCEPTION 'Invalid TV login session';
    END IF;

    IF v_status = 'expired' THEN
        RETURN QUERY SELECT 'expired'::text, v_expires, v_poll_interval;
        RETURN;
    END IF;

    IF v_poll_count >= 240 THEN
        UPDATE tv_login_sessions
        SET status = 'expired'
        WHERE code = p_code AND device_nonce = p_device_nonce;
        RETURN QUERY SELECT 'expired'::text, v_expires, v_poll_interval;
        RETURN;
    END IF;

    UPDATE tv_login_sessions
    SET poll_count = poll_count + 1
    WHERE code = p_code
      AND device_nonce = p_device_nonce;

    RETURN QUERY SELECT v_status, v_expires, v_poll_interval;
END;
$$;


--
-- Name: random_tv_login_code(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.random_tv_login_code() RETURNS text
    LANGUAGE sql
    AS $$
  select encode(extensions.gen_random_bytes(16), 'hex');
$$;


--
-- Name: record_activity_event(text, text, integer, text, text, text, text, text, text, text, integer, integer, text, text, uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.record_activity_event(p_event_type text, p_status text, p_profile_id integer DEFAULT NULL::integer, p_platform text DEFAULT 'unknown'::text, p_app_version text DEFAULT NULL::text, p_device_id text DEFAULT NULL::text, p_device_name text DEFAULT NULL::text, p_entity_type text DEFAULT NULL::text, p_entity_key text DEFAULT NULL::text, p_action text DEFAULT NULL::text, p_duration_ms integer DEFAULT NULL::integer, p_item_count integer DEFAULT NULL::integer, p_error_code text DEFAULT NULL::text, p_error_message text DEFAULT NULL::text, p_correlation_id uuid DEFAULT NULL::uuid, p_metadata jsonb DEFAULT '{}'::jsonb) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'auth'
    AS $$
declare
  v_actor_user_id uuid := auth.uid();
  v_user_id uuid;
  v_event_id uuid;
  v_metadata jsonb := coalesce(p_metadata, '{}'::jsonb);
  v_event_type text := nullif(left(btrim(coalesce(p_event_type, '')), 128), '');
  v_status text := nullif(btrim(coalesce(p_status, '')), '');
begin
  if v_actor_user_id is null then
    raise exception 'record_activity_event requires an authenticated session';
  end if;

  if v_event_type is null then
    raise exception 'event_type is required';
  end if;

  if v_status not in ('started', 'succeeded', 'failed', 'skipped') then
    raise exception 'status must be one of started, succeeded, failed, skipped';
  end if;

  if pg_column_size(v_metadata) > 32768 then
    v_metadata := jsonb_build_object(
      'truncated', true,
      'reason', 'metadata exceeded 32KB limit'
    );
  end if;

  v_user_id := public.get_sync_owner();

  insert into public.user_activity_events (
    user_id,
    actor_user_id,
    profile_id,
    platform,
    app_version,
    device_id,
    device_name,
    event_type,
    entity_type,
    entity_key,
    action,
    status,
    duration_ms,
    item_count,
    error_code,
    error_message,
    correlation_id,
    metadata
  ) values (
    v_user_id,
    v_actor_user_id,
    p_profile_id,
    coalesce(nullif(left(btrim(coalesce(p_platform, '')), 64), ''), 'unknown'),
    nullif(left(btrim(coalesce(p_app_version, '')), 64), ''),
    nullif(left(btrim(coalesce(p_device_id, '')), 128), ''),
    nullif(left(btrim(coalesce(p_device_name, '')), 128), ''),
    v_event_type,
    nullif(left(btrim(coalesce(p_entity_type, '')), 64), ''),
    nullif(left(btrim(coalesce(p_entity_key, '')), 512), ''),
    nullif(left(btrim(coalesce(p_action, '')), 64), ''),
    v_status,
    case when p_duration_ms is null then null else greatest(p_duration_ms, 0) end,
    case when p_item_count is null then null else greatest(p_item_count, 0) end,
    nullif(left(btrim(coalesce(p_error_code, '')), 128), ''),
    nullif(left(btrim(coalesce(p_error_message, '')), 1024), ''),
    p_correlation_id,
    v_metadata
  )
  returning id into v_event_id;

  return v_event_id;
end;
$$;


--
-- Name: record_library_item_delta_event(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.record_library_item_delta_event() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
    if tg_op = 'DELETE' then
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
        new.description,
        new.release_info,
        new.imdb_rating,
        coalesce(new.genres, '{}'::text[]),
        new.addon_base_url,
        coalesce(new.added_at, 0)
    );
    return new;
end;
$$;


--
-- Name: record_watch_progress_delta_event(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.record_watch_progress_delta_event() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  if tg_op = 'DELETE' then
    insert into public.watch_progress_events (
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
    ) values (
      old.user_id,
      old.profile_id,
      'delete',
      old.progress_key,
      old.content_id,
      old.content_type,
      old.video_id,
      old.season,
      old.episode,
      old.position,
      old.duration,
      old.last_watched
    );
    return old;
  end if;

  insert into public.watch_progress_events (
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
  ) values (
    new.user_id,
    new.profile_id,
    'upsert',
    new.progress_key,
    new.content_id,
    new.content_type,
    new.video_id,
    new.season,
    new.episode,
    new.position,
    new.duration,
    new.last_watched
  );
  return new;
end;
$$;


--
-- Name: register_current_device(text, text, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.register_current_device(p_installation_id text, p_client_name text, p_client_version text DEFAULT NULL::text, p_platform text DEFAULT NULL::text, p_device_name text DEFAULT NULL::text) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $_$
declare
    v_user_id uuid := auth.uid();
    v_session_id uuid := nullif(auth.jwt() ->> 'session_id', '')::uuid;
    v_installation_id text := nullif(btrim(p_installation_id), '');
    v_client_name text := nullif(btrim(p_client_name), '');
    v_previous_session_id uuid;
begin
    if v_user_id is null or v_session_id is null then
        raise exception using errcode = '42501', message = 'Authentication required';
    end if;

    if (
        v_installation_id is null
        or char_length(v_installation_id) not between 16 and 96
        or v_installation_id !~ '^[A-Za-z0-9_-]+$'
    ) then
        raise exception using errcode = '22023', message = 'Invalid installation identifier';
    end if;

    if v_client_name not in (
        'Nuvio Web',
        'Nuvio Mobile',
        'Nuvio TV',
        'Nuvio Desktop'
    ) then
        raise exception using errcode = '22023', message = 'Unsupported Nuvio client';
    end if;

    if not exists (
        select 1
        from auth.sessions
        where id = v_session_id
          and user_id = v_user_id
    ) then
        raise exception using errcode = '42501', message = 'Session is no longer active';
    end if;

    perform pg_catalog.pg_advisory_xact_lock(
        pg_catalog.hashtextextended(
            v_user_id::text || ':' || v_installation_id,
            0
        )
    );

    delete from public.user_session_devices
    where session_id = v_session_id;

    select session_id
    into v_previous_session_id
    from public.user_session_devices
    where user_id = v_user_id
      and installation_id = v_installation_id
    for update;

    insert into public.user_session_devices (
        session_id,
        user_id,
        installation_id,
        client_name,
        client_version,
        platform,
        device_name,
        last_seen_at
    )
    values (
        v_session_id,
        v_user_id,
        v_installation_id,
        v_client_name,
        left(nullif(btrim(p_client_version), ''), 40),
        left(coalesce(nullif(btrim(p_platform), ''), 'Unknown'), 80),
        left(nullif(btrim(p_device_name), ''), 160),
        now()
    )
    on conflict (user_id, installation_id) do update
    set session_id = excluded.session_id,
        client_name = excluded.client_name,
        client_version = excluded.client_version,
        platform = excluded.platform,
        device_name = excluded.device_name,
        last_seen_at = excluded.last_seen_at;

    if (
        v_previous_session_id is not null
        and v_previous_session_id <> v_session_id
    ) then
        delete from auth.sessions
        where id = v_previous_session_id
          and user_id = v_user_id;
    end if;

    return true;
end;
$_$;


--
-- Name: register_current_session(text, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.register_current_session(p_client_name text, p_client_version text DEFAULT NULL::text, p_platform text DEFAULT NULL::text, p_device_name text DEFAULT NULL::text) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
    v_session_id uuid := nullif(auth.jwt() ->> 'session_id', '')::uuid;
begin
    if v_session_id is null then
        raise exception using errcode = '42501', message = 'Authentication required';
    end if;

    return public.register_current_device(
        'nuvio-session-' || replace(v_session_id::text, '-', ''),
        p_client_name,
        p_client_version,
        p_platform,
        p_device_name
    );
end;
$$;


--
-- Name: revoke_my_session(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.revoke_my_session(p_session_id uuid) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
    v_user_id uuid := auth.uid();
    v_current_session_id uuid := nullif(auth.jwt() ->> 'session_id', '')::uuid;
begin
    if v_user_id is null or v_current_session_id is null then
        raise exception using errcode = '42501', message = 'Authentication required';
    end if;

    if p_session_id = v_current_session_id then
        raise exception using errcode = '22023', message = 'Use local sign out for the current session';
    end if;

    delete from auth.sessions
    where id = p_session_id
      and user_id = v_user_id;

    return found;
end;
$$;


--
-- Name: set_profile_pin(integer, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_profile_pin(p_profile_id integer, p_pin text, p_current_pin text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $_$
declare
    v_user_id uuid := get_sync_owner();
    v_updated_rows integer;
    v_pin_enabled boolean;
    v_pin_hash text;
begin
    if p_profile_id < 1 or p_profile_id > 6 then
        raise exception 'Invalid profile id';
    end if;

    if p_pin !~ '^[0-9]{4}$' then
        raise exception 'PIN must be exactly 4 digits';
    end if;

    select pin_enabled, pin_hash
    into v_pin_enabled, v_pin_hash
    from public.profiles
    where user_id = v_user_id
      and profile_index = p_profile_id;

    if not found then
        raise exception 'Profile not found for current user';
    end if;

    if v_pin_enabled is true and v_pin_hash is not null then
        if p_current_pin is null
           or p_current_pin !~ '^[0-9]{4}$'
           or extensions.crypt(p_current_pin, v_pin_hash) <> v_pin_hash then
            raise exception 'Current PIN is required to change PIN';
        end if;
    end if;

    update public.profiles
    set
        pin_enabled = true,
        pin_hash = extensions.crypt(p_pin, extensions.gen_salt('bf', 10)),
        pin_updated_at = now(),
        failed_pin_attempts = 0,
        pin_locked_until = null,
        updated_at = now()
    where user_id = v_user_id
      and profile_index = p_profile_id;

    get diagnostics v_updated_rows = row_count;
    if v_updated_rows = 0 then
        raise exception 'Profile not found for current user';
    end if;
end;
$_$;


--
-- Name: set_updated_at(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$;


--
-- Name: start_tracker_tv_login_session(text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.start_tracker_tv_login_session(p_tracker text, p_device_nonce text, p_redirect_base_url text) RETURNS TABLE(code text, web_url text, expires_at timestamp with time zone, poll_interval_seconds integer)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
    WITH inserted AS (
        INSERT INTO public.tracker_tv_login_sessions
            (code, tracker, device_nonce, owner_user_id, redirect_base_url, expires_at)
        SELECT
            upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8)),
            p_tracker,
            p_device_nonce,
            public.get_sync_owner(),
            p_redirect_base_url,
            now() + interval '5 minutes'
        WHERE public.get_sync_owner() IS NOT NULL
          AND p_tracker IN ('mal','anilist','kitsu')
          AND p_device_nonce IS NOT NULL
          AND length(p_device_nonce) >= 8
        RETURNING
            tracker_tv_login_sessions.code,
            tracker_tv_login_sessions.expires_at
    )
    SELECT
        inserted.code,
        p_redirect_base_url || '?code=' || inserted.code || '&t=' || p_tracker,
        inserted.expires_at,
        3
    FROM inserted;
$$;


--
-- Name: start_tv_login_session(text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.start_tv_login_session(p_device_nonce text, p_redirect_base_url text, p_device_name text DEFAULT NULL::text) RETURNS TABLE(code text, web_url text, expires_at timestamp with time zone, poll_interval_seconds integer)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
    v_code TEXT;
    v_expires TIMESTAMPTZ;
BEGIN
    IF p_device_nonce IS NULL OR length(trim(p_device_nonce)) < 12 THEN
        RAISE EXCEPTION 'Invalid device nonce';
    END IF;

    IF p_redirect_base_url IS NULL OR position('/tv-login' IN p_redirect_base_url) = 0 THEN
        RAISE EXCEPTION 'Invalid TV login redirect base URL';
    END IF;

    PERFORM expire_old_tv_login_sessions();

    IF (
        SELECT count(*)
        FROM tv_login_sessions
        WHERE created_at >= NOW() - INTERVAL '1 minute'
    ) > 200 THEN
        RAISE EXCEPTION 'Rate limit exceeded';
    END IF;

    v_code := random_tv_login_code();
    v_expires := NOW() + INTERVAL '5 minutes';

    INSERT INTO tv_login_sessions (
        code,
        device_nonce,
        device_name,
        status,
        expires_at,
        poll_interval_seconds
    )
    VALUES (
        v_code,
        p_device_nonce,
        p_device_name,
        'pending',
        v_expires,
        3
    );

    RETURN QUERY
    SELECT
        v_code,
        p_redirect_base_url || '?code=' || v_code,
        v_expires,
        3;
END;
$$;


--
-- Name: sync_current_origin_client_id(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_current_origin_client_id() RETURNS text
    LANGUAGE sql STABLE
    SET search_path TO 'public'
    AS $$
  select nullif(current_setting('app.origin_client_id', true), '')
$$;


--
-- Name: sync_delete_library_items(jsonb, integer, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_delete_library_items(p_keys jsonb, p_profile_id integer DEFAULT 1, p_origin_client_id text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
    v_user_id uuid := public.get_sync_owner();
begin
    if p_profile_id is null or p_profile_id < 1 or p_profile_id > 6 then
        raise exception 'Invalid profile id';
    end if;

    perform public.sync_set_origin_client_id(p_origin_client_id);

    with keys as (
        select distinct
            (e->>'content_id')::text as content_id,
            (e->>'content_type')::text as content_type
        from jsonb_array_elements(coalesce(p_keys, '[]'::jsonb)) e
        where btrim(coalesce(e->>'content_id', '')) <> ''
          and btrim(coalesce(e->>'content_type', '')) <> ''
    )
    delete from public.library_items li
    using keys k
    where li.user_id = v_user_id
      and li.profile_id = p_profile_id
      and li.content_id = k.content_id
      and li.content_type = k.content_type;
end;
$$;


--
-- Name: sync_delete_profile_data(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_delete_profile_data(p_profile_id integer) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE v_user_id uuid := get_sync_owner();
BEGIN
    DELETE FROM addons WHERE user_id = v_user_id AND profile_id = p_profile_id;
    DELETE FROM plugins WHERE user_id = v_user_id AND profile_id = p_profile_id;
    DELETE FROM collections WHERE user_id = v_user_id AND profile_id = p_profile_id;
    DELETE FROM watch_progress WHERE user_id = v_user_id AND profile_id = p_profile_id;
    DELETE FROM library_items WHERE user_id = v_user_id AND profile_id = p_profile_id;
    DELETE FROM watched_items WHERE user_id = v_user_id AND profile_id = p_profile_id;
    DELETE FROM profiles WHERE user_id = v_user_id AND profile_index = p_profile_id;
END; $$;


--
-- Name: sync_delete_profile_data(integer, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_delete_profile_data(p_profile_id integer, p_origin_client_id text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  perform public.sync_set_origin_client_id(p_origin_client_id);
  perform public.sync_delete_profile_data(p_profile_id);
end;
$$;


--
-- Name: sync_delete_provider_credentials(integer, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_delete_provider_credentials(p_profile_id integer, p_provider text, p_origin_client_id text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
    v_user_id uuid := get_sync_owner();
    v_provider text := lower(btrim(coalesce(p_provider, '')));
begin
    perform set_config('app.sync_origin_client_id', coalesce(p_origin_client_id, ''), true);

    if v_provider = '' then
        return;
    end if;

    delete from public.provider_credentials pc
    where pc.user_id = v_user_id
      and pc.profile_id = p_profile_id
      and pc.provider = v_provider;
end;
$$;


--
-- Name: sync_delete_watch_progress(jsonb, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_delete_watch_progress(p_keys jsonb, p_profile_id integer DEFAULT 1) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_effective_user_id uuid;
  v_auth_uid uuid := auth.uid();
  v_headers jsonb := coalesce(nullif(current_setting('request.headers', true), '')::jsonb, '{}'::jsonb);
  v_incoming_count integer := 0;
  v_deleted_count integer := 0;
  v_payload_hash text;
begin
  v_effective_user_id := get_sync_owner();

  select count(*) into v_incoming_count
  from jsonb_array_elements_text(coalesce(p_keys, '[]'::jsonb)) as k;

  select encode(
    extensions.digest(coalesce(string_agg(k, ',' order by k), ''), 'sha256'),
    'hex'
  ) into v_payload_hash
  from jsonb_array_elements_text(coalesce(p_keys, '[]'::jsonb)) as k;

  with deleted as (
    delete from watch_progress
    where user_id = v_effective_user_id
      and profile_id = p_profile_id
      and progress_key in (
        select jsonb_array_elements_text(coalesce(p_keys, '[]'::jsonb))
      )
    returning 1
  )
  select count(*)::integer into v_deleted_count from deleted;

end;
$$;


--
-- Name: sync_delete_watch_progress(text, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_delete_watch_progress(p_progress_key text, p_profile_id integer DEFAULT 1) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_user_id uuid := get_sync_owner();
  v_auth_uid uuid := auth.uid();
  v_headers jsonb := coalesce(nullif(current_setting('request.headers', true), '')::jsonb, '{}'::jsonb);
  v_deleted_count integer := 0;
begin
  with deleted as (
    delete from watch_progress
    where user_id = v_user_id and profile_id = p_profile_id and progress_key = p_progress_key
    returning 1
  )
  select count(*)::integer into v_deleted_count from deleted;

end;
$$;


--
-- Name: sync_delete_watch_progress(jsonb, integer, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_delete_watch_progress(p_keys jsonb, p_profile_id integer, p_origin_client_id text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  perform public.sync_set_origin_client_id(p_origin_client_id);
  perform public.sync_delete_watch_progress(p_keys, p_profile_id);
end;
$$;


--
-- Name: sync_delete_watched_items(jsonb, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_delete_watched_items(p_keys jsonb, p_profile_id integer DEFAULT 0) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_user_id uuid := public.get_sync_owner();
begin
  with keys as (
    select
      (k->>'content_id')::text as content_id,
      coalesce((k->>'season')::integer, -1) as season_key,
      coalesce((k->>'episode')::integer, -1) as episode_key
    from jsonb_array_elements(coalesce(p_keys, '[]'::jsonb)) as k
    where coalesce((k->>'content_id')::text, '') <> ''
  ), deleted as (
    delete from public.watched_items w
    using keys k
    where w.user_id = v_user_id
      and w.profile_id = p_profile_id
      and w.content_id = k.content_id
      and coalesce(w.season, -1) = k.season_key
      and coalesce(w.episode, -1) = k.episode_key
    returning w.user_id, w.profile_id, w.content_id, w.content_type, w.title, w.season, w.episode, w.watched_at
  )
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
    user_id,
    profile_id,
    'delete',
    content_id,
    content_type,
    title,
    season,
    episode,
    watched_at
  from deleted;
end;
$$;


--
-- Name: sync_delete_watched_items(jsonb, integer, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_delete_watched_items(p_keys jsonb, p_profile_id integer, p_origin_client_id text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  perform public.sync_set_origin_client_id(p_origin_client_id);
  perform public.sync_delete_watched_items(p_keys, p_profile_id);
end;
$$;


--
-- Name: sync_export_account_backup(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_export_account_backup() RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
    v_owner uuid;
    v_data jsonb;
BEGIN
    v_owner := public.get_sync_owner();

    IF v_owner IS NULL THEN
        RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '28000';
    END IF;

    v_data := jsonb_build_object(
        'profiles', (
            SELECT COALESCE(jsonb_agg(to_jsonb(src) ORDER BY src.profile_index), '[]'::jsonb)
            FROM (
                SELECT
                    profile_index,
                    profile_id,
                    name,
                    avatar_color_hex,
                    uses_primary_addons,
                    uses_primary_plugins,
                    avatar_id,
                    avatar_url,
                    created_at,
                    updated_at
                FROM public.profiles
                WHERE user_id = v_owner
                ORDER BY profile_index
            ) AS src
        ),
        'addons', (
            SELECT COALESCE(jsonb_agg(to_jsonb(src) ORDER BY src.profile_id, src.sort_order, src.created_at), '[]'::jsonb)
            FROM (
                SELECT
                    profile_id,
                    url,
                    name,
                    enabled,
                    sort_order,
                    created_at,
                    updated_at
                FROM public.addons
                WHERE user_id = v_owner
                ORDER BY profile_id, sort_order, created_at
            ) AS src
        ),
        'plugins', (
            SELECT COALESCE(jsonb_agg(to_jsonb(src) ORDER BY src.profile_id, src.sort_order, src.created_at), '[]'::jsonb)
            FROM (
                SELECT
                    profile_id,
                    url,
                    name,
                    enabled,
                    sort_order,
                    repo_type,
                    created_at,
                    updated_at
                FROM public.plugins
                WHERE user_id = v_owner
                ORDER BY profile_id, sort_order, created_at
            ) AS src
        ),
        'library_items', (
            SELECT COALESCE(jsonb_agg(to_jsonb(src) ORDER BY src.profile_id, src.added_at DESC, src.created_at), '[]'::jsonb)
            FROM (
                SELECT
                    profile_id,
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
                    added_at,
                    created_at,
                    updated_at
                FROM public.library_items
                WHERE user_id = v_owner
                ORDER BY profile_id, added_at DESC, created_at
            ) AS src
        ),
        'watch_progress', (
            SELECT COALESCE(jsonb_agg(to_jsonb(src) ORDER BY src.profile_id, src.last_watched DESC, src.progress_key), '[]'::jsonb)
            FROM (
                SELECT
                    profile_id,
                    content_id,
                    content_type,
                    video_id,
                    season,
                    episode,
                    position,
                    duration,
                    last_watched,
                    progress_key
                FROM public.watch_progress
                WHERE user_id = v_owner
                ORDER BY profile_id, last_watched DESC, progress_key
            ) AS src
        ),
        'watched_items', (
            SELECT COALESCE(jsonb_agg(to_jsonb(src) ORDER BY src.profile_id, src.watched_at DESC, src.content_id), '[]'::jsonb)
            FROM (
                SELECT
                    profile_id,
                    content_id,
                    content_type,
                    title,
                    season,
                    episode,
                    watched_at,
                    created_at
                FROM public.watched_items
                WHERE user_id = v_owner
                ORDER BY profile_id, watched_at DESC, content_id
            ) AS src
        ),
        'profile_settings_blobs', (
            SELECT COALESCE(jsonb_agg(to_jsonb(src) ORDER BY src.profile_id, src.platform, src.updated_at), '[]'::jsonb)
            FROM (
                SELECT
                    profile_id,
                    platform,
                    settings_json,
                    created_at,
                    updated_at
                FROM public.profile_settings_blobs
                WHERE user_id = v_owner
                ORDER BY profile_id, platform, updated_at
            ) AS src
        ),
        'home_catalog_settings', (
            SELECT COALESCE(jsonb_agg(to_jsonb(src) ORDER BY src.profile_id, src.platform, src.updated_at), '[]'::jsonb)
            FROM (
                SELECT
                    profile_id,
                    platform,
                    settings_json,
                    updated_at
                FROM public.home_catalog_settings
                WHERE user_id = v_owner
                ORDER BY profile_id, platform, updated_at
            ) AS src
        ),
        'collections', (
            SELECT COALESCE(jsonb_agg(to_jsonb(src) ORDER BY src.profile_id, src.updated_at), '[]'::jsonb)
            FROM (
                SELECT
                    profile_id,
                    collections_json,
                    created_at,
                    updated_at
                FROM public.collections
                WHERE user_id = v_owner
                ORDER BY profile_id, updated_at
            ) AS src
        ),
        'profile_tracker_settings', (
            SELECT COALESCE(jsonb_agg(to_jsonb(src) ORDER BY src.profile_id, src.tracker), '[]'::jsonb)
            FROM (
                SELECT
                    profile_id,
                    tracker,
                    enabled_statuses,
                    row_order,
                    send_progress,
                    updated_at
                FROM public.profile_tracker_settings
                WHERE user_id = v_owner
                ORDER BY profile_id, tracker
            ) AS src
        )
    );

    RETURN jsonb_build_object(
        'format', 'nuvio_account_backup',
        'version', 1,
        'scope', 'account',
        'exported_at', to_jsonb(now()),
        'sensitive_data_excluded', jsonb_build_array(
            'auth_sessions',
            'linked_devices',
            'profile_pin_hashes',
            'tracker_tokens',
            'provider_credentials',
            'audit_logs',
            'login_sessions'
        ),
        'counts', jsonb_build_object(
            'profiles', jsonb_array_length(v_data->'profiles'),
            'addons', jsonb_array_length(v_data->'addons'),
            'plugins', jsonb_array_length(v_data->'plugins'),
            'library_items', jsonb_array_length(v_data->'library_items'),
            'watch_progress', jsonb_array_length(v_data->'watch_progress'),
            'watched_items', jsonb_array_length(v_data->'watched_items'),
            'profile_settings_blobs', jsonb_array_length(v_data->'profile_settings_blobs'),
            'home_catalog_settings', jsonb_array_length(v_data->'home_catalog_settings'),
            'collections', jsonb_array_length(v_data->'collections'),
            'profile_tracker_settings', jsonb_array_length(v_data->'profile_tracker_settings')
        ),
        'data', v_data
    );
END;
$$;


--
-- Name: FUNCTION sync_export_account_backup(); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.sync_export_account_backup() IS 'Exports a versioned Nuvio account backup for the authenticated sync owner. Sensitive auth, credential, token, session, device, and audit data are intentionally excluded.';


--
-- Name: sync_get_library_delta_cursor(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_get_library_delta_cursor(p_profile_id integer DEFAULT 1) RETURNS bigint
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
    select coalesce(max(e.event_id), 0)::bigint
    from public.library_item_events e
    where e.user_id = public.get_sync_owner()
      and e.profile_id = p_profile_id;
$$;


--
-- Name: sync_get_watch_progress_delta_cursor(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_get_watch_progress_delta_cursor(p_profile_id integer DEFAULT 1) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_user_id uuid := public.get_sync_owner();
  v_auth_uid uuid := auth.uid();
  v_headers jsonb := coalesce(nullif(current_setting('request.headers', true), '')::jsonb, '{}'::jsonb);
  v_cursor bigint;
begin
  select coalesce(max(event_id), 0)::bigint into v_cursor
  from public.watch_progress_events
  where user_id = v_user_id
    and profile_id = p_profile_id;


  return v_cursor;
end;
$$;


--
-- Name: sync_get_watched_items_delta_cursor(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_get_watched_items_delta_cursor(p_profile_id integer DEFAULT 1) RETURNS bigint
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select coalesce(max(event_id), 0)::bigint
  from public.watched_item_events
  where user_id = public.get_sync_owner()
    and profile_id = p_profile_id;
$$;


--
-- Name: sync_pull_collections(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_pull_collections(p_profile_id integer) RETURNS TABLE(profile_id integer, collections_json jsonb, updated_at timestamp with time zone)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
    SELECT
        c.profile_id,
        c.collections_json,
        c.updated_at
    FROM public.collections c
    WHERE c.user_id = get_sync_owner()
      AND c.profile_id = p_profile_id
    LIMIT 1;
$$;


--
-- Name: home_catalog_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.home_catalog_settings (
    user_id uuid DEFAULT auth.uid() NOT NULL,
    profile_id integer DEFAULT 1 NOT NULL,
    settings_json jsonb DEFAULT '{}'::jsonb NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    platform text DEFAULT 'tv'::text NOT NULL,
    id uuid DEFAULT gen_random_uuid() NOT NULL
)
WITH (autovacuum_vacuum_scale_factor='0.02', autovacuum_vacuum_threshold='500', autovacuum_analyze_scale_factor='0.02', autovacuum_analyze_threshold='500', autovacuum_vacuum_cost_limit='800', autovacuum_vacuum_cost_delay='5');


--
-- Name: sync_pull_home_catalog_settings(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_pull_home_catalog_settings(p_profile_id integer) RETURNS SETOF public.home_catalog_settings
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
    v_user_id uuid;
begin
    v_user_id := get_sync_owner();
    return query
        select *
        from public.home_catalog_settings
        where user_id = v_user_id
          and profile_id = p_profile_id;
end;
$$;


--
-- Name: sync_pull_home_catalog_settings(integer, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_pull_home_catalog_settings(p_profile_id integer, p_platform text DEFAULT 'tv'::text) RETURNS SETOF public.home_catalog_settings
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
    v_user_id uuid;
BEGIN
    v_user_id := get_sync_owner();
    RETURN QUERY
        SELECT *
        FROM public.home_catalog_settings
        WHERE user_id = v_user_id
          AND profile_id = p_profile_id
          AND platform = p_platform;
END;
$$;


--
-- Name: library_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.library_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    content_id text NOT NULL,
    content_type text NOT NULL,
    name text DEFAULT ''::text NOT NULL,
    poster text,
    poster_shape text DEFAULT 'POSTER'::text NOT NULL,
    background text,
    description text,
    release_info text,
    imdb_rating real,
    genres text[] DEFAULT '{}'::text[],
    addon_base_url text,
    added_at bigint DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    profile_id integer DEFAULT 1 NOT NULL
)
WITH (autovacuum_vacuum_scale_factor='0.03', autovacuum_vacuum_threshold='1000', autovacuum_analyze_scale_factor='0.03', autovacuum_analyze_threshold='1000', autovacuum_vacuum_cost_limit='800', autovacuum_vacuum_cost_delay='5');


--
-- Name: sync_pull_library(integer, integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_pull_library(p_profile_id integer DEFAULT 1, p_limit integer DEFAULT 500, p_offset integer DEFAULT 0) RETURNS SETOF public.library_items
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
      SELECT * FROM library_items
      WHERE user_id = get_sync_owner() AND profile_id = p_profile_id
      ORDER BY added_at DESC
      LIMIT p_limit
      OFFSET p_offset;
  $$;


--
-- Name: sync_pull_library_delta(integer, bigint, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_pull_library_delta(p_profile_id integer DEFAULT 1, p_since_event_id bigint DEFAULT 0, p_limit integer DEFAULT 1000) RETURNS TABLE(event_id bigint, operation text, content_id text, content_type text, name text, poster text, poster_shape text, background text, description text, release_info text, imdb_rating real, genres text[], addon_base_url text, added_at bigint)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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
        e.added_at
    from public.library_item_events e
    where e.user_id = public.get_sync_owner()
      and e.profile_id = p_profile_id
      and e.event_id > greatest(coalesce(p_since_event_id, 0), 0)
    order by e.event_id asc
    limit least(greatest(coalesce(p_limit, 1000), 1), 1000);
$$;


--
-- Name: sync_pull_profile_locks(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_pull_profile_locks() RETURNS TABLE(profile_index integer, pin_enabled boolean, pin_locked_until timestamp with time zone)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
    SELECT
        p.profile_index,
        p.pin_enabled,
        p.pin_locked_until
    FROM public.profiles p
    WHERE p.user_id = get_sync_owner()
    ORDER BY p.profile_index;
$$;


--
-- Name: sync_pull_profile_settings_blob(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_pull_profile_settings_blob(p_profile_id integer) RETURNS TABLE(profile_id integer, settings_json jsonb, updated_at timestamp with time zone)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
    SELECT
        b.profile_id,
        b.settings_json,
        b.updated_at
    FROM public.profile_settings_blobs b
    WHERE b.user_id = get_sync_owner()
      AND b.profile_id = p_profile_id
    ORDER BY b.updated_at DESC
    LIMIT 1;
$$;


--
-- Name: sync_pull_profile_settings_blob(integer, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_pull_profile_settings_blob(p_profile_id integer, p_platform text DEFAULT 'tv'::text) RETURNS TABLE(profile_id integer, settings_json jsonb, updated_at timestamp with time zone)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
    SELECT
        b.profile_id,
        b.settings_json,
        b.updated_at
    FROM public.profile_settings_blobs b
    WHERE b.user_id = get_sync_owner()
      AND b.profile_id = p_profile_id
      AND b.platform = p_platform
    ORDER BY b.updated_at DESC
    LIMIT 1;
$$;


--
-- Name: sync_pull_profiles(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_pull_profiles() RETURNS TABLE(id uuid, user_id uuid, profile_index integer, name text, avatar_color_hex text, uses_primary_addons boolean, uses_primary_plugins boolean, avatar_id text, avatar_url text, pin_enabled boolean, pin_locked_until timestamp with time zone, created_at timestamp with time zone, updated_at timestamp with time zone)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
    select
        p.id,
        p.user_id,
        p.profile_index,
        p.name,
        p.avatar_color_hex,
        p.uses_primary_addons,
        p.uses_primary_plugins,
        p.avatar_id,
        p.avatar_url,
        p.pin_enabled,
        p.pin_locked_until,
        p.created_at,
        p.updated_at
    from public.profiles p
    where p.user_id = get_sync_owner()
    order by p.profile_index;
$$;


--
-- Name: sync_pull_provider_credentials(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_pull_provider_credentials(p_profile_id integer) RETURNS TABLE(provider text, credential_json jsonb, updated_at timestamp with time zone)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
    select null::text as provider,
           null::jsonb as credential_json,
           null::timestamp with time zone as updated_at
    where false;
$$;


--
-- Name: watch_progress; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.watch_progress (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    content_id text NOT NULL,
    content_type text NOT NULL,
    video_id text NOT NULL,
    season integer,
    episode integer,
    "position" bigint DEFAULT 0 NOT NULL,
    duration bigint DEFAULT 0 NOT NULL,
    last_watched bigint DEFAULT 0 NOT NULL,
    progress_key text NOT NULL,
    profile_id integer DEFAULT 1 NOT NULL
)
WITH (autovacuum_vacuum_cost_limit='1000', autovacuum_vacuum_cost_delay='5', autovacuum_vacuum_scale_factor='0.02', autovacuum_analyze_scale_factor='0.01', autovacuum_vacuum_threshold='50', autovacuum_analyze_threshold='50');


--
-- Name: sync_pull_watch_progress(integer, bigint, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_pull_watch_progress(p_profile_id integer DEFAULT 1, p_since_last_watched bigint DEFAULT NULL::bigint, p_limit integer DEFAULT NULL::integer) RETURNS SETOF public.watch_progress
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_uid uuid := (select auth.uid());
  v_owner uuid;
  v_headers jsonb := coalesce(nullif(current_setting('request.headers', true), '')::jsonb, '{}'::jsonb);
  v_limit integer;
  v_returned_count integer := 0;
  v_max_last_watched bigint;
begin
  set local statement_timeout = '30s';

  v_owner := public.get_sync_owner();

  v_limit := case
    when p_limit is null or p_limit <= 0 then null
    else p_limit
  end;

  if p_since_last_watched is null then
    create temporary table pg_temp._watch_progress_pull_result on commit drop as
    select *
    from public.watch_progress
    where user_id = v_owner
      and profile_id = p_profile_id
    order by last_watched desc
    limit v_limit;
  else
    create temporary table pg_temp._watch_progress_pull_result on commit drop as
    select *
    from public.watch_progress
    where user_id = v_owner
      and profile_id = p_profile_id
      and last_watched > p_since_last_watched
    order by last_watched desc
    limit v_limit;
  end if;

  select count(*)::integer, max(last_watched)
    into v_returned_count, v_max_last_watched
  from pg_temp._watch_progress_pull_result;


  return query select * from pg_temp._watch_progress_pull_result;
end;
$$;


--
-- Name: sync_pull_watch_progress_delta(integer, bigint, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_pull_watch_progress_delta(p_profile_id integer DEFAULT 1, p_since_event_id bigint DEFAULT 0, p_limit integer DEFAULT 1000) RETURNS TABLE(event_id bigint, operation text, progress_key text, content_id text, content_type text, video_id text, season integer, episode integer, "position" bigint, duration bigint, last_watched bigint)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_user_id uuid := public.get_sync_owner();
  v_auth_uid uuid := auth.uid();
  v_headers jsonb := coalesce(nullif(current_setting('request.headers', true), '')::jsonb, '{}'::jsonb);
  v_limit integer := least(greatest(coalesce(p_limit, 1000), 1), 1000);
  v_returned_count integer := 0;
  v_min_event_id bigint;
  v_max_event_id bigint;
begin
  create temporary table pg_temp._watch_progress_delta_result on commit drop as
  select
    e.event_id,
    e.operation,
    e.progress_key,
    e.content_id,
    e.content_type,
    e.video_id,
    e.season,
    e.episode,
    e.position,
    e.duration,
    e.last_watched
  from public.watch_progress_events e
  where e.user_id = v_user_id
    and e.profile_id = p_profile_id
    and e.event_id > greatest(coalesce(p_since_event_id, 0), 0)
  order by e.event_id asc
  limit v_limit;

  select count(*)::integer, min(r.event_id), max(r.event_id)
    into v_returned_count, v_min_event_id, v_max_event_id
  from pg_temp._watch_progress_delta_result r;


  return query
  select
    r.event_id,
    r.operation,
    r.progress_key,
    r.content_id,
    r.content_type,
    r.video_id,
    r.season,
    r.episode,
    r.position,
    r.duration,
    r.last_watched
  from pg_temp._watch_progress_delta_result r;
end;
$$;


--
-- Name: watched_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.watched_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    content_id text NOT NULL,
    content_type text NOT NULL,
    title text DEFAULT ''::text NOT NULL,
    season integer,
    episode integer,
    watched_at bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    profile_id integer DEFAULT 1 NOT NULL
)
WITH (autovacuum_vacuum_cost_limit='1000', autovacuum_vacuum_cost_delay='5', autovacuum_vacuum_scale_factor='0.02', autovacuum_analyze_scale_factor='0.01', autovacuum_vacuum_threshold='50', autovacuum_analyze_threshold='50');


--
-- Name: sync_pull_watched_items(integer, integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_pull_watched_items(p_profile_id integer DEFAULT 1, p_page integer DEFAULT 1, p_page_size integer DEFAULT 100000) RETURNS SETOF public.watched_items
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
    SELECT * FROM watched_items
    WHERE user_id = get_sync_owner() AND profile_id = p_profile_id
    ORDER BY watched_at DESC
    LIMIT p_page_size
    OFFSET (p_page - 1) * p_page_size;
$$;


--
-- Name: sync_pull_watched_items_delta(integer, bigint, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_pull_watched_items_delta(p_profile_id integer DEFAULT 1, p_since_event_id bigint DEFAULT 0, p_limit integer DEFAULT 1000) RETURNS TABLE(event_id bigint, operation text, content_id text, content_type text, title text, season integer, episode integer, watched_at bigint)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_user_id uuid := public.get_sync_owner();
  v_limit integer := least(greatest(coalesce(p_limit, 1000), 1), 1000);
begin
  return query
  select
    e.event_id,
    e.operation,
    e.content_id,
    e.content_type,
    e.title,
    e.season,
    e.episode,
    e.watched_at
  from public.watched_item_events e
  where e.user_id = v_user_id
    and e.profile_id = p_profile_id
    and e.event_id > greatest(coalesce(p_since_event_id, 0), 0)
  order by e.event_id asc
  limit v_limit;
end;
$$;


--
-- Name: sync_push_addons(jsonb, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_push_addons(p_addons jsonb, p_profile_id integer DEFAULT 1) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
    v_user_id uuid := get_sync_owner();
    v_headers jsonb := coalesce(
        nullif(current_setting('request.headers', true), '')::jsonb,
        '{}'::jsonb
    );
    v_urls text[];
    v_names text[];
    v_enabled_values boolean[];
    v_sort_orders integer[];
    v_url_hashes text[];
    v_old_count integer := 0;
    v_incoming_count integer := 0;
    v_deleted_count integer := 0;
    v_old_hash text;
    v_incoming_hash text;
    v_deleted_hashes jsonb := '[]'::jsonb;
begin
    -- Expand and type the incoming JSON exactly once. The aligned arrays are
    -- reused by the hash comparison, upsert, and delete.
    select
        coalesce(array_agg(i.url order by i.ordinality), array[]::text[]),
        coalesce(array_agg(i.name order by i.ordinality), array[]::text[]),
        coalesce(array_agg(i.enabled order by i.ordinality), array[]::boolean[]),
        coalesce(array_agg(i.sort_order order by i.ordinality), array[]::integer[]),
        coalesce(array_agg(i.url_hash order by i.ordinality), array[]::text[]),
        count(*)::integer,
        encode(
            extensions.digest(
                coalesce(
                    string_agg(
                        jsonb_build_array(
                            i.url,
                            i.name,
                            i.enabled,
                            i.sort_order
                        )::text,
                        E'\n'
                        order by i.url_hash, i.url
                    ),
                    ''
                ),
                'sha256'
            ),
            'hex'
        )
    into
        v_urls,
        v_names,
        v_enabled_values,
        v_sort_orders,
        v_url_hashes,
        v_incoming_count,
        v_incoming_hash
    from (
        select
            e.ordinality,
            (e.item->>'url')::text as url,
            (e.item->>'name')::text as name,
            coalesce((e.item->>'enabled')::boolean, true) as enabled,
            coalesce((e.item->>'sort_order')::integer, 0) as sort_order,
            md5((e.item->>'url')::text) as url_hash
        from jsonb_array_elements(coalesce(p_addons, '[]'::jsonb))
            with ordinality as e(item, ordinality)
    ) as i;

    -- Read the existing profile once, producing both its normalized state hash
    -- and the deletion audit data.
    select
        count(*)::integer,
        encode(
            extensions.digest(
                coalesce(
                    string_agg(
                        jsonb_build_array(
                            a.url,
                            a.name,
                            a.enabled,
                            a.sort_order
                        )::text,
                        E'\n'
                        order by md5(a.url), a.url
                    ),
                    ''
                ),
                'sha256'
            ),
            'hex'
        ),
        count(*) filter (
            where not coalesce(md5(a.url) = any(v_url_hashes), false)
        ),
        coalesce(
            jsonb_agg(md5(a.url) order by md5(a.url)) filter (
                where not coalesce(md5(a.url) = any(v_url_hashes), false)
            ),
            '[]'::jsonb
        )
    into
        v_old_count,
        v_old_hash,
        v_deleted_count,
        v_deleted_hashes
    from public.addons as a
    where a.user_id = v_user_id
      and a.profile_id = p_profile_id;

    -- Identical retries perform no audit insert, upsert, or delete.
    if v_old_count = v_incoming_count
       and v_old_hash = v_incoming_hash then
        return;
    end if;

    insert into public.sync_push_audit_logs (
        surface,
        user_id,
        auth_uid,
        profile_id,
        request_user_agent,
        request_ip,
        request_method,
        request_path,
        old_row_count,
        incoming_row_count,
        deleted_row_count,
        old_payload_hash,
        incoming_payload_hash,
        deleted_item_hashes,
        metadata
    ) values (
        'addons',
        v_user_id,
        auth.uid(),
        p_profile_id,
        coalesce(v_headers->>'user-agent', v_headers->>'User-Agent'),
        nullif(
            split_part(
                coalesce(
                    v_headers->>'x-forwarded-for',
                    v_headers->>'X-Forwarded-For',
                    ''
                ),
                ',',
                1
            ),
            ''
        ),
        current_setting('request.method', true),
        current_setting('request.path', true),
        v_old_count,
        v_incoming_count,
        v_deleted_count,
        v_old_hash,
        v_incoming_hash,
        v_deleted_hashes,
        jsonb_build_object('would_delete_existing_rows', v_deleted_count > 0)
    );

    insert into public.addons (
        user_id,
        url,
        name,
        enabled,
        sort_order,
        profile_id
    )
    select
        v_user_id,
        i.url,
        i.name,
        i.enabled,
        i.sort_order,
        p_profile_id
    from unnest(
        v_urls,
        v_names,
        v_enabled_values,
        v_sort_orders
    ) as i(url, name, enabled, sort_order)
    on conflict (user_id, md5(url), profile_id)
    do update set
        name = excluded.name,
        enabled = excluded.enabled,
        sort_order = excluded.sort_order
    where addons.name is distinct from excluded.name
       or addons.enabled is distinct from excluded.enabled
       or addons.sort_order is distinct from excluded.sort_order;

    delete from public.addons as a
    where a.user_id = v_user_id
      and a.profile_id = p_profile_id
      and not coalesce(md5(a.url) = any(v_url_hashes), false);
end;
$$;


--
-- Name: sync_push_addons(jsonb, integer, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_push_addons(p_addons jsonb, p_profile_id integer, p_origin_client_id text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  perform public.sync_set_origin_client_id(p_origin_client_id);
  perform public.sync_push_addons(p_addons, p_profile_id);
end;
$$;


--
-- Name: sync_push_collections(integer, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_push_collections(p_profile_id integer, p_collections_json jsonb) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
    v_user_id uuid := get_sync_owner();
begin
    if p_profile_id < 1 or p_profile_id > 6 then
        raise exception 'Invalid profile id';
    end if;

    insert into public.collections (
        user_id,
        profile_id,
        collections_json,
        updated_at
    ) values (
        v_user_id,
        p_profile_id,
        coalesce(p_collections_json, '[]'::jsonb),
        now()
    )
    on conflict (user_id, profile_id)
    do update set
        collections_json = excluded.collections_json,
        updated_at = now()
    where public.collections.collections_json is distinct from excluded.collections_json;
end;
$$;


--
-- Name: sync_push_collections(integer, jsonb, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_push_collections(p_profile_id integer, p_collections_json jsonb, p_origin_client_id text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  perform public.sync_set_origin_client_id(p_origin_client_id);
  perform public.sync_push_collections(p_profile_id, p_collections_json);
end;
$$;


--
-- Name: sync_push_home_catalog_settings(integer, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_push_home_catalog_settings(p_profile_id integer, p_settings_json jsonb) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
    perform public.sync_push_home_catalog_settings(p_profile_id, p_settings_json, 'tv'::text);
end;
$$;


--
-- Name: sync_push_home_catalog_settings(integer, jsonb, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_push_home_catalog_settings(p_profile_id integer, p_settings_json jsonb, p_platform text DEFAULT 'tv'::text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
    v_user_id uuid;
begin
    v_user_id := get_sync_owner();
    insert into public.home_catalog_settings (user_id, profile_id, platform, settings_json, updated_at)
    values (v_user_id, p_profile_id, p_platform, p_settings_json, now())
    on conflict (user_id, profile_id, platform)
    do update set
        settings_json = excluded.settings_json,
        updated_at = excluded.updated_at
    where public.home_catalog_settings.settings_json is distinct from excluded.settings_json;
end;
$$;


--
-- Name: sync_push_home_catalog_settings(integer, jsonb, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_push_home_catalog_settings(p_profile_id integer, p_settings_json jsonb, p_platform text, p_origin_client_id text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  perform public.sync_set_origin_client_id(p_origin_client_id);
  perform public.sync_push_home_catalog_settings(p_profile_id, p_settings_json, p_platform);
end;
$$;


--
-- Name: sync_push_library(jsonb, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_push_library(p_items jsonb, p_profile_id integer DEFAULT 1) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE v_user_id uuid := get_sync_owner();
BEGIN
    INSERT INTO library_items (
        user_id, content_id, content_type, name, poster, poster_shape,
        background, description, release_info, imdb_rating, genres,
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
$$;


--
-- Name: sync_push_library(jsonb, integer, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_push_library(p_items jsonb, p_profile_id integer, p_origin_client_id text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  perform public.sync_set_origin_client_id(p_origin_client_id);
  perform public.sync_push_library(p_items, p_profile_id);
end;
$$;


--
-- Name: sync_push_library_items(jsonb, integer, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_push_library_items(p_items jsonb, p_profile_id integer DEFAULT 1, p_origin_client_id text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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
       or library_items.description is distinct from excluded.description
       or library_items.release_info is distinct from excluded.release_info
       or library_items.imdb_rating is distinct from excluded.imdb_rating
       or library_items.genres is distinct from excluded.genres
       or library_items.addon_base_url is distinct from excluded.addon_base_url
       or library_items.added_at is distinct from excluded.added_at;
end;
$$;


--
-- Name: sync_push_plugins(jsonb, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_push_plugins(p_plugins jsonb, p_profile_id integer DEFAULT 1) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
    v_user_id uuid := get_sync_owner();
    v_headers jsonb := coalesce(
        nullif(current_setting('request.headers', true), '')::jsonb,
        '{}'::jsonb
    );
    v_urls text[];
    v_names text[];
    v_enabled_values boolean[];
    v_sort_orders integer[];
    v_repo_types text[];
    v_url_hashes text[];
    v_old_count integer := 0;
    v_incoming_count integer := 0;
    v_deleted_count integer := 0;
    v_old_hash text;
    v_incoming_hash text;
    v_deleted_hashes jsonb := '[]'::jsonb;
begin
    -- Expand and type the incoming JSON exactly once. The aligned arrays are
    -- reused by the hash comparison, upsert, and delete.
    select
        coalesce(array_agg(i.url order by i.ordinality), array[]::text[]),
        coalesce(array_agg(i.name order by i.ordinality), array[]::text[]),
        coalesce(array_agg(i.enabled order by i.ordinality), array[]::boolean[]),
        coalesce(array_agg(i.sort_order order by i.ordinality), array[]::integer[]),
        coalesce(array_agg(i.repo_type order by i.ordinality), array[]::text[]),
        coalesce(array_agg(i.url_hash order by i.ordinality), array[]::text[]),
        count(*)::integer,
        encode(
            extensions.digest(
                coalesce(
                    string_agg(
                        jsonb_build_array(
                            i.url,
                            i.name,
                            i.enabled,
                            i.sort_order,
                            i.repo_type
                        )::text,
                        E'\n'
                        order by i.url_hash, i.url
                    ),
                    ''
                ),
                'sha256'
            ),
            'hex'
        )
    into
        v_urls,
        v_names,
        v_enabled_values,
        v_sort_orders,
        v_repo_types,
        v_url_hashes,
        v_incoming_count,
        v_incoming_hash
    from (
        select
            e.ordinality,
            (e.item->>'url')::text as url,
            (e.item->>'name')::text as name,
            coalesce((e.item->>'enabled')::boolean, true) as enabled,
            coalesce((e.item->>'sort_order')::integer, 0) as sort_order,
            (e.item->>'repo_type')::text as repo_type,
            md5((e.item->>'url')::text) as url_hash
        from jsonb_array_elements(coalesce(p_plugins, '[]'::jsonb))
            with ordinality as e(item, ordinality)
    ) as i;

    -- Read the existing profile once, producing both its normalized state hash
    -- and the deletion audit data.
    select
        count(*)::integer,
        encode(
            extensions.digest(
                coalesce(
                    string_agg(
                        jsonb_build_array(
                            p.url,
                            p.name,
                            p.enabled,
                            p.sort_order,
                            p.repo_type
                        )::text,
                        E'\n'
                        order by md5(p.url), p.url
                    ),
                    ''
                ),
                'sha256'
            ),
            'hex'
        ),
        count(*) filter (
            where not coalesce(md5(p.url) = any(v_url_hashes), false)
        ),
        coalesce(
            jsonb_agg(md5(p.url) order by md5(p.url)) filter (
                where not coalesce(md5(p.url) = any(v_url_hashes), false)
            ),
            '[]'::jsonb
        )
    into
        v_old_count,
        v_old_hash,
        v_deleted_count,
        v_deleted_hashes
    from public.plugins as p
    where p.user_id = v_user_id
      and p.profile_id = p_profile_id;

    -- Identical retries perform no audit insert, upsert, or delete.
    if v_old_count = v_incoming_count
       and v_old_hash = v_incoming_hash then
        return;
    end if;

    insert into public.sync_push_audit_logs (
        surface,
        user_id,
        auth_uid,
        profile_id,
        request_user_agent,
        request_ip,
        request_method,
        request_path,
        old_row_count,
        incoming_row_count,
        deleted_row_count,
        old_payload_hash,
        incoming_payload_hash,
        deleted_item_hashes,
        metadata
    ) values (
        'plugins',
        v_user_id,
        auth.uid(),
        p_profile_id,
        coalesce(v_headers->>'user-agent', v_headers->>'User-Agent'),
        nullif(
            split_part(
                coalesce(
                    v_headers->>'x-forwarded-for',
                    v_headers->>'X-Forwarded-For',
                    ''
                ),
                ',',
                1
            ),
            ''
        ),
        current_setting('request.method', true),
        current_setting('request.path', true),
        v_old_count,
        v_incoming_count,
        v_deleted_count,
        v_old_hash,
        v_incoming_hash,
        v_deleted_hashes,
        jsonb_build_object('would_delete_existing_rows', v_deleted_count > 0)
    );

    insert into public.plugins (
        user_id,
        url,
        name,
        enabled,
        sort_order,
        profile_id,
        repo_type
    )
    select
        v_user_id,
        i.url,
        i.name,
        i.enabled,
        i.sort_order,
        p_profile_id,
        i.repo_type
    from unnest(
        v_urls,
        v_names,
        v_enabled_values,
        v_sort_orders,
        v_repo_types
    ) as i(url, name, enabled, sort_order, repo_type)
    on conflict (user_id, md5(url), profile_id)
    do update set
        name = excluded.name,
        enabled = excluded.enabled,
        sort_order = excluded.sort_order,
        repo_type = excluded.repo_type
    where plugins.name is distinct from excluded.name
       or plugins.enabled is distinct from excluded.enabled
       or plugins.sort_order is distinct from excluded.sort_order
       or plugins.repo_type is distinct from excluded.repo_type;

    delete from public.plugins as p
    where p.user_id = v_user_id
      and p.profile_id = p_profile_id
      and not coalesce(md5(p.url) = any(v_url_hashes), false);
end;
$$;


--
-- Name: sync_push_plugins(jsonb, integer, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_push_plugins(p_plugins jsonb, p_profile_id integer, p_origin_client_id text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
    perform set_config('app.sync_origin_client_id', coalesce(p_origin_client_id, ''), true);
    perform public.sync_push_plugins(p_plugins, p_profile_id);
end;
$$;


--
-- Name: sync_push_profile_settings_blob(integer, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_push_profile_settings_blob(p_profile_id integer, p_settings_json jsonb) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
    perform public.sync_push_profile_settings_blob(p_profile_id, p_settings_json, 'tv'::text);
end;
$$;


--
-- Name: sync_push_profile_settings_blob(integer, jsonb, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_push_profile_settings_blob(p_profile_id integer, p_settings_json jsonb, p_platform text DEFAULT 'tv'::text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $_$
declare
    v_user_id uuid := get_sync_owner();
    v_headers jsonb := coalesce(
        nullif(current_setting('request.headers', true), '')::jsonb,
        '{}'::jsonb
    );
    v_old_settings jsonb;
    v_new_settings jsonb := coalesce(p_settings_json, '{}'::jsonb);
    v_old_text text;
    v_incoming_text text;
    v_old_hash text;
    v_incoming_hash text;
    v_old_size integer;
    v_incoming_size integer;
    v_allow_settings_shrink boolean := false;
    v_plugins_cleared boolean := false;
    v_suspicious_shrink boolean := false;
begin
    if p_profile_id < 1 or p_profile_id > 6 then
        raise exception 'Invalid profile id';
    end if;

    v_allow_settings_shrink :=
        lower(coalesce(
            v_headers->>'x-nuvio-allow-settings-shrink',
            v_headers->>'X-Nuvio-Allow-Settings-Shrink',
            ''
        )) in ('1', 'true', 't', 'yes', 'y');

    if v_new_settings #>> '{features,player_settings,next_episode_threshold_percent_v2,value}' ~ '^-?[0-9]+(\.[0-9]+)?$' then
        v_new_settings := jsonb_set(
            v_new_settings,
            '{features,player_settings,next_episode_threshold_percent_v2}',
            jsonb_build_object(
                'type', 'float',
                'value', ((v_new_settings #>> '{features,player_settings,next_episode_threshold_percent_v2,value}')::numeric)
            ),
            true
        );
    end if;

    if v_new_settings #>> '{features,player_settings,next_episode_threshold_minutes_before_end_v2,value}' ~ '^-?[0-9]+(\.[0-9]+)?$' then
        v_new_settings := jsonb_set(
            v_new_settings,
            '{features,player_settings,next_episode_threshold_minutes_before_end_v2}',
            jsonb_build_object(
                'type', 'float',
                'value', ((v_new_settings #>> '{features,player_settings,next_episode_threshold_minutes_before_end_v2,value}')::numeric)
            ),
            true
        );
    end if;

    select b.settings_json into v_old_settings
    from public.profile_settings_blobs b
    where b.user_id = v_user_id
      and b.profile_id = p_profile_id
      and b.platform = p_platform
    order by b.updated_at desc
    limit 1;

    -- An identical retry cannot be a destructive shrink. Return before any
    -- audit or write while preserving normalization and authorization.
    if v_old_settings is not distinct from v_new_settings then
        return;
    end if;

    -- Serialize each changed value once and reuse it for hashing and sizing.
    v_old_text := coalesce(v_old_settings::text, '');
    v_incoming_text := coalesce(v_new_settings::text, '');
    v_old_hash := encode(
        extensions.digest(v_old_text, 'sha256'),
        'hex'
    );
    v_incoming_hash := encode(
        extensions.digest(v_incoming_text, 'sha256'),
        'hex'
    );
    v_old_size := length(v_old_text);
    v_incoming_size := length(v_incoming_text);

    -- Plugin badge settings can be most of the blob. Removing the last plugin
    -- intentionally clears that object, which is a legitimate large shrink.
    -- Only recognize it after the normalized plugins table is empty so a
    -- default/truncated settings payload cannot bypass the guard on its own.
    v_plugins_cleared :=
        jsonb_typeof(v_old_settings #> '{features,stream_badge_settings}') = 'object'
        and coalesce(v_old_settings #> '{features,stream_badge_settings}', '{}'::jsonb) <> '{}'::jsonb
        and coalesce(v_new_settings #> '{features,stream_badge_settings}', '{}'::jsonb) = '{}'::jsonb
        and not exists (
            select 1
            from public.plugins p
            where p.user_id = v_user_id
              and p.profile_id = p_profile_id
        );

    v_suspicious_shrink :=
        v_old_settings is not null
        and v_old_size >= 5000
        and v_incoming_size < (v_old_size::numeric * 0.50)
        and (
            v_incoming_size < 2500
            or (v_old_size >= 10000 and v_incoming_size < 7500)
            or (v_old_size >= 50000 and v_incoming_size < 15000)
        );

    if v_suspicious_shrink and not v_allow_settings_shrink and not v_plugins_cleared then
        raise log
            'Rejected suspicious profile settings shrink user=% profile=% platform=% old_size=% incoming_size=% user_agent=%',
            v_user_id,
            p_profile_id,
            p_platform,
            v_old_size,
            v_incoming_size,
            coalesce(v_headers->>'user-agent', v_headers->>'User-Agent');

        raise exception
            'Rejected suspicious profile settings shrink: old_size=%, incoming_size=%, platform=%, profile_id=%',
            v_old_size,
            v_incoming_size,
            p_platform,
            p_profile_id
            using errcode = '22023';
    end if;

    insert into public.sync_push_audit_logs (
        surface,
        user_id,
        auth_uid,
        profile_id,
        platform,
        request_user_agent,
        request_ip,
        request_method,
        request_path,
        old_row_count,
        incoming_row_count,
        deleted_row_count,
        old_payload_hash,
        incoming_payload_hash,
        metadata
    ) values (
        'profile_settings',
        v_user_id,
        auth.uid(),
        p_profile_id,
        p_platform,
        coalesce(v_headers->>'user-agent', v_headers->>'User-Agent'),
        nullif(
            split_part(
                coalesce(
                    v_headers->>'x-forwarded-for',
                    v_headers->>'X-Forwarded-For',
                    ''
                ),
                ',',
                1
            ),
            ''
        ),
        current_setting('request.method', true),
        current_setting('request.path', true),
        case when v_old_settings is null then 0 else 1 end,
        1,
        null,
        v_old_hash,
        v_incoming_hash,
        jsonb_build_object(
            'old_size_bytes', v_old_size,
            'incoming_size_bytes', v_incoming_size,
            'settings_changed', true,
            'shrink_guard_checked', true,
            'allow_settings_shrink', v_allow_settings_shrink,
            'plugins_cleared', v_plugins_cleared
        )
    );

    insert into public.profile_settings_blobs (
        user_id,
        profile_id,
        platform,
        settings_json,
        updated_at
    ) values (
        v_user_id,
        p_profile_id,
        p_platform,
        v_new_settings,
        now()
    )
    on conflict (user_id, profile_id, platform)
    do update set
        settings_json = excluded.settings_json,
        updated_at = now()
    where public.profile_settings_blobs.settings_json is distinct from excluded.settings_json;
end;
$_$;


--
-- Name: sync_push_profile_settings_blob(integer, jsonb, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_push_profile_settings_blob(p_profile_id integer, p_settings_json jsonb, p_platform text, p_origin_client_id text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  perform public.sync_set_origin_client_id(p_origin_client_id);
  perform public.sync_push_profile_settings_blob(p_profile_id, p_settings_json, p_platform);
end;
$$;


--
-- Name: sync_push_profiles(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_push_profiles(p_profiles jsonb) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
    perform public.sync_push_profiles(p_profiles, 4);
end;
$$;


--
-- Name: sync_push_profiles(jsonb, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_push_profiles(p_profiles jsonb, p_client_max_profiles integer) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
    v_user_id uuid := get_sync_owner();
    v_client_max_profiles integer;
begin
    if p_client_max_profiles < 1 or p_client_max_profiles > 6 then
        raise exception 'Invalid client max profiles';
    end if;

    v_client_max_profiles := p_client_max_profiles;

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
    ),
    deleted as (
        delete from public.profiles p
        where p.user_id = v_user_id
          and p.profile_index between 1 and v_client_max_profiles
          and not exists (
            select 1
            from validated v
            where v.profile_index = p.profile_index
          )
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
$$;


--
-- Name: sync_push_profiles(jsonb, integer, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_push_profiles(p_profiles jsonb, p_client_max_profiles integer, p_origin_client_id text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  perform public.sync_set_origin_client_id(p_origin_client_id);
  perform public.sync_push_profiles(p_profiles, p_client_max_profiles);
end;
$$;


--
-- Name: sync_push_provider_credentials(integer, jsonb, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_push_provider_credentials(p_profile_id integer, p_credentials jsonb, p_origin_client_id text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
    return;
end;
$$;


--
-- Name: sync_push_watch_progress(jsonb, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_push_watch_progress(p_entries jsonb, p_profile_id integer DEFAULT 1) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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
    from dedup d
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
    from dedup d
    where wp.user_id = v_owner
      and wp.profile_id = p_profile_id
      and wp.progress_key = d.progress_key
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
    from dedup
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
    returning 1
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
    returning 1
  )
  select
    (select count from dedup_count),
    (select count(*)::integer from inserted_progress),
    (select count(*)::integer from updated_progress),
    (select count(*)::integer from inserted_watched),
    (select count(*)::integer from updated_watched)
  into
    v_normalized_count,
    v_inserted_progress_count,
    v_updated_progress_count,
    v_inserted_watched_count,
    v_updated_watched_count;

end;
$$;


--
-- Name: sync_push_watch_progress(jsonb, integer, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_push_watch_progress(p_entries jsonb, p_profile_id integer, p_origin_client_id text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  perform public.sync_set_origin_client_id(p_origin_client_id);
  perform public.sync_push_watch_progress(p_entries, p_profile_id);
end;
$$;


--
-- Name: sync_push_watched_items(jsonb, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_push_watched_items(p_items jsonb, p_profile_id integer DEFAULT 1) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_user_id uuid := public.get_sync_owner();
begin
  with normalized as (
    select
      (e->>'content_id')::text as content_id,
      coalesce((e->>'content_type')::text, 'movie') as content_type,
      coalesce((e->>'title')::text, '') as title,
      (e->>'season')::integer as season,
      (e->>'episode')::integer as episode,
      coalesce((e->>'watched_at')::bigint, 0) as watched_at
    from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) as e
    where coalesce((e->>'content_id')::text, '') <> ''
  ), dedup as (
    select distinct on (content_id, coalesce(season, -1), coalesce(episode, -1))
      content_id,
      content_type,
      title,
      season,
      episode,
      watched_at
    from normalized
    order by content_id, coalesce(season, -1), coalesce(episode, -1), watched_at desc
  ), upserted as (
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
      v_user_id,
      d.content_id,
      d.content_type,
      d.title,
      d.season,
      d.episode,
      d.watched_at,
      p_profile_id
    from dedup d
    on conflict (user_id, content_id, coalesce(season, -1), coalesce(episode, -1), profile_id)
    do update set
      content_type = excluded.content_type,
      title = excluded.title,
      watched_at = excluded.watched_at
    where public.watched_items.content_type is distinct from excluded.content_type
       or public.watched_items.title is distinct from excluded.title
       or public.watched_items.watched_at is distinct from excluded.watched_at
    returning user_id, profile_id, content_id, content_type, title, season, episode, watched_at
  )
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
    user_id,
    profile_id,
    'upsert',
    content_id,
    content_type,
    title,
    season,
    episode,
    watched_at
  from upserted;
end;
$$;


--
-- Name: sync_push_watched_items(jsonb, integer, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_push_watched_items(p_items jsonb, p_profile_id integer, p_origin_client_id text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  perform public.sync_set_origin_client_id(p_origin_client_id);
  perform public.sync_push_watched_items(p_items, p_profile_id);
end;
$$;


--
-- Name: sync_restore_account_backup(jsonb, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_restore_account_backup(p_backup jsonb, p_mode text DEFAULT 'replace'::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $_$
DECLARE
    v_owner uuid;
    v_mode text;
    v_version integer;
    v_data jsonb;
    v_key text;
    v_counts jsonb;
BEGIN
    v_owner := public.get_sync_owner();

    IF v_owner IS NULL THEN
        RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '28000';
    END IF;

    v_mode := lower(COALESCE(NULLIF(btrim(p_mode), ''), 'replace'));

    IF v_mode <> 'replace' THEN
        RAISE EXCEPTION 'Unsupported restore mode: %. Only replace is supported.', v_mode
            USING ERRCODE = '22023';
    END IF;

    IF p_backup IS NULL OR jsonb_typeof(p_backup) IS DISTINCT FROM 'object' THEN
        RAISE EXCEPTION 'Invalid Nuvio backup file' USING ERRCODE = '22023';
    END IF;

    IF p_backup->>'format' IS DISTINCT FROM 'nuvio_account_backup' THEN
        RAISE EXCEPTION 'Unsupported Nuvio backup format' USING ERRCODE = '22023';
    END IF;

    IF COALESCE(p_backup->>'version', '') !~ '^[0-9]+$' THEN
        RAISE EXCEPTION 'Unsupported Nuvio backup version' USING ERRCODE = '22023';
    END IF;

    v_version := (p_backup->>'version')::integer;

    IF v_version <> 1 THEN
        RAISE EXCEPTION 'Unsupported Nuvio backup version: %', v_version
            USING ERRCODE = '22023';
    END IF;

    v_data := COALESCE(p_backup->'data', '{}'::jsonb);

    IF jsonb_typeof(v_data) IS DISTINCT FROM 'object' THEN
        RAISE EXCEPTION 'Invalid Nuvio backup data' USING ERRCODE = '22023';
    END IF;

    FOREACH v_key IN ARRAY ARRAY[
        'profiles',
        'addons',
        'plugins',
        'library_items',
        'watch_progress',
        'watched_items',
        'profile_settings_blobs',
        'home_catalog_settings',
        'collections',
        'profile_tracker_settings'
    ]
    LOOP
        IF v_data ? v_key AND jsonb_typeof(v_data->v_key) IS DISTINCT FROM 'array' THEN
            RAISE EXCEPTION 'Invalid Nuvio backup data section: %', v_key
                USING ERRCODE = '22023';
        END IF;
    END LOOP;

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
    )
    SELECT
        user_id,
        profile_id,
        'delete',
        progress_key,
        content_id,
        content_type,
        COALESCE(video_id, ''),
        season,
        episode,
        COALESCE(position, 0),
        COALESCE(duration, 0),
        COALESCE(last_watched, 0)
    FROM public.watch_progress
    WHERE user_id = v_owner;

    INSERT INTO public.watched_item_events (
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
    SELECT
        user_id,
        profile_id,
        'delete',
        content_id,
        content_type,
        COALESCE(title, ''),
        season,
        episode,
        COALESCE(watched_at, 0)
    FROM public.watched_items
    WHERE user_id = v_owner;

    DELETE FROM public.profile_tracker_settings WHERE user_id = v_owner;
    DELETE FROM public.home_catalog_settings WHERE user_id = v_owner;
    DELETE FROM public.profile_settings_blobs WHERE user_id = v_owner;
    DELETE FROM public.collections WHERE user_id = v_owner;
    DELETE FROM public.library_items WHERE user_id = v_owner;
    DELETE FROM public.watch_progress WHERE user_id = v_owner;
    DELETE FROM public.watched_items WHERE user_id = v_owner;
    DELETE FROM public.addons WHERE user_id = v_owner;
    DELETE FROM public.plugins WHERE user_id = v_owner;
    DELETE FROM public.profiles WHERE user_id = v_owner;

    INSERT INTO public.profiles (
        user_id,
        profile_index,
        profile_id,
        name,
        avatar_color_hex,
        uses_primary_addons,
        uses_primary_plugins,
        avatar_id,
        avatar_url,
        created_at,
        updated_at
    )
    SELECT
        v_owner,
        COALESCE(NULLIF(item.value->>'profile_index', '')::integer, 1),
        COALESCE(NULLIF(item.value->>'profile_id', '')::integer, NULLIF(item.value->>'profile_index', '')::integer, 1),
        COALESCE(item.value->>'name', ''),
        COALESCE(NULLIF(item.value->>'avatar_color_hex', ''), '#1E88E5'),
        CASE
            WHEN COALESCE(NULLIF(item.value->>'profile_index', '')::integer, 1) = 1 THEN false
            ELSE COALESCE((item.value->>'uses_primary_addons')::boolean, false)
        END,
        CASE
            WHEN COALESCE(NULLIF(item.value->>'profile_index', '')::integer, 1) = 1 THEN false
            ELSE COALESCE((item.value->>'uses_primary_plugins')::boolean, false)
        END,
        avatar.id,
        NULLIF(item.value->>'avatar_url', ''),
        COALESCE(NULLIF(item.value->>'created_at', '')::timestamptz, now()),
        COALESCE(NULLIF(item.value->>'updated_at', '')::timestamptz, now())
    FROM jsonb_array_elements(COALESCE(v_data->'profiles', '[]'::jsonb)) AS item(value)
    LEFT JOIN public.avatar_catalog AS avatar
        ON avatar.id = NULLIF(item.value->>'avatar_id', '')
    WHERE jsonb_typeof(item.value) = 'object';

    INSERT INTO public.addons (
        user_id,
        profile_id,
        url,
        name,
        enabled,
        sort_order,
        created_at,
        updated_at
    )
    SELECT
        v_owner,
        COALESCE(NULLIF(item.value->>'profile_id', '')::integer, 1),
        NULLIF(item.value->>'url', ''),
        NULLIF(item.value->>'name', ''),
        COALESCE((item.value->>'enabled')::boolean, true),
        COALESCE(NULLIF(item.value->>'sort_order', '')::integer, 0),
        COALESCE(NULLIF(item.value->>'created_at', '')::timestamptz, now()),
        COALESCE(NULLIF(item.value->>'updated_at', '')::timestamptz, now())
    FROM jsonb_array_elements(COALESCE(v_data->'addons', '[]'::jsonb)) AS item(value)
    WHERE jsonb_typeof(item.value) = 'object'
        AND NULLIF(item.value->>'url', '') IS NOT NULL;

    INSERT INTO public.plugins (
        user_id,
        profile_id,
        url,
        name,
        enabled,
        sort_order,
        repo_type,
        created_at,
        updated_at
    )
    SELECT
        v_owner,
        COALESCE(NULLIF(item.value->>'profile_id', '')::integer, 1),
        NULLIF(item.value->>'url', ''),
        NULLIF(item.value->>'name', ''),
        COALESCE((item.value->>'enabled')::boolean, true),
        COALESCE(NULLIF(item.value->>'sort_order', '')::integer, 0),
        NULLIF(item.value->>'repo_type', ''),
        COALESCE(NULLIF(item.value->>'created_at', '')::timestamptz, now()),
        COALESCE(NULLIF(item.value->>'updated_at', '')::timestamptz, now())
    FROM jsonb_array_elements(COALESCE(v_data->'plugins', '[]'::jsonb)) AS item(value)
    WHERE jsonb_typeof(item.value) = 'object'
        AND NULLIF(item.value->>'url', '') IS NOT NULL;

    INSERT INTO public.library_items (
        user_id,
        profile_id,
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
        added_at,
        created_at,
        updated_at
    )
    SELECT
        v_owner,
        COALESCE(NULLIF(item.value->>'profile_id', '')::integer, 1),
        NULLIF(item.value->>'content_id', ''),
        NULLIF(item.value->>'content_type', ''),
        COALESCE(item.value->>'name', ''),
        NULLIF(item.value->>'poster', ''),
        COALESCE(NULLIF(item.value->>'poster_shape', ''), 'POSTER'),
        NULLIF(item.value->>'background', ''),
        NULLIF(item.value->>'description', ''),
        NULLIF(item.value->>'release_info', ''),
        NULLIF(item.value->>'imdb_rating', '')::real,
        CASE
            WHEN jsonb_typeof(item.value->'genres') = 'array'
                THEN ARRAY(SELECT jsonb_array_elements_text(item.value->'genres'))
            ELSE '{}'::text[]
        END,
        NULLIF(item.value->>'addon_base_url', ''),
        COALESCE(NULLIF(item.value->>'added_at', '')::bigint, 0),
        COALESCE(NULLIF(item.value->>'created_at', '')::timestamptz, now()),
        COALESCE(NULLIF(item.value->>'updated_at', '')::timestamptz, now())
    FROM jsonb_array_elements(COALESCE(v_data->'library_items', '[]'::jsonb)) AS item(value)
    WHERE jsonb_typeof(item.value) = 'object'
        AND NULLIF(item.value->>'content_id', '') IS NOT NULL
        AND NULLIF(item.value->>'content_type', '') IS NOT NULL;

    INSERT INTO public.watch_progress (
        user_id,
        profile_id,
        content_id,
        content_type,
        video_id,
        season,
        episode,
        position,
        duration,
        last_watched,
        progress_key
    )
    SELECT
        v_owner,
        COALESCE(NULLIF(item.value->>'profile_id', '')::integer, 1),
        NULLIF(item.value->>'content_id', ''),
        NULLIF(item.value->>'content_type', ''),
        COALESCE(item.value->>'video_id', ''),
        NULLIF(item.value->>'season', '')::integer,
        NULLIF(item.value->>'episode', '')::integer,
        COALESCE(NULLIF(item.value->>'position', '')::bigint, 0),
        COALESCE(NULLIF(item.value->>'duration', '')::bigint, 0),
        COALESCE(NULLIF(item.value->>'last_watched', '')::bigint, 0),
        NULLIF(item.value->>'progress_key', '')
    FROM jsonb_array_elements(COALESCE(v_data->'watch_progress', '[]'::jsonb)) AS item(value)
    WHERE jsonb_typeof(item.value) = 'object'
        AND NULLIF(item.value->>'content_id', '') IS NOT NULL
        AND NULLIF(item.value->>'content_type', '') IS NOT NULL
        AND NULLIF(item.value->>'progress_key', '') IS NOT NULL;

    INSERT INTO public.watched_items (
        user_id,
        profile_id,
        content_id,
        content_type,
        title,
        season,
        episode,
        watched_at,
        created_at
    )
    SELECT
        v_owner,
        COALESCE(NULLIF(item.value->>'profile_id', '')::integer, 1),
        NULLIF(item.value->>'content_id', ''),
        COALESCE(NULLIF(item.value->>'content_type', ''), 'movie'),
        COALESCE(item.value->>'title', ''),
        NULLIF(item.value->>'season', '')::integer,
        NULLIF(item.value->>'episode', '')::integer,
        COALESCE(NULLIF(item.value->>'watched_at', '')::bigint, 0),
        COALESCE(NULLIF(item.value->>'created_at', '')::timestamptz, now())
    FROM jsonb_array_elements(COALESCE(v_data->'watched_items', '[]'::jsonb)) AS item(value)
    WHERE jsonb_typeof(item.value) = 'object'
        AND NULLIF(item.value->>'content_id', '') IS NOT NULL;

    INSERT INTO public.profile_settings_blobs (
        user_id,
        profile_id,
        platform,
        settings_json,
        created_at,
        updated_at
    )
    SELECT
        v_owner,
        COALESCE(NULLIF(item.value->>'profile_id', '')::integer, 1),
        COALESCE(NULLIF(item.value->>'platform', ''), 'tv'),
        CASE
            WHEN item.value ? 'settings_json' AND jsonb_typeof(item.value->'settings_json') <> 'null'
                THEN item.value->'settings_json'
            ELSE '{}'::jsonb
        END,
        COALESCE(NULLIF(item.value->>'created_at', '')::timestamptz, now()),
        COALESCE(NULLIF(item.value->>'updated_at', '')::timestamptz, now())
    FROM jsonb_array_elements(COALESCE(v_data->'profile_settings_blobs', '[]'::jsonb)) AS item(value)
    WHERE jsonb_typeof(item.value) = 'object';

    INSERT INTO public.home_catalog_settings (
        user_id,
        profile_id,
        platform,
        settings_json,
        updated_at
    )
    SELECT
        v_owner,
        COALESCE(NULLIF(item.value->>'profile_id', '')::integer, 1),
        COALESCE(NULLIF(item.value->>'platform', ''), 'tv'),
        CASE
            WHEN item.value ? 'settings_json' AND jsonb_typeof(item.value->'settings_json') <> 'null'
                THEN item.value->'settings_json'
            ELSE '{}'::jsonb
        END,
        COALESCE(NULLIF(item.value->>'updated_at', '')::timestamptz, now())
    FROM jsonb_array_elements(COALESCE(v_data->'home_catalog_settings', '[]'::jsonb)) AS item(value)
    WHERE jsonb_typeof(item.value) = 'object';

    INSERT INTO public.collections (
        user_id,
        profile_id,
        collections_json,
        created_at,
        updated_at
    )
    SELECT
        v_owner,
        COALESCE(NULLIF(item.value->>'profile_id', '')::integer, 1),
        CASE
            WHEN jsonb_typeof(item.value->'collections_json') = 'array'
                THEN item.value->'collections_json'
            ELSE '[]'::jsonb
        END,
        COALESCE(NULLIF(item.value->>'created_at', '')::timestamptz, now()),
        COALESCE(NULLIF(item.value->>'updated_at', '')::timestamptz, now())
    FROM jsonb_array_elements(COALESCE(v_data->'collections', '[]'::jsonb)) AS item(value)
    WHERE jsonb_typeof(item.value) = 'object';

    INSERT INTO public.profile_tracker_settings (
        user_id,
        profile_id,
        tracker,
        enabled_statuses,
        row_order,
        send_progress,
        updated_at
    )
    SELECT
        v_owner,
        COALESCE(NULLIF(item.value->>'profile_id', '')::integer, 1),
        NULLIF(item.value->>'tracker', ''),
        CASE
            WHEN jsonb_typeof(item.value->'enabled_statuses') = 'array'
                THEN ARRAY(SELECT jsonb_array_elements_text(item.value->'enabled_statuses'))
            ELSE '{}'::text[]
        END,
        CASE
            WHEN jsonb_typeof(item.value->'row_order') = 'array'
                THEN ARRAY(SELECT jsonb_array_elements_text(item.value->'row_order'))
            ELSE '{}'::text[]
        END,
        COALESCE((item.value->>'send_progress')::boolean, true),
        COALESCE(NULLIF(item.value->>'updated_at', '')::timestamptz, now())
    FROM jsonb_array_elements(COALESCE(v_data->'profile_tracker_settings', '[]'::jsonb)) AS item(value)
    WHERE jsonb_typeof(item.value) = 'object'
        AND NULLIF(item.value->>'tracker', '') IS NOT NULL;

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
    )
    SELECT
        user_id,
        profile_id,
        'upsert',
        progress_key,
        content_id,
        content_type,
        COALESCE(video_id, ''),
        season,
        episode,
        COALESCE(position, 0),
        COALESCE(duration, 0),
        COALESCE(last_watched, 0)
    FROM public.watch_progress
    WHERE user_id = v_owner;

    INSERT INTO public.watched_item_events (
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
    SELECT
        user_id,
        profile_id,
        'upsert',
        content_id,
        content_type,
        COALESCE(title, ''),
        season,
        episode,
        COALESCE(watched_at, 0)
    FROM public.watched_items
    WHERE user_id = v_owner;

    v_counts := jsonb_build_object(
        'profiles', (SELECT COUNT(*) FROM public.profiles WHERE user_id = v_owner),
        'addons', (SELECT COUNT(*) FROM public.addons WHERE user_id = v_owner),
        'plugins', (SELECT COUNT(*) FROM public.plugins WHERE user_id = v_owner),
        'library_items', (SELECT COUNT(*) FROM public.library_items WHERE user_id = v_owner),
        'watch_progress', (SELECT COUNT(*) FROM public.watch_progress WHERE user_id = v_owner),
        'watched_items', (SELECT COUNT(*) FROM public.watched_items WHERE user_id = v_owner),
        'profile_settings_blobs', (SELECT COUNT(*) FROM public.profile_settings_blobs WHERE user_id = v_owner),
        'home_catalog_settings', (SELECT COUNT(*) FROM public.home_catalog_settings WHERE user_id = v_owner),
        'collections', (SELECT COUNT(*) FROM public.collections WHERE user_id = v_owner),
        'profile_tracker_settings', (SELECT COUNT(*) FROM public.profile_tracker_settings WHERE user_id = v_owner)
    );

    RETURN jsonb_build_object(
        'restored_at', to_jsonb(now()),
        'mode', v_mode,
        'counts', v_counts,
        'sensitive_data_excluded', COALESCE(p_backup->'sensitive_data_excluded', '[]'::jsonb)
    );
END;
$_$;


--
-- Name: FUNCTION sync_restore_account_backup(p_backup jsonb, p_mode text); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.sync_restore_account_backup(p_backup jsonb, p_mode text) IS 'Restores a versioned Nuvio account backup for the authenticated sync owner in replace mode. Sensitive auth, credential, token, session, device, and audit data are not restored.';


--
-- Name: sync_set_origin_client_id(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_set_origin_client_id(p_origin_client_id text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  perform set_config(
    'app.origin_client_id',
    coalesce(left(nullif(trim(p_origin_client_id), ''), 96), ''),
    true
  );
end;
$$;


--
-- Name: upsert_profile_tracker_settings(integer, text, text[], text[], boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.upsert_profile_tracker_settings(p_profile_id integer, p_tracker text, p_enabled_statuses text[], p_row_order text[], p_send_progress boolean) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
    v_owner UUID := public.get_sync_owner();
BEGIN
    IF v_owner IS NULL THEN
        RAISE EXCEPTION 'not authenticated';
    END IF;
    IF p_tracker NOT IN ('mal','anilist','kitsu') THEN
        RAISE EXCEPTION 'bad tracker: %', p_tracker;
    END IF;

    INSERT INTO public.profile_tracker_settings
        (user_id, profile_id, tracker, enabled_statuses, row_order, send_progress, updated_at)
    VALUES
        (v_owner, p_profile_id, p_tracker,
         COALESCE(p_enabled_statuses, '{}'),
         COALESCE(p_row_order, '{}'),
         COALESCE(p_send_progress, true),
         now())
    ON CONFLICT (user_id, profile_id, tracker) DO UPDATE SET
        enabled_statuses = EXCLUDED.enabled_statuses,
        row_order = EXCLUDED.row_order,
        send_progress = EXCLUDED.send_progress,
        updated_at = now();
END;
$$;


--
-- Name: upsert_tracker_tokens(integer, text, text, text, integer, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.upsert_tracker_tokens(p_profile_id integer, p_tracker text, p_access_token text, p_refresh_token text, p_expires_in_seconds integer, p_tracker_user_id text, p_username text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
    v_owner UUID := public.get_sync_owner();
BEGIN
    IF v_owner IS NULL THEN
        RAISE EXCEPTION 'not authenticated';
    END IF;
    IF p_tracker NOT IN ('mal','anilist','kitsu') THEN
        RAISE EXCEPTION 'bad tracker: %', p_tracker;
    END IF;
    IF p_access_token IS NULL OR length(p_access_token) = 0 THEN
        RAISE EXCEPTION 'missing access_token';
    END IF;

    INSERT INTO public.user_tracker_tokens
        (user_id, profile_id, tracker, access_token, refresh_token,
         expires_at, tracker_user_id, tracker_username, updated_at)
    VALUES
        (v_owner, p_profile_id, p_tracker, p_access_token, p_refresh_token,
         CASE WHEN p_expires_in_seconds IS NULL THEN NULL
              ELSE now() + make_interval(secs => p_expires_in_seconds) END,
         p_tracker_user_id, p_username, now())
    ON CONFLICT (user_id, profile_id, tracker) DO UPDATE SET
        access_token = EXCLUDED.access_token,
        refresh_token = COALESCE(EXCLUDED.refresh_token, public.user_tracker_tokens.refresh_token),
        expires_at = EXCLUDED.expires_at,
        tracker_user_id = COALESCE(EXCLUDED.tracker_user_id, public.user_tracker_tokens.tracker_user_id),
        tracker_username = COALESCE(EXCLUDED.tracker_username, public.user_tracker_tokens.tracker_username),
        updated_at = now();
END;
$$;


--
-- Name: verify_profile_pin(integer, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.verify_profile_pin(p_profile_id integer, p_pin text) RETURNS TABLE(unlocked boolean, retry_after_seconds integer)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $_$
declare
    v_user_id uuid := get_sync_owner();
    v_pin_enabled boolean;
    v_pin_hash text;
    v_locked_until timestamp with time zone;
    v_failed_attempts integer;
    v_remaining_seconds integer;
begin
    if p_profile_id < 1 or p_profile_id > 6 then
        return query select false, 0;
        return;
    end if;

    select
        p.pin_enabled,
        p.pin_hash,
        p.pin_locked_until,
        p.failed_pin_attempts
    into
        v_pin_enabled,
        v_pin_hash,
        v_locked_until,
        v_failed_attempts
    from public.profiles p
    where p.user_id = v_user_id
      and p.profile_index = p_profile_id;

    if not found then
        return query select false, 0;
        return;
    end if;

    if v_pin_enabled is distinct from true or v_pin_hash is null then
        return query select true, 0;
        return;
    end if;

    if v_locked_until is not null and v_locked_until > now() then
        v_remaining_seconds := greatest(0, ceil(extract(epoch from (v_locked_until - now())))::integer);
        return query select false, v_remaining_seconds;
        return;
    end if;

    if p_pin ~ '^[0-9]{4}$' and extensions.crypt(p_pin, v_pin_hash) = v_pin_hash then
        update public.profiles
        set
            failed_pin_attempts = 0,
            pin_locked_until = null,
            updated_at = now()
        where user_id = v_user_id
          and profile_index = p_profile_id;

        return query select true, 0;
        return;
    end if;

    v_failed_attempts := coalesce(v_failed_attempts, 0) + 1;

    if v_failed_attempts >= 5 then
        update public.profiles
        set
            failed_pin_attempts = 0,
            pin_locked_until = now() + interval '5 minutes',
            updated_at = now()
        where user_id = v_user_id
          and profile_index = p_profile_id;

        return query select false, 300;
        return;
    end if;

    update public.profiles
    set
        failed_pin_attempts = v_failed_attempts,
        updated_at = now()
    where user_id = v_user_id
      and profile_index = p_profile_id;

    return query select false, 0;
end;
$_$;


--
-- Name: addons; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.addons (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    url text NOT NULL,
    name text,
    enabled boolean DEFAULT true NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    profile_id integer DEFAULT 1 NOT NULL
)
WITH (autovacuum_vacuum_scale_factor='0.03', autovacuum_vacuum_threshold='500', autovacuum_analyze_scale_factor='0.03', autovacuum_analyze_threshold='500', autovacuum_vacuum_cost_limit='800', autovacuum_vacuum_cost_delay='5');


--
-- Name: collections; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.collections (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    profile_id integer DEFAULT 1 NOT NULL,
    collections_json jsonb DEFAULT '[]'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT collections_profile_id_check CHECK (((profile_id >= 1) AND (profile_id <= 6)))
)
WITH (autovacuum_vacuum_scale_factor='0.02', autovacuum_vacuum_threshold='100', autovacuum_analyze_scale_factor='0.02', autovacuum_analyze_threshold='100', autovacuum_vacuum_cost_limit='800', autovacuum_vacuum_cost_delay='5');


--
-- Name: library_item_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.library_item_events (
    event_id bigint NOT NULL,
    user_id uuid NOT NULL,
    profile_id integer NOT NULL,
    operation text NOT NULL,
    content_id text NOT NULL,
    content_type text NOT NULL,
    name text DEFAULT ''::text NOT NULL,
    poster text,
    poster_shape text DEFAULT 'POSTER'::text NOT NULL,
    background text,
    description text,
    release_info text,
    imdb_rating real,
    genres text[] DEFAULT '{}'::text[] NOT NULL,
    addon_base_url text,
    added_at bigint DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT library_item_events_operation_check CHECK ((operation = ANY (ARRAY['upsert'::text, 'delete'::text])))
);


--
-- Name: library_item_events_event_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.library_item_events ALTER COLUMN event_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.library_item_events_event_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: plugins; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.plugins (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    url text NOT NULL,
    name text,
    enabled boolean DEFAULT true NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    profile_id integer DEFAULT 1 NOT NULL,
    repo_type text
);


--
-- Name: profile_settings_blobs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.profile_settings_blobs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    profile_id integer NOT NULL,
    settings_json jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    platform text DEFAULT 'tv'::text NOT NULL,
    CONSTRAINT profile_settings_blobs_profile_id_range CHECK (((profile_id >= 1) AND (profile_id <= 6)))
)
WITH (autovacuum_vacuum_scale_factor='0.02', autovacuum_vacuum_threshold='500', autovacuum_analyze_scale_factor='0.02', autovacuum_analyze_threshold='500', autovacuum_vacuum_cost_limit='800', autovacuum_vacuum_cost_delay='5');


--
-- Name: profiles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.profiles (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    profile_index integer NOT NULL,
    name text DEFAULT ''::text NOT NULL,
    avatar_color_hex text DEFAULT '#1E88E5'::text NOT NULL,
    uses_primary_addons boolean DEFAULT false NOT NULL,
    uses_primary_plugins boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    profile_id integer DEFAULT 1 NOT NULL,
    avatar_id text,
    pin_enabled boolean DEFAULT false NOT NULL,
    pin_hash text,
    pin_updated_at timestamp with time zone,
    failed_pin_attempts integer DEFAULT 0 NOT NULL,
    pin_locked_until timestamp with time zone,
    avatar_url text,
    CONSTRAINT chk_primary_no_uses_primary CHECK (((profile_index > 1) OR ((uses_primary_addons = false) AND (uses_primary_plugins = false)))),
    CONSTRAINT profiles_failed_pin_attempts_non_negative CHECK ((failed_pin_attempts >= 0))
);


--
-- Name: COLUMN profiles.avatar_url; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.profiles.avatar_url IS 'Optional custom profile avatar image URL. When set, the client uses this instead of avatar_id.';


--
-- Name: provider_credentials; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.provider_credentials (
    user_id uuid NOT NULL,
    profile_id integer DEFAULT 1 NOT NULL,
    provider text NOT NULL,
    credential_json jsonb DEFAULT '{}'::jsonb NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT provider_credentials_provider_not_blank CHECK ((btrim(provider) <> ''::text))
);


--
-- Name: sync_push_audit_logs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sync_push_audit_logs (
    id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    surface text NOT NULL,
    user_id uuid NOT NULL,
    auth_uid uuid,
    profile_id integer,
    platform text,
    request_user_agent text,
    request_ip text,
    request_method text,
    request_path text,
    old_row_count integer,
    incoming_row_count integer,
    deleted_row_count integer,
    old_payload_hash text,
    incoming_payload_hash text,
    deleted_item_hashes jsonb DEFAULT '[]'::jsonb NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT sync_push_audit_logs_surface_check CHECK ((surface = ANY (ARRAY['addons'::text, 'plugins'::text, 'profile_settings'::text])))
);


--
-- Name: tracker_tv_login_sessions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tracker_tv_login_sessions (
    code text NOT NULL,
    tracker text NOT NULL,
    device_nonce text NOT NULL,
    owner_user_id uuid NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    access_token text,
    refresh_token text,
    expires_in integer,
    tracker_user_id text,
    tracker_username text,
    redirect_base_url text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    CONSTRAINT tracker_tv_login_sessions_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'ready'::text, 'expired'::text]))),
    CONSTRAINT tracker_tv_login_sessions_tracker_check CHECK ((tracker = ANY (ARRAY['mal'::text, 'anilist'::text, 'kitsu'::text])))
);


--
-- Name: tv_login_sessions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tv_login_sessions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    code text NOT NULL,
    device_nonce text NOT NULL,
    device_name text,
    status text DEFAULT 'pending'::text NOT NULL,
    approved_user_id uuid,
    poll_interval_seconds integer DEFAULT 3 NOT NULL,
    poll_count integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    expires_at timestamp with time zone DEFAULT (now() + '00:02:00'::interval) NOT NULL,
    approved_at timestamp with time zone,
    exchanged_at timestamp with time zone,
    CONSTRAINT tv_login_sessions_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'approved'::text, 'exchanged'::text, 'expired'::text, 'cancelled'::text])))
);


--
-- Name: user_activity_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_activity_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    user_id uuid NOT NULL,
    actor_user_id uuid,
    profile_id integer,
    platform text DEFAULT 'unknown'::text NOT NULL,
    app_version text,
    device_id text,
    device_name text,
    event_type text NOT NULL,
    entity_type text,
    entity_key text,
    action text,
    status text NOT NULL,
    duration_ms integer,
    item_count integer,
    error_code text,
    error_message text,
    correlation_id uuid,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT user_activity_events_status_check CHECK ((status = ANY (ARRAY['started'::text, 'succeeded'::text, 'failed'::text, 'skipped'::text])))
);


--
-- Name: user_session_devices; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_session_devices (
    session_id uuid NOT NULL,
    user_id uuid NOT NULL,
    client_name text NOT NULL,
    client_version text,
    platform text NOT NULL,
    device_name text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    last_seen_at timestamp with time zone DEFAULT now() NOT NULL,
    installation_id text NOT NULL,
    CONSTRAINT user_session_devices_client_name_length CHECK ((char_length(client_name) <= 80)),
    CONSTRAINT user_session_devices_client_version_length CHECK ((char_length(client_version) <= 40)),
    CONSTRAINT user_session_devices_device_name_length CHECK ((char_length(device_name) <= 160)),
    CONSTRAINT user_session_devices_installation_id_format CHECK ((((char_length(installation_id) >= 16) AND (char_length(installation_id) <= 96)) AND (installation_id ~ '^[A-Za-z0-9_-]+$'::text))),
    CONSTRAINT user_session_devices_official_client CHECK ((client_name = ANY (ARRAY['Nuvio Web'::text, 'Nuvio Mobile'::text, 'Nuvio TV'::text, 'Nuvio Desktop'::text]))),
    CONSTRAINT user_session_devices_platform_length CHECK ((char_length(platform) <= 80))
);


--
-- Name: watch_progress_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.watch_progress_events (
    event_id bigint NOT NULL,
    user_id uuid NOT NULL,
    profile_id integer DEFAULT 1 NOT NULL,
    operation text NOT NULL,
    progress_key text NOT NULL,
    content_id text NOT NULL,
    content_type text NOT NULL,
    video_id text DEFAULT ''::text NOT NULL,
    season integer,
    episode integer,
    "position" bigint DEFAULT 0 NOT NULL,
    duration bigint DEFAULT 0 NOT NULL,
    last_watched bigint DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT watch_progress_events_operation_check CHECK ((operation = ANY (ARRAY['upsert'::text, 'delete'::text])))
)
WITH (autovacuum_vacuum_scale_factor='0.02', autovacuum_vacuum_threshold='1000', autovacuum_analyze_scale_factor='0.01', autovacuum_analyze_threshold='1000');


--
-- Name: watch_progress_events_event_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.watch_progress_events_event_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: watch_progress_events_event_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.watch_progress_events_event_id_seq OWNED BY public.watch_progress_events.event_id;


--
-- Name: watched_item_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.watched_item_events (
    event_id bigint NOT NULL,
    user_id uuid NOT NULL,
    profile_id integer DEFAULT 1 NOT NULL,
    operation text NOT NULL,
    content_id text NOT NULL,
    content_type text NOT NULL,
    title text DEFAULT ''::text NOT NULL,
    season integer,
    episode integer,
    watched_at bigint DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT watched_item_events_operation_check CHECK ((operation = ANY (ARRAY['upsert'::text, 'delete'::text])))
);


--
-- Name: watched_item_events_event_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.watched_item_events_event_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: watched_item_events_event_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.watched_item_events_event_id_seq OWNED BY public.watched_item_events.event_id;


--
-- Name: watch_progress_events event_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.watch_progress_events ALTER COLUMN event_id SET DEFAULT nextval('public.watch_progress_events_event_id_seq'::regclass);


--
-- Name: watched_item_events event_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.watched_item_events ALTER COLUMN event_id SET DEFAULT nextval('public.watched_item_events_event_id_seq'::regclass);


--
-- Name: addons addons_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.addons
    ADD CONSTRAINT addons_pkey PRIMARY KEY (id);


--
-- Name: avatar_catalog avatar_catalog_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.avatar_catalog
    ADD CONSTRAINT avatar_catalog_pkey PRIMARY KEY (id);


--
-- Name: collections collections_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.collections
    ADD CONSTRAINT collections_pkey PRIMARY KEY (id);


--
-- Name: collections collections_user_profile_unique; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.collections
    ADD CONSTRAINT collections_user_profile_unique UNIQUE (user_id, profile_id);


--
-- Name: home_catalog_settings home_catalog_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.home_catalog_settings
    ADD CONSTRAINT home_catalog_settings_pkey PRIMARY KEY (id);


--
-- Name: home_catalog_settings home_catalog_settings_user_profile_platform_unique; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.home_catalog_settings
    ADD CONSTRAINT home_catalog_settings_user_profile_platform_unique UNIQUE (user_id, profile_id, platform);


--
-- Name: library_item_events library_item_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.library_item_events
    ADD CONSTRAINT library_item_events_pkey PRIMARY KEY (event_id);


--
-- Name: library_items library_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.library_items
    ADD CONSTRAINT library_items_pkey PRIMARY KEY (id);


--
-- Name: library_items library_items_user_id_content_id_content_type_profile_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.library_items
    ADD CONSTRAINT library_items_user_id_content_id_content_type_profile_id_key UNIQUE (user_id, content_id, content_type, profile_id);


--
-- Name: plugins plugins_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plugins
    ADD CONSTRAINT plugins_pkey PRIMARY KEY (id);


--
-- Name: profile_settings_blobs profile_settings_blobs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profile_settings_blobs
    ADD CONSTRAINT profile_settings_blobs_pkey PRIMARY KEY (id);


--
-- Name: profile_settings_blobs profile_settings_blobs_user_profile_platform_unique; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profile_settings_blobs
    ADD CONSTRAINT profile_settings_blobs_user_profile_platform_unique UNIQUE (user_id, profile_id, platform);


--
-- Name: profile_tracker_settings profile_tracker_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profile_tracker_settings
    ADD CONSTRAINT profile_tracker_settings_pkey PRIMARY KEY (user_id, profile_id, tracker);


--
-- Name: profiles profiles_avatar_url_http_check; Type: CHECK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.profiles
    ADD CONSTRAINT profiles_avatar_url_http_check CHECK (((avatar_url IS NULL) OR ((char_length(avatar_url) <= 2048) AND (avatar_url ~* '^https?://\S+$'::text)))) NOT VALID;


--
-- Name: profiles profiles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_pkey PRIMARY KEY (id);


--
-- Name: profiles profiles_user_id_profile_index_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_user_id_profile_index_key UNIQUE (user_id, profile_index);


--
-- Name: provider_credentials provider_credentials_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.provider_credentials
    ADD CONSTRAINT provider_credentials_pkey PRIMARY KEY (user_id, profile_id, provider);


--
-- Name: sync_push_audit_logs sync_push_audit_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sync_push_audit_logs
    ADD CONSTRAINT sync_push_audit_logs_pkey PRIMARY KEY (id);


--
-- Name: tracker_tv_login_sessions tracker_tv_login_sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tracker_tv_login_sessions
    ADD CONSTRAINT tracker_tv_login_sessions_pkey PRIMARY KEY (code);


--
-- Name: tv_login_sessions tv_login_sessions_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tv_login_sessions
    ADD CONSTRAINT tv_login_sessions_code_key UNIQUE (code);


--
-- Name: tv_login_sessions tv_login_sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tv_login_sessions
    ADD CONSTRAINT tv_login_sessions_pkey PRIMARY KEY (id);


--
-- Name: user_activity_events user_activity_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_activity_events
    ADD CONSTRAINT user_activity_events_pkey PRIMARY KEY (id);


--
-- Name: user_session_devices user_session_devices_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_session_devices
    ADD CONSTRAINT user_session_devices_pkey PRIMARY KEY (session_id);


--
-- Name: user_session_devices user_session_devices_user_installation_unique; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_session_devices
    ADD CONSTRAINT user_session_devices_user_installation_unique UNIQUE (user_id, installation_id);


--
-- Name: user_tracker_tokens user_tracker_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_tracker_tokens
    ADD CONSTRAINT user_tracker_tokens_pkey PRIMARY KEY (user_id, profile_id, tracker);


--
-- Name: watch_progress_events watch_progress_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.watch_progress_events
    ADD CONSTRAINT watch_progress_events_pkey PRIMARY KEY (event_id);


--
-- Name: watch_progress watch_progress_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.watch_progress
    ADD CONSTRAINT watch_progress_pkey PRIMARY KEY (id);


--
-- Name: watch_progress watch_progress_user_profile_progress_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.watch_progress
    ADD CONSTRAINT watch_progress_user_profile_progress_key UNIQUE (user_id, profile_id, progress_key);


--
-- Name: watched_item_events watched_item_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.watched_item_events
    ADD CONSTRAINT watched_item_events_pkey PRIMARY KEY (event_id);


--
-- Name: watched_items watched_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.watched_items
    ADD CONSTRAINT watched_items_pkey PRIMARY KEY (id);


--
-- Name: addons_sort_order_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX addons_sort_order_idx ON public.addons USING btree (sort_order);


--
-- Name: idx_addons_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_addons_user_id ON public.addons USING btree (user_id);


--
-- Name: idx_addons_user_profile; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_addons_user_profile ON public.addons USING btree (user_id, profile_id);


--
-- Name: idx_avatar_catalog_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_avatar_catalog_active ON public.avatar_catalog USING btree (is_active, sort_order);


--
-- Name: idx_collections_user_profile; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_collections_user_profile ON public.collections USING btree (user_id, profile_id);


--
-- Name: idx_library_items_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_library_items_user_id ON public.library_items USING btree (user_id);


--
-- Name: idx_library_items_user_profile_added_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_library_items_user_profile_added_at ON public.library_items USING btree (user_id, profile_id, added_at DESC);


--
-- Name: idx_plugins_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_plugins_user_id ON public.plugins USING btree (user_id);


--
-- Name: idx_plugins_user_profile; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_plugins_user_profile ON public.plugins USING btree (user_id, profile_id);


--
-- Name: idx_profile_settings_blobs_user_profile; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_profile_settings_blobs_user_profile ON public.profile_settings_blobs USING btree (user_id, profile_id);


--
-- Name: idx_tv_login_sessions_approved_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tv_login_sessions_approved_user_id ON public.tv_login_sessions USING btree (approved_user_id);


--
-- Name: idx_tv_login_sessions_code; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tv_login_sessions_code ON public.tv_login_sessions USING btree (code);


--
-- Name: idx_tv_login_sessions_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tv_login_sessions_created_at ON public.tv_login_sessions USING btree (created_at);


--
-- Name: idx_tv_login_sessions_expires_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tv_login_sessions_expires_at ON public.tv_login_sessions USING btree (expires_at);


--
-- Name: idx_tv_login_sessions_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tv_login_sessions_status ON public.tv_login_sessions USING btree (status);


--
-- Name: idx_watch_progress_events_owner_profile_event; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_watch_progress_events_owner_profile_event ON public.watch_progress_events USING btree (user_id, profile_id, event_id);


--
-- Name: idx_watched_item_events_owner_profile_event; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_watched_item_events_owner_profile_event ON public.watched_item_events USING btree (user_id, profile_id, event_id);


--
-- Name: idx_watched_items_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_watched_items_unique ON public.watched_items USING btree (user_id, content_id, COALESCE(season, '-1'::integer), COALESCE(episode, '-1'::integer), profile_id);


--
-- Name: idx_watched_items_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_watched_items_user_id ON public.watched_items USING btree (user_id);


--
-- Name: idx_watched_items_user_profile_watched_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_watched_items_user_profile_watched_at ON public.watched_items USING btree (user_id, profile_id, watched_at DESC);


--
-- Name: idx_wp_user_profile_lastwatched; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_wp_user_profile_lastwatched ON public.watch_progress USING btree (user_id, profile_id, last_watched DESC);


--
-- Name: library_item_events_owner_profile_event_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX library_item_events_owner_profile_event_idx ON public.library_item_events USING btree (user_id, profile_id, event_id);


--
-- Name: plugins_sort_order_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX plugins_sort_order_idx ON public.plugins USING btree (sort_order);


--
-- Name: sync_push_audit_logs_surface_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX sync_push_audit_logs_surface_created_idx ON public.sync_push_audit_logs USING btree (surface, created_at DESC);


--
-- Name: sync_push_audit_logs_user_profile_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX sync_push_audit_logs_user_profile_created_idx ON public.sync_push_audit_logs USING btree (user_id, profile_id, created_at DESC);


--
-- Name: tracker_tv_login_sessions_expires_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tracker_tv_login_sessions_expires_idx ON public.tracker_tv_login_sessions USING btree (expires_at);


--
-- Name: tracker_tv_login_sessions_owner_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tracker_tv_login_sessions_owner_idx ON public.tracker_tv_login_sessions USING btree (owner_user_id);


--
-- Name: uq_addon_url; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_addon_url ON public.addons USING btree (user_id, md5(url), profile_id);


--
-- Name: uq_plugin_url; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_plugin_url ON public.plugins USING btree (user_id, md5(url), profile_id);


--
-- Name: user_activity_events_actor_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_activity_events_actor_created_idx ON public.user_activity_events USING btree (actor_user_id, created_at DESC);


--
-- Name: user_activity_events_correlation_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_activity_events_correlation_idx ON public.user_activity_events USING btree (correlation_id) WHERE (correlation_id IS NOT NULL);


--
-- Name: user_activity_events_created_brin_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_activity_events_created_brin_idx ON public.user_activity_events USING brin (created_at);


--
-- Name: user_activity_events_event_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_activity_events_event_created_idx ON public.user_activity_events USING btree (event_type, created_at DESC);


--
-- Name: user_activity_events_non_success_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_activity_events_non_success_status_idx ON public.user_activity_events USING btree (status, created_at DESC) WHERE (status <> 'succeeded'::text);


--
-- Name: user_activity_events_user_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_activity_events_user_created_idx ON public.user_activity_events USING btree (user_id, created_at DESC);


--
-- Name: user_activity_events_user_profile_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_activity_events_user_profile_created_idx ON public.user_activity_events USING btree (user_id, profile_id, created_at DESC);


--
-- Name: user_session_devices_user_last_seen_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_session_devices_user_last_seen_idx ON public.user_session_devices USING btree (user_id, last_seen_at DESC);


--
-- Name: library_items library_item_delta_events_trigger; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER library_item_delta_events_trigger AFTER INSERT OR DELETE OR UPDATE ON public.library_items FOR EACH ROW EXECUTE FUNCTION public.record_library_item_delta_event();


--
-- Name: profiles on_profile_created_addons; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER on_profile_created_addons AFTER INSERT ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.handle_new_profile_default_addons();


--
-- Name: addons set_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.addons FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: plugins set_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.plugins FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: watch_progress trg_fix_watch_progress_key; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_fix_watch_progress_key BEFORE INSERT OR UPDATE ON public.watch_progress FOR EACH ROW EXECUTE FUNCTION public.fix_watch_progress_key();


--
-- Name: watch_progress watch_progress_delta_events_trigger; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER watch_progress_delta_events_trigger AFTER INSERT OR DELETE OR UPDATE ON public.watch_progress FOR EACH ROW EXECUTE FUNCTION public.record_watch_progress_delta_event();


--
-- Name: addons addons_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.addons
    ADD CONSTRAINT addons_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: collections collections_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.collections
    ADD CONSTRAINT collections_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: profiles fk_profiles_avatar_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT fk_profiles_avatar_id FOREIGN KEY (avatar_id) REFERENCES public.avatar_catalog(id) ON DELETE SET NULL;


--
-- Name: library_item_events library_item_events_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.library_item_events
    ADD CONSTRAINT library_item_events_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: library_items library_items_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.library_items
    ADD CONSTRAINT library_items_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: plugins plugins_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plugins
    ADD CONSTRAINT plugins_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: profile_settings_blobs profile_settings_blobs_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profile_settings_blobs
    ADD CONSTRAINT profile_settings_blobs_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: profile_tracker_settings profile_tracker_settings_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profile_tracker_settings
    ADD CONSTRAINT profile_tracker_settings_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: profiles profiles_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: provider_credentials provider_credentials_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.provider_credentials
    ADD CONSTRAINT provider_credentials_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: tracker_tv_login_sessions tracker_tv_login_sessions_owner_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tracker_tv_login_sessions
    ADD CONSTRAINT tracker_tv_login_sessions_owner_user_id_fkey FOREIGN KEY (owner_user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: tv_login_sessions tv_login_sessions_approved_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tv_login_sessions
    ADD CONSTRAINT tv_login_sessions_approved_user_id_fkey FOREIGN KEY (approved_user_id) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: user_activity_events user_activity_events_actor_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_activity_events
    ADD CONSTRAINT user_activity_events_actor_user_id_fkey FOREIGN KEY (actor_user_id) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: user_activity_events user_activity_events_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_activity_events
    ADD CONSTRAINT user_activity_events_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: user_session_devices user_session_devices_session_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_session_devices
    ADD CONSTRAINT user_session_devices_session_id_fkey FOREIGN KEY (session_id) REFERENCES auth.sessions(id) ON DELETE CASCADE;


--
-- Name: user_session_devices user_session_devices_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_session_devices
    ADD CONSTRAINT user_session_devices_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: user_tracker_tokens user_tracker_tokens_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_tracker_tokens
    ADD CONSTRAINT user_tracker_tokens_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: watch_progress watch_progress_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.watch_progress
    ADD CONSTRAINT watch_progress_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: watched_item_events watched_item_events_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.watched_item_events
    ADD CONSTRAINT watched_item_events_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: watched_items watched_items_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.watched_items
    ADD CONSTRAINT watched_items_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: tv_login_sessions No direct access to tv_login_sessions; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "No direct access to tv_login_sessions" ON public.tv_login_sessions TO authenticated, anon USING (false) WITH CHECK (false);


--
-- Name: home_catalog_settings Users can insert own home catalog settings; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can insert own home catalog settings" ON public.home_catalog_settings FOR INSERT WITH CHECK ((user_id = auth.uid()));


--
-- Name: addons Users can manage own addons; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can manage own addons" ON public.addons USING ((( SELECT auth.uid() AS uid) = user_id)) WITH CHECK ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: collections Users can manage own collections; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can manage own collections" ON public.collections USING ((( SELECT auth.uid() AS uid) = user_id)) WITH CHECK ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: library_items Users can manage own library items; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can manage own library items" ON public.library_items USING ((( SELECT auth.uid() AS uid) = user_id)) WITH CHECK ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: plugins Users can manage own plugins; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can manage own plugins" ON public.plugins USING ((auth.uid() = user_id)) WITH CHECK ((auth.uid() = user_id));


--
-- Name: profile_settings_blobs Users can manage own profile settings blobs; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can manage own profile settings blobs" ON public.profile_settings_blobs USING ((( SELECT auth.uid() AS uid) = user_id)) WITH CHECK ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: provider_credentials Users can manage own provider credentials; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can manage own provider credentials" ON public.provider_credentials USING ((( SELECT auth.uid() AS uid) = user_id)) WITH CHECK ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: watch_progress Users can manage own watch progress; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can manage own watch progress" ON public.watch_progress USING ((( SELECT auth.uid() AS uid) = user_id)) WITH CHECK ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: watched_items Users can manage own watched items; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can manage own watched items" ON public.watched_items USING ((( SELECT auth.uid() AS uid) = user_id)) WITH CHECK ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: home_catalog_settings Users can read own home catalog settings; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can read own home catalog settings" ON public.home_catalog_settings FOR SELECT USING ((user_id = auth.uid()));


--
-- Name: user_session_devices Users can read their own session device metadata; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can read their own session device metadata" ON public.user_session_devices FOR SELECT TO authenticated USING ((user_id = auth.uid()));


--
-- Name: home_catalog_settings Users can update own home catalog settings; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can update own home catalog settings" ON public.home_catalog_settings FOR UPDATE USING ((user_id = auth.uid()));


--
-- Name: profiles Users manage own profiles; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users manage own profiles" ON public.profiles USING (public.can_access_user_data(user_id)) WITH CHECK ((user_id = public.get_sync_owner()));


--
-- Name: addons; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.addons ENABLE ROW LEVEL SECURITY;

--
-- Name: avatar_catalog; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.avatar_catalog ENABLE ROW LEVEL SECURITY;

--
-- Name: avatar_catalog avatar_catalog is world-readable; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "avatar_catalog is world-readable" ON public.avatar_catalog FOR SELECT TO authenticated, anon USING (true);


--
-- Name: collections; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.collections ENABLE ROW LEVEL SECURITY;

--
-- Name: home_catalog_settings; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.home_catalog_settings ENABLE ROW LEVEL SECURITY;

--
-- Name: library_item_events; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.library_item_events ENABLE ROW LEVEL SECURITY;

--
-- Name: library_items; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.library_items ENABLE ROW LEVEL SECURITY;

--
-- Name: plugins; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.plugins ENABLE ROW LEVEL SECURITY;

--
-- Name: profile_settings_blobs; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.profile_settings_blobs ENABLE ROW LEVEL SECURITY;

--
-- Name: profile_tracker_settings; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.profile_tracker_settings ENABLE ROW LEVEL SECURITY;

--
-- Name: profiles; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

--
-- Name: provider_credentials; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.provider_credentials ENABLE ROW LEVEL SECURITY;

--
-- Name: sync_push_audit_logs; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.sync_push_audit_logs ENABLE ROW LEVEL SECURITY;

--
-- Name: tracker_tv_login_sessions tracker_sessions_owner_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tracker_sessions_owner_read ON public.tracker_tv_login_sessions FOR SELECT USING ((auth.uid() = owner_user_id));


--
-- Name: profile_tracker_settings tracker_settings_owner_rw; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tracker_settings_owner_rw ON public.profile_tracker_settings USING ((user_id = public.get_sync_owner())) WITH CHECK ((user_id = public.get_sync_owner()));


--
-- Name: user_tracker_tokens tracker_tokens_owner_rw; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tracker_tokens_owner_rw ON public.user_tracker_tokens USING ((user_id = public.get_sync_owner())) WITH CHECK ((user_id = public.get_sync_owner()));


--
-- Name: tracker_tv_login_sessions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.tracker_tv_login_sessions ENABLE ROW LEVEL SECURITY;

--
-- Name: tv_login_sessions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.tv_login_sessions ENABLE ROW LEVEL SECURITY;

--
-- Name: user_activity_events; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.user_activity_events ENABLE ROW LEVEL SECURITY;

--
-- Name: user_session_devices; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.user_session_devices ENABLE ROW LEVEL SECURITY;

--
-- Name: user_tracker_tokens; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.user_tracker_tokens ENABLE ROW LEVEL SECURITY;

--
-- Name: watch_progress; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.watch_progress ENABLE ROW LEVEL SECURITY;

--
-- Name: watch_progress_events; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.watch_progress_events ENABLE ROW LEVEL SECURITY;

--
-- Name: watched_item_events; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.watched_item_events ENABLE ROW LEVEL SECURITY;

--
-- Name: watched_items; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.watched_items ENABLE ROW LEVEL SECURITY;

--
-- Name: SCHEMA public; Type: ACL; Schema: -; Owner: -
--

REVOKE USAGE ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO postgres;
GRANT USAGE ON SCHEMA public TO anon;
GRANT USAGE ON SCHEMA public TO authenticated;
GRANT USAGE ON SCHEMA public TO service_role;
GRANT USAGE ON SCHEMA public TO supabase_monitor;


--
-- Name: FUNCTION approve_tv_login_session(p_code text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.approve_tv_login_session(p_code text) TO anon;
GRANT ALL ON FUNCTION public.approve_tv_login_session(p_code text) TO authenticated;
GRANT ALL ON FUNCTION public.approve_tv_login_session(p_code text) TO service_role;


--
-- Name: FUNCTION can_access_user_data(p_user_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.can_access_user_data(p_user_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.can_access_user_data(p_user_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.can_access_user_data(p_user_id uuid) TO service_role;


--
-- Name: FUNCTION cleanup_anonymous_users(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.cleanup_anonymous_users() TO anon;
GRANT ALL ON FUNCTION public.cleanup_anonymous_users() TO authenticated;
GRANT ALL ON FUNCTION public.cleanup_anonymous_users() TO service_role;


--
-- Name: FUNCTION clear_profile_pin(p_profile_id integer, p_current_pin text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.clear_profile_pin(p_profile_id integer, p_current_pin text) TO anon;
GRANT ALL ON FUNCTION public.clear_profile_pin(p_profile_id integer, p_current_pin text) TO authenticated;
GRANT ALL ON FUNCTION public.clear_profile_pin(p_profile_id integer, p_current_pin text) TO service_role;


--
-- Name: FUNCTION clear_profile_pin_with_account_password(p_account_password text, p_profile_id integer); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.clear_profile_pin_with_account_password(p_account_password text, p_profile_id integer) TO anon;
GRANT ALL ON FUNCTION public.clear_profile_pin_with_account_password(p_account_password text, p_profile_id integer) TO authenticated;
GRANT ALL ON FUNCTION public.clear_profile_pin_with_account_password(p_account_password text, p_profile_id integer) TO service_role;


--
-- Name: FUNCTION clear_tracker_tokens(p_profile_id integer, p_tracker text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.clear_tracker_tokens(p_profile_id integer, p_tracker text) TO anon;
GRANT ALL ON FUNCTION public.clear_tracker_tokens(p_profile_id integer, p_tracker text) TO authenticated;
GRANT ALL ON FUNCTION public.clear_tracker_tokens(p_profile_id integer, p_tracker text) TO service_role;


--
-- Name: FUNCTION consume_tv_login_session(p_code text, p_device_nonce text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.consume_tv_login_session(p_code text, p_device_nonce text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.consume_tv_login_session(p_code text, p_device_nonce text) TO service_role;


--
-- Name: FUNCTION emit_sync_invalidation(p_user_id uuid, p_profile_id integer, p_surface text, p_metadata jsonb); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.emit_sync_invalidation(p_user_id uuid, p_profile_id integer, p_surface text, p_metadata jsonb) TO postgres;
GRANT ALL ON FUNCTION public.emit_sync_invalidation(p_user_id uuid, p_profile_id integer, p_surface text, p_metadata jsonb) TO anon;
GRANT ALL ON FUNCTION public.emit_sync_invalidation(p_user_id uuid, p_profile_id integer, p_surface text, p_metadata jsonb) TO authenticated;
GRANT ALL ON FUNCTION public.emit_sync_invalidation(p_user_id uuid, p_profile_id integer, p_surface text, p_metadata jsonb) TO service_role;


--
-- Name: FUNCTION expire_old_tv_login_sessions(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.expire_old_tv_login_sessions() FROM PUBLIC;
GRANT ALL ON FUNCTION public.expire_old_tv_login_sessions() TO anon;
GRANT ALL ON FUNCTION public.expire_old_tv_login_sessions() TO authenticated;
GRANT ALL ON FUNCTION public.expire_old_tv_login_sessions() TO service_role;


--
-- Name: FUNCTION fix_watch_progress_key(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.fix_watch_progress_key() TO anon;
GRANT ALL ON FUNCTION public.fix_watch_progress_key() TO authenticated;
GRANT ALL ON FUNCTION public.fix_watch_progress_key() TO service_role;


--
-- Name: TABLE avatar_catalog; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.avatar_catalog TO anon;
GRANT ALL ON TABLE public.avatar_catalog TO authenticated;
GRANT ALL ON TABLE public.avatar_catalog TO service_role;
GRANT SELECT ON TABLE public.avatar_catalog TO supabase_monitor;


--
-- Name: FUNCTION get_avatar_catalog(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_avatar_catalog() TO anon;
GRANT ALL ON FUNCTION public.get_avatar_catalog() TO authenticated;
GRANT ALL ON FUNCTION public.get_avatar_catalog() TO service_role;


--
-- Name: TABLE profile_tracker_settings; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.profile_tracker_settings TO anon;
GRANT ALL ON TABLE public.profile_tracker_settings TO authenticated;
GRANT ALL ON TABLE public.profile_tracker_settings TO service_role;
GRANT SELECT ON TABLE public.profile_tracker_settings TO supabase_monitor;


--
-- Name: FUNCTION get_profile_tracker_settings(p_profile_id integer); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_profile_tracker_settings(p_profile_id integer) TO anon;
GRANT ALL ON FUNCTION public.get_profile_tracker_settings(p_profile_id integer) TO authenticated;
GRANT ALL ON FUNCTION public.get_profile_tracker_settings(p_profile_id integer) TO service_role;


--
-- Name: FUNCTION get_sync_overview(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_sync_overview() TO service_role;
GRANT ALL ON FUNCTION public.get_sync_overview() TO anon;
GRANT ALL ON FUNCTION public.get_sync_overview() TO authenticated;


--
-- Name: FUNCTION get_sync_owner(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_sync_owner() TO service_role;
GRANT ALL ON FUNCTION public.get_sync_owner() TO authenticated;


--
-- Name: TABLE user_tracker_tokens; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.user_tracker_tokens TO anon;
GRANT ALL ON TABLE public.user_tracker_tokens TO authenticated;
GRANT ALL ON TABLE public.user_tracker_tokens TO service_role;
GRANT SELECT ON TABLE public.user_tracker_tokens TO supabase_monitor;


--
-- Name: FUNCTION get_tracker_tokens(p_profile_id integer); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_tracker_tokens(p_profile_id integer) TO anon;
GRANT ALL ON FUNCTION public.get_tracker_tokens(p_profile_id integer) TO authenticated;
GRANT ALL ON FUNCTION public.get_tracker_tokens(p_profile_id integer) TO service_role;


--
-- Name: FUNCTION handle_new_profile_default_addons(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.handle_new_profile_default_addons() TO anon;
GRANT ALL ON FUNCTION public.handle_new_profile_default_addons() TO authenticated;
GRANT ALL ON FUNCTION public.handle_new_profile_default_addons() TO service_role;


--
-- Name: FUNCTION handle_new_user_default_addons(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.handle_new_user_default_addons() TO anon;
GRANT ALL ON FUNCTION public.handle_new_user_default_addons() TO authenticated;
GRANT ALL ON FUNCTION public.handle_new_user_default_addons() TO service_role;


--
-- Name: FUNCTION health_ping(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.health_ping() TO anon;
GRANT ALL ON FUNCTION public.health_ping() TO authenticated;
GRANT ALL ON FUNCTION public.health_ping() TO service_role;


--
-- Name: FUNCTION list_my_sessions(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.list_my_sessions() FROM PUBLIC;
GRANT ALL ON FUNCTION public.list_my_sessions() TO postgres;
GRANT ALL ON FUNCTION public.list_my_sessions() TO authenticated;
GRANT ALL ON FUNCTION public.list_my_sessions() TO service_role;


--
-- Name: FUNCTION poll_tracker_tv_login_session(p_tracker text, p_code text, p_device_nonce text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.poll_tracker_tv_login_session(p_tracker text, p_code text, p_device_nonce text) TO anon;
GRANT ALL ON FUNCTION public.poll_tracker_tv_login_session(p_tracker text, p_code text, p_device_nonce text) TO authenticated;
GRANT ALL ON FUNCTION public.poll_tracker_tv_login_session(p_tracker text, p_code text, p_device_nonce text) TO service_role;


--
-- Name: FUNCTION poll_tv_login_session(p_code text, p_device_nonce text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.poll_tv_login_session(p_code text, p_device_nonce text) TO anon;
GRANT ALL ON FUNCTION public.poll_tv_login_session(p_code text, p_device_nonce text) TO authenticated;
GRANT ALL ON FUNCTION public.poll_tv_login_session(p_code text, p_device_nonce text) TO service_role;


--
-- Name: FUNCTION random_tv_login_code(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.random_tv_login_code() FROM PUBLIC;
GRANT ALL ON FUNCTION public.random_tv_login_code() TO anon;
GRANT ALL ON FUNCTION public.random_tv_login_code() TO authenticated;
GRANT ALL ON FUNCTION public.random_tv_login_code() TO service_role;


--
-- Name: FUNCTION record_activity_event(p_event_type text, p_status text, p_profile_id integer, p_platform text, p_app_version text, p_device_id text, p_device_name text, p_entity_type text, p_entity_key text, p_action text, p_duration_ms integer, p_item_count integer, p_error_code text, p_error_message text, p_correlation_id uuid, p_metadata jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.record_activity_event(p_event_type text, p_status text, p_profile_id integer, p_platform text, p_app_version text, p_device_id text, p_device_name text, p_entity_type text, p_entity_key text, p_action text, p_duration_ms integer, p_item_count integer, p_error_code text, p_error_message text, p_correlation_id uuid, p_metadata jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.record_activity_event(p_event_type text, p_status text, p_profile_id integer, p_platform text, p_app_version text, p_device_id text, p_device_name text, p_entity_type text, p_entity_key text, p_action text, p_duration_ms integer, p_item_count integer, p_error_code text, p_error_message text, p_correlation_id uuid, p_metadata jsonb) TO anon;
GRANT ALL ON FUNCTION public.record_activity_event(p_event_type text, p_status text, p_profile_id integer, p_platform text, p_app_version text, p_device_id text, p_device_name text, p_entity_type text, p_entity_key text, p_action text, p_duration_ms integer, p_item_count integer, p_error_code text, p_error_message text, p_correlation_id uuid, p_metadata jsonb) TO authenticated;
GRANT ALL ON FUNCTION public.record_activity_event(p_event_type text, p_status text, p_profile_id integer, p_platform text, p_app_version text, p_device_id text, p_device_name text, p_entity_type text, p_entity_key text, p_action text, p_duration_ms integer, p_item_count integer, p_error_code text, p_error_message text, p_correlation_id uuid, p_metadata jsonb) TO service_role;


--
-- Name: FUNCTION record_library_item_delta_event(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.record_library_item_delta_event() FROM PUBLIC;
GRANT ALL ON FUNCTION public.record_library_item_delta_event() TO postgres;


--
-- Name: FUNCTION record_watch_progress_delta_event(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.record_watch_progress_delta_event() FROM PUBLIC;
GRANT ALL ON FUNCTION public.record_watch_progress_delta_event() TO service_role;


--
-- Name: FUNCTION register_current_device(p_installation_id text, p_client_name text, p_client_version text, p_platform text, p_device_name text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.register_current_device(p_installation_id text, p_client_name text, p_client_version text, p_platform text, p_device_name text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.register_current_device(p_installation_id text, p_client_name text, p_client_version text, p_platform text, p_device_name text) TO postgres;
GRANT ALL ON FUNCTION public.register_current_device(p_installation_id text, p_client_name text, p_client_version text, p_platform text, p_device_name text) TO authenticated;
GRANT ALL ON FUNCTION public.register_current_device(p_installation_id text, p_client_name text, p_client_version text, p_platform text, p_device_name text) TO service_role;


--
-- Name: FUNCTION register_current_session(p_client_name text, p_client_version text, p_platform text, p_device_name text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.register_current_session(p_client_name text, p_client_version text, p_platform text, p_device_name text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.register_current_session(p_client_name text, p_client_version text, p_platform text, p_device_name text) TO postgres;
GRANT ALL ON FUNCTION public.register_current_session(p_client_name text, p_client_version text, p_platform text, p_device_name text) TO authenticated;
GRANT ALL ON FUNCTION public.register_current_session(p_client_name text, p_client_version text, p_platform text, p_device_name text) TO service_role;


--
-- Name: FUNCTION revoke_my_session(p_session_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.revoke_my_session(p_session_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.revoke_my_session(p_session_id uuid) TO postgres;
GRANT ALL ON FUNCTION public.revoke_my_session(p_session_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.revoke_my_session(p_session_id uuid) TO service_role;


--
-- Name: FUNCTION set_profile_pin(p_profile_id integer, p_pin text, p_current_pin text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.set_profile_pin(p_profile_id integer, p_pin text, p_current_pin text) TO anon;
GRANT ALL ON FUNCTION public.set_profile_pin(p_profile_id integer, p_pin text, p_current_pin text) TO authenticated;
GRANT ALL ON FUNCTION public.set_profile_pin(p_profile_id integer, p_pin text, p_current_pin text) TO service_role;


--
-- Name: FUNCTION set_updated_at(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.set_updated_at() TO anon;
GRANT ALL ON FUNCTION public.set_updated_at() TO authenticated;
GRANT ALL ON FUNCTION public.set_updated_at() TO service_role;


--
-- Name: FUNCTION start_tracker_tv_login_session(p_tracker text, p_device_nonce text, p_redirect_base_url text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.start_tracker_tv_login_session(p_tracker text, p_device_nonce text, p_redirect_base_url text) TO anon;
GRANT ALL ON FUNCTION public.start_tracker_tv_login_session(p_tracker text, p_device_nonce text, p_redirect_base_url text) TO authenticated;
GRANT ALL ON FUNCTION public.start_tracker_tv_login_session(p_tracker text, p_device_nonce text, p_redirect_base_url text) TO service_role;


--
-- Name: FUNCTION start_tv_login_session(p_device_nonce text, p_redirect_base_url text, p_device_name text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.start_tv_login_session(p_device_nonce text, p_redirect_base_url text, p_device_name text) TO anon;
GRANT ALL ON FUNCTION public.start_tv_login_session(p_device_nonce text, p_redirect_base_url text, p_device_name text) TO authenticated;
GRANT ALL ON FUNCTION public.start_tv_login_session(p_device_nonce text, p_redirect_base_url text, p_device_name text) TO service_role;


--
-- Name: FUNCTION sync_current_origin_client_id(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.sync_current_origin_client_id() TO postgres;
GRANT ALL ON FUNCTION public.sync_current_origin_client_id() TO anon;
GRANT ALL ON FUNCTION public.sync_current_origin_client_id() TO authenticated;
GRANT ALL ON FUNCTION public.sync_current_origin_client_id() TO service_role;


--
-- Name: FUNCTION sync_delete_library_items(p_keys jsonb, p_profile_id integer, p_origin_client_id text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.sync_delete_library_items(p_keys jsonb, p_profile_id integer, p_origin_client_id text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.sync_delete_library_items(p_keys jsonb, p_profile_id integer, p_origin_client_id text) TO postgres;
GRANT ALL ON FUNCTION public.sync_delete_library_items(p_keys jsonb, p_profile_id integer, p_origin_client_id text) TO authenticated;
GRANT ALL ON FUNCTION public.sync_delete_library_items(p_keys jsonb, p_profile_id integer, p_origin_client_id text) TO service_role;


--
-- Name: FUNCTION sync_delete_profile_data(p_profile_id integer); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.sync_delete_profile_data(p_profile_id integer) TO service_role;
GRANT ALL ON FUNCTION public.sync_delete_profile_data(p_profile_id integer) TO anon;
GRANT ALL ON FUNCTION public.sync_delete_profile_data(p_profile_id integer) TO authenticated;


--
-- Name: FUNCTION sync_delete_profile_data(p_profile_id integer, p_origin_client_id text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.sync_delete_profile_data(p_profile_id integer, p_origin_client_id text) TO postgres;
GRANT ALL ON FUNCTION public.sync_delete_profile_data(p_profile_id integer, p_origin_client_id text) TO anon;
GRANT ALL ON FUNCTION public.sync_delete_profile_data(p_profile_id integer, p_origin_client_id text) TO authenticated;
GRANT ALL ON FUNCTION public.sync_delete_profile_data(p_profile_id integer, p_origin_client_id text) TO service_role;


--
-- Name: FUNCTION sync_delete_provider_credentials(p_profile_id integer, p_provider text, p_origin_client_id text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.sync_delete_provider_credentials(p_profile_id integer, p_provider text, p_origin_client_id text) TO postgres;
GRANT ALL ON FUNCTION public.sync_delete_provider_credentials(p_profile_id integer, p_provider text, p_origin_client_id text) TO anon;
GRANT ALL ON FUNCTION public.sync_delete_provider_credentials(p_profile_id integer, p_provider text, p_origin_client_id text) TO authenticated;
GRANT ALL ON FUNCTION public.sync_delete_provider_credentials(p_profile_id integer, p_provider text, p_origin_client_id text) TO service_role;


--
-- Name: FUNCTION sync_delete_watch_progress(p_keys jsonb, p_profile_id integer); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.sync_delete_watch_progress(p_keys jsonb, p_profile_id integer) TO service_role;
GRANT ALL ON FUNCTION public.sync_delete_watch_progress(p_keys jsonb, p_profile_id integer) TO anon;
GRANT ALL ON FUNCTION public.sync_delete_watch_progress(p_keys jsonb, p_profile_id integer) TO authenticated;


--
-- Name: FUNCTION sync_delete_watch_progress(p_progress_key text, p_profile_id integer); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.sync_delete_watch_progress(p_progress_key text, p_profile_id integer) TO service_role;
GRANT ALL ON FUNCTION public.sync_delete_watch_progress(p_progress_key text, p_profile_id integer) TO anon;
GRANT ALL ON FUNCTION public.sync_delete_watch_progress(p_progress_key text, p_profile_id integer) TO authenticated;


--
-- Name: FUNCTION sync_delete_watch_progress(p_keys jsonb, p_profile_id integer, p_origin_client_id text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.sync_delete_watch_progress(p_keys jsonb, p_profile_id integer, p_origin_client_id text) TO postgres;
GRANT ALL ON FUNCTION public.sync_delete_watch_progress(p_keys jsonb, p_profile_id integer, p_origin_client_id text) TO anon;
GRANT ALL ON FUNCTION public.sync_delete_watch_progress(p_keys jsonb, p_profile_id integer, p_origin_client_id text) TO authenticated;
GRANT ALL ON FUNCTION public.sync_delete_watch_progress(p_keys jsonb, p_profile_id integer, p_origin_client_id text) TO service_role;


--
-- Name: FUNCTION sync_delete_watched_items(p_keys jsonb, p_profile_id integer); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.sync_delete_watched_items(p_keys jsonb, p_profile_id integer) TO service_role;
GRANT ALL ON FUNCTION public.sync_delete_watched_items(p_keys jsonb, p_profile_id integer) TO anon;
GRANT ALL ON FUNCTION public.sync_delete_watched_items(p_keys jsonb, p_profile_id integer) TO authenticated;


--
-- Name: FUNCTION sync_delete_watched_items(p_keys jsonb, p_profile_id integer, p_origin_client_id text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.sync_delete_watched_items(p_keys jsonb, p_profile_id integer, p_origin_client_id text) TO postgres;
GRANT ALL ON FUNCTION public.sync_delete_watched_items(p_keys jsonb, p_profile_id integer, p_origin_client_id text) TO anon;
GRANT ALL ON FUNCTION public.sync_delete_watched_items(p_keys jsonb, p_profile_id integer, p_origin_client_id text) TO authenticated;
GRANT ALL ON FUNCTION public.sync_delete_watched_items(p_keys jsonb, p_profile_id integer, p_origin_client_id text) TO service_role;


--
-- Name: FUNCTION sync_export_account_backup(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.sync_export_account_backup() FROM PUBLIC;
GRANT ALL ON FUNCTION public.sync_export_account_backup() TO postgres;
GRANT ALL ON FUNCTION public.sync_export_account_backup() TO anon;
GRANT ALL ON FUNCTION public.sync_export_account_backup() TO authenticated;
GRANT ALL ON FUNCTION public.sync_export_account_backup() TO service_role;


--
-- Name: FUNCTION sync_get_library_delta_cursor(p_profile_id integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.sync_get_library_delta_cursor(p_profile_id integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.sync_get_library_delta_cursor(p_profile_id integer) TO postgres;
GRANT ALL ON FUNCTION public.sync_get_library_delta_cursor(p_profile_id integer) TO authenticated;
GRANT ALL ON FUNCTION public.sync_get_library_delta_cursor(p_profile_id integer) TO service_role;


--
-- Name: FUNCTION sync_get_watch_progress_delta_cursor(p_profile_id integer); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.sync_get_watch_progress_delta_cursor(p_profile_id integer) TO service_role;
GRANT ALL ON FUNCTION public.sync_get_watch_progress_delta_cursor(p_profile_id integer) TO authenticated;


--
-- Name: FUNCTION sync_get_watched_items_delta_cursor(p_profile_id integer); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.sync_get_watched_items_delta_cursor(p_profile_id integer) TO service_role;
GRANT ALL ON FUNCTION public.sync_get_watched_items_delta_cursor(p_profile_id integer) TO authenticated;


--
-- Name: FUNCTION sync_pull_collections(p_profile_id integer); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.sync_pull_collections(p_profile_id integer) TO service_role;
GRANT ALL ON FUNCTION public.sync_pull_collections(p_profile_id integer) TO anon;
GRANT ALL ON FUNCTION public.sync_pull_collections(p_profile_id integer) TO authenticated;


--
-- Name: TABLE home_catalog_settings; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.home_catalog_settings TO anon;
GRANT ALL ON TABLE public.home_catalog_settings TO authenticated;
GRANT ALL ON TABLE public.home_catalog_settings TO service_role;
GRANT SELECT ON TABLE public.home_catalog_settings TO supabase_monitor;


--
-- Name: FUNCTION sync_pull_home_catalog_settings(p_profile_id integer); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.sync_pull_home_catalog_settings(p_profile_id integer) TO service_role;
GRANT ALL ON FUNCTION public.sync_pull_home_catalog_settings(p_profile_id integer) TO anon;
GRANT ALL ON FUNCTION public.sync_pull_home_catalog_settings(p_profile_id integer) TO authenticated;


--
-- Name: FUNCTION sync_pull_home_catalog_settings(p_profile_id integer, p_platform text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.sync_pull_home_catalog_settings(p_profile_id integer, p_platform text) TO service_role;
GRANT ALL ON FUNCTION public.sync_pull_home_catalog_settings(p_profile_id integer, p_platform text) TO anon;
GRANT ALL ON FUNCTION public.sync_pull_home_catalog_settings(p_profile_id integer, p_platform text) TO authenticated;


--
-- Name: TABLE library_items; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.library_items TO anon;
GRANT ALL ON TABLE public.library_items TO authenticated;
GRANT ALL ON TABLE public.library_items TO service_role;
GRANT SELECT ON TABLE public.library_items TO supabase_monitor;


--
-- Name: FUNCTION sync_pull_library(p_profile_id integer, p_limit integer, p_offset integer); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.sync_pull_library(p_profile_id integer, p_limit integer, p_offset integer) TO service_role;
GRANT ALL ON FUNCTION public.sync_pull_library(p_profile_id integer, p_limit integer, p_offset integer) TO anon;
GRANT ALL ON FUNCTION public.sync_pull_library(p_profile_id integer, p_limit integer, p_offset integer) TO authenticated;


--
-- Name: FUNCTION sync_pull_library_delta(p_profile_id integer, p_since_event_id bigint, p_limit integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.sync_pull_library_delta(p_profile_id integer, p_since_event_id bigint, p_limit integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.sync_pull_library_delta(p_profile_id integer, p_since_event_id bigint, p_limit integer) TO postgres;
GRANT ALL ON FUNCTION public.sync_pull_library_delta(p_profile_id integer, p_since_event_id bigint, p_limit integer) TO authenticated;
GRANT ALL ON FUNCTION public.sync_pull_library_delta(p_profile_id integer, p_since_event_id bigint, p_limit integer) TO service_role;


--
-- Name: FUNCTION sync_pull_profile_locks(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.sync_pull_profile_locks() TO service_role;
GRANT ALL ON FUNCTION public.sync_pull_profile_locks() TO anon;
GRANT ALL ON FUNCTION public.sync_pull_profile_locks() TO authenticated;


--
-- Name: FUNCTION sync_pull_profile_settings_blob(p_profile_id integer); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.sync_pull_profile_settings_blob(p_profile_id integer) TO service_role;
GRANT ALL ON FUNCTION public.sync_pull_profile_settings_blob(p_profile_id integer) TO anon;
GRANT ALL ON FUNCTION public.sync_pull_profile_settings_blob(p_profile_id integer) TO authenticated;


--
-- Name: FUNCTION sync_pull_profile_settings_blob(p_profile_id integer, p_platform text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.sync_pull_profile_settings_blob(p_profile_id integer, p_platform text) TO service_role;
GRANT ALL ON FUNCTION public.sync_pull_profile_settings_blob(p_profile_id integer, p_platform text) TO anon;
GRANT ALL ON FUNCTION public.sync_pull_profile_settings_blob(p_profile_id integer, p_platform text) TO authenticated;


--
-- Name: FUNCTION sync_pull_profiles(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.sync_pull_profiles() TO service_role;
GRANT ALL ON FUNCTION public.sync_pull_profiles() TO anon;
GRANT ALL ON FUNCTION public.sync_pull_profiles() TO authenticated;


--
-- Name: FUNCTION sync_pull_provider_credentials(p_profile_id integer); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.sync_pull_provider_credentials(p_profile_id integer) TO postgres;
GRANT ALL ON FUNCTION public.sync_pull_provider_credentials(p_profile_id integer) TO anon;
GRANT ALL ON FUNCTION public.sync_pull_provider_credentials(p_profile_id integer) TO authenticated;
GRANT ALL ON FUNCTION public.sync_pull_provider_credentials(p_profile_id integer) TO service_role;


--
-- Name: TABLE watch_progress; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.watch_progress TO anon;
GRANT ALL ON TABLE public.watch_progress TO authenticated;
GRANT ALL ON TABLE public.watch_progress TO service_role;
GRANT SELECT ON TABLE public.watch_progress TO supabase_monitor;


--
-- Name: FUNCTION sync_pull_watch_progress(p_profile_id integer, p_since_last_watched bigint, p_limit integer); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.sync_pull_watch_progress(p_profile_id integer, p_since_last_watched bigint, p_limit integer) TO service_role;
GRANT ALL ON FUNCTION public.sync_pull_watch_progress(p_profile_id integer, p_since_last_watched bigint, p_limit integer) TO anon;
GRANT ALL ON FUNCTION public.sync_pull_watch_progress(p_profile_id integer, p_since_last_watched bigint, p_limit integer) TO authenticated;


--
-- Name: FUNCTION sync_pull_watch_progress_delta(p_profile_id integer, p_since_event_id bigint, p_limit integer); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.sync_pull_watch_progress_delta(p_profile_id integer, p_since_event_id bigint, p_limit integer) TO service_role;
GRANT ALL ON FUNCTION public.sync_pull_watch_progress_delta(p_profile_id integer, p_since_event_id bigint, p_limit integer) TO authenticated;


--
-- Name: TABLE watched_items; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.watched_items TO anon;
GRANT ALL ON TABLE public.watched_items TO authenticated;
GRANT ALL ON TABLE public.watched_items TO service_role;
GRANT SELECT ON TABLE public.watched_items TO supabase_monitor;


--
-- Name: FUNCTION sync_pull_watched_items(p_profile_id integer, p_page integer, p_page_size integer); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.sync_pull_watched_items(p_profile_id integer, p_page integer, p_page_size integer) TO service_role;
GRANT ALL ON FUNCTION public.sync_pull_watched_items(p_profile_id integer, p_page integer, p_page_size integer) TO anon;
GRANT ALL ON FUNCTION public.sync_pull_watched_items(p_profile_id integer, p_page integer, p_page_size integer) TO authenticated;


--
-- Name: FUNCTION sync_pull_watched_items_delta(p_profile_id integer, p_since_event_id bigint, p_limit integer); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.sync_pull_watched_items_delta(p_profile_id integer, p_since_event_id bigint, p_limit integer) TO service_role;
GRANT ALL ON FUNCTION public.sync_pull_watched_items_delta(p_profile_id integer, p_since_event_id bigint, p_limit integer) TO authenticated;


--
-- Name: FUNCTION sync_push_addons(p_addons jsonb, p_profile_id integer); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.sync_push_addons(p_addons jsonb, p_profile_id integer) TO service_role;
GRANT ALL ON FUNCTION public.sync_push_addons(p_addons jsonb, p_profile_id integer) TO authenticated;


--
-- Name: FUNCTION sync_push_addons(p_addons jsonb, p_profile_id integer, p_origin_client_id text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.sync_push_addons(p_addons jsonb, p_profile_id integer, p_origin_client_id text) TO postgres;
GRANT ALL ON FUNCTION public.sync_push_addons(p_addons jsonb, p_profile_id integer, p_origin_client_id text) TO anon;
GRANT ALL ON FUNCTION public.sync_push_addons(p_addons jsonb, p_profile_id integer, p_origin_client_id text) TO authenticated;
GRANT ALL ON FUNCTION public.sync_push_addons(p_addons jsonb, p_profile_id integer, p_origin_client_id text) TO service_role;


--
-- Name: FUNCTION sync_push_collections(p_profile_id integer, p_collections_json jsonb); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.sync_push_collections(p_profile_id integer, p_collections_json jsonb) TO service_role;
GRANT ALL ON FUNCTION public.sync_push_collections(p_profile_id integer, p_collections_json jsonb) TO anon;
GRANT ALL ON FUNCTION public.sync_push_collections(p_profile_id integer, p_collections_json jsonb) TO authenticated;


--
-- Name: FUNCTION sync_push_collections(p_profile_id integer, p_collections_json jsonb, p_origin_client_id text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.sync_push_collections(p_profile_id integer, p_collections_json jsonb, p_origin_client_id text) TO postgres;
GRANT ALL ON FUNCTION public.sync_push_collections(p_profile_id integer, p_collections_json jsonb, p_origin_client_id text) TO anon;
GRANT ALL ON FUNCTION public.sync_push_collections(p_profile_id integer, p_collections_json jsonb, p_origin_client_id text) TO authenticated;
GRANT ALL ON FUNCTION public.sync_push_collections(p_profile_id integer, p_collections_json jsonb, p_origin_client_id text) TO service_role;


--
-- Name: FUNCTION sync_push_home_catalog_settings(p_profile_id integer, p_settings_json jsonb); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.sync_push_home_catalog_settings(p_profile_id integer, p_settings_json jsonb) TO service_role;
GRANT ALL ON FUNCTION public.sync_push_home_catalog_settings(p_profile_id integer, p_settings_json jsonb) TO anon;
GRANT ALL ON FUNCTION public.sync_push_home_catalog_settings(p_profile_id integer, p_settings_json jsonb) TO authenticated;


--
-- Name: FUNCTION sync_push_home_catalog_settings(p_profile_id integer, p_settings_json jsonb, p_platform text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.sync_push_home_catalog_settings(p_profile_id integer, p_settings_json jsonb, p_platform text) TO service_role;
GRANT ALL ON FUNCTION public.sync_push_home_catalog_settings(p_profile_id integer, p_settings_json jsonb, p_platform text) TO anon;
GRANT ALL ON FUNCTION public.sync_push_home_catalog_settings(p_profile_id integer, p_settings_json jsonb, p_platform text) TO authenticated;


--
-- Name: FUNCTION sync_push_home_catalog_settings(p_profile_id integer, p_settings_json jsonb, p_platform text, p_origin_client_id text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.sync_push_home_catalog_settings(p_profile_id integer, p_settings_json jsonb, p_platform text, p_origin_client_id text) TO postgres;
GRANT ALL ON FUNCTION public.sync_push_home_catalog_settings(p_profile_id integer, p_settings_json jsonb, p_platform text, p_origin_client_id text) TO anon;
GRANT ALL ON FUNCTION public.sync_push_home_catalog_settings(p_profile_id integer, p_settings_json jsonb, p_platform text, p_origin_client_id text) TO authenticated;
GRANT ALL ON FUNCTION public.sync_push_home_catalog_settings(p_profile_id integer, p_settings_json jsonb, p_platform text, p_origin_client_id text) TO service_role;


--
-- Name: FUNCTION sync_push_library(p_items jsonb, p_profile_id integer); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.sync_push_library(p_items jsonb, p_profile_id integer) TO service_role;
GRANT ALL ON FUNCTION public.sync_push_library(p_items jsonb, p_profile_id integer) TO anon;
GRANT ALL ON FUNCTION public.sync_push_library(p_items jsonb, p_profile_id integer) TO authenticated;


--
-- Name: FUNCTION sync_push_library(p_items jsonb, p_profile_id integer, p_origin_client_id text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.sync_push_library(p_items jsonb, p_profile_id integer, p_origin_client_id text) TO postgres;
GRANT ALL ON FUNCTION public.sync_push_library(p_items jsonb, p_profile_id integer, p_origin_client_id text) TO anon;
GRANT ALL ON FUNCTION public.sync_push_library(p_items jsonb, p_profile_id integer, p_origin_client_id text) TO authenticated;
GRANT ALL ON FUNCTION public.sync_push_library(p_items jsonb, p_profile_id integer, p_origin_client_id text) TO service_role;


--
-- Name: FUNCTION sync_push_library_items(p_items jsonb, p_profile_id integer, p_origin_client_id text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.sync_push_library_items(p_items jsonb, p_profile_id integer, p_origin_client_id text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.sync_push_library_items(p_items jsonb, p_profile_id integer, p_origin_client_id text) TO postgres;
GRANT ALL ON FUNCTION public.sync_push_library_items(p_items jsonb, p_profile_id integer, p_origin_client_id text) TO authenticated;
GRANT ALL ON FUNCTION public.sync_push_library_items(p_items jsonb, p_profile_id integer, p_origin_client_id text) TO service_role;


--
-- Name: FUNCTION sync_push_plugins(p_plugins jsonb, p_profile_id integer); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.sync_push_plugins(p_plugins jsonb, p_profile_id integer) TO service_role;
GRANT ALL ON FUNCTION public.sync_push_plugins(p_plugins jsonb, p_profile_id integer) TO authenticated;


--
-- Name: FUNCTION sync_push_plugins(p_plugins jsonb, p_profile_id integer, p_origin_client_id text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.sync_push_plugins(p_plugins jsonb, p_profile_id integer, p_origin_client_id text) TO postgres;
GRANT ALL ON FUNCTION public.sync_push_plugins(p_plugins jsonb, p_profile_id integer, p_origin_client_id text) TO anon;
GRANT ALL ON FUNCTION public.sync_push_plugins(p_plugins jsonb, p_profile_id integer, p_origin_client_id text) TO authenticated;
GRANT ALL ON FUNCTION public.sync_push_plugins(p_plugins jsonb, p_profile_id integer, p_origin_client_id text) TO service_role;


--
-- Name: FUNCTION sync_push_profile_settings_blob(p_profile_id integer, p_settings_json jsonb); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.sync_push_profile_settings_blob(p_profile_id integer, p_settings_json jsonb) TO service_role;
GRANT ALL ON FUNCTION public.sync_push_profile_settings_blob(p_profile_id integer, p_settings_json jsonb) TO anon;
GRANT ALL ON FUNCTION public.sync_push_profile_settings_blob(p_profile_id integer, p_settings_json jsonb) TO authenticated;


--
-- Name: FUNCTION sync_push_profile_settings_blob(p_profile_id integer, p_settings_json jsonb, p_platform text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.sync_push_profile_settings_blob(p_profile_id integer, p_settings_json jsonb, p_platform text) TO service_role;
GRANT ALL ON FUNCTION public.sync_push_profile_settings_blob(p_profile_id integer, p_settings_json jsonb, p_platform text) TO anon;
GRANT ALL ON FUNCTION public.sync_push_profile_settings_blob(p_profile_id integer, p_settings_json jsonb, p_platform text) TO authenticated;


--
-- Name: FUNCTION sync_push_profile_settings_blob(p_profile_id integer, p_settings_json jsonb, p_platform text, p_origin_client_id text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.sync_push_profile_settings_blob(p_profile_id integer, p_settings_json jsonb, p_platform text, p_origin_client_id text) TO postgres;
GRANT ALL ON FUNCTION public.sync_push_profile_settings_blob(p_profile_id integer, p_settings_json jsonb, p_platform text, p_origin_client_id text) TO anon;
GRANT ALL ON FUNCTION public.sync_push_profile_settings_blob(p_profile_id integer, p_settings_json jsonb, p_platform text, p_origin_client_id text) TO authenticated;
GRANT ALL ON FUNCTION public.sync_push_profile_settings_blob(p_profile_id integer, p_settings_json jsonb, p_platform text, p_origin_client_id text) TO service_role;


--
-- Name: FUNCTION sync_push_profiles(p_profiles jsonb); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.sync_push_profiles(p_profiles jsonb) TO service_role;
GRANT ALL ON FUNCTION public.sync_push_profiles(p_profiles jsonb) TO anon;
GRANT ALL ON FUNCTION public.sync_push_profiles(p_profiles jsonb) TO authenticated;


--
-- Name: FUNCTION sync_push_profiles(p_profiles jsonb, p_client_max_profiles integer); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.sync_push_profiles(p_profiles jsonb, p_client_max_profiles integer) TO service_role;
GRANT ALL ON FUNCTION public.sync_push_profiles(p_profiles jsonb, p_client_max_profiles integer) TO anon;
GRANT ALL ON FUNCTION public.sync_push_profiles(p_profiles jsonb, p_client_max_profiles integer) TO authenticated;


--
-- Name: FUNCTION sync_push_profiles(p_profiles jsonb, p_client_max_profiles integer, p_origin_client_id text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.sync_push_profiles(p_profiles jsonb, p_client_max_profiles integer, p_origin_client_id text) TO postgres;
GRANT ALL ON FUNCTION public.sync_push_profiles(p_profiles jsonb, p_client_max_profiles integer, p_origin_client_id text) TO anon;
GRANT ALL ON FUNCTION public.sync_push_profiles(p_profiles jsonb, p_client_max_profiles integer, p_origin_client_id text) TO authenticated;
GRANT ALL ON FUNCTION public.sync_push_profiles(p_profiles jsonb, p_client_max_profiles integer, p_origin_client_id text) TO service_role;


--
-- Name: FUNCTION sync_push_provider_credentials(p_profile_id integer, p_credentials jsonb, p_origin_client_id text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.sync_push_provider_credentials(p_profile_id integer, p_credentials jsonb, p_origin_client_id text) TO postgres;
GRANT ALL ON FUNCTION public.sync_push_provider_credentials(p_profile_id integer, p_credentials jsonb, p_origin_client_id text) TO anon;
GRANT ALL ON FUNCTION public.sync_push_provider_credentials(p_profile_id integer, p_credentials jsonb, p_origin_client_id text) TO authenticated;
GRANT ALL ON FUNCTION public.sync_push_provider_credentials(p_profile_id integer, p_credentials jsonb, p_origin_client_id text) TO service_role;


--
-- Name: FUNCTION sync_push_watch_progress(p_entries jsonb, p_profile_id integer); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.sync_push_watch_progress(p_entries jsonb, p_profile_id integer) TO service_role;
GRANT ALL ON FUNCTION public.sync_push_watch_progress(p_entries jsonb, p_profile_id integer) TO anon;
GRANT ALL ON FUNCTION public.sync_push_watch_progress(p_entries jsonb, p_profile_id integer) TO authenticated;


--
-- Name: FUNCTION sync_push_watch_progress(p_entries jsonb, p_profile_id integer, p_origin_client_id text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.sync_push_watch_progress(p_entries jsonb, p_profile_id integer, p_origin_client_id text) TO postgres;
GRANT ALL ON FUNCTION public.sync_push_watch_progress(p_entries jsonb, p_profile_id integer, p_origin_client_id text) TO anon;
GRANT ALL ON FUNCTION public.sync_push_watch_progress(p_entries jsonb, p_profile_id integer, p_origin_client_id text) TO authenticated;
GRANT ALL ON FUNCTION public.sync_push_watch_progress(p_entries jsonb, p_profile_id integer, p_origin_client_id text) TO service_role;


--
-- Name: FUNCTION sync_push_watched_items(p_items jsonb, p_profile_id integer); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.sync_push_watched_items(p_items jsonb, p_profile_id integer) TO service_role;
GRANT ALL ON FUNCTION public.sync_push_watched_items(p_items jsonb, p_profile_id integer) TO anon;
GRANT ALL ON FUNCTION public.sync_push_watched_items(p_items jsonb, p_profile_id integer) TO authenticated;


--
-- Name: FUNCTION sync_push_watched_items(p_items jsonb, p_profile_id integer, p_origin_client_id text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.sync_push_watched_items(p_items jsonb, p_profile_id integer, p_origin_client_id text) TO postgres;
GRANT ALL ON FUNCTION public.sync_push_watched_items(p_items jsonb, p_profile_id integer, p_origin_client_id text) TO anon;
GRANT ALL ON FUNCTION public.sync_push_watched_items(p_items jsonb, p_profile_id integer, p_origin_client_id text) TO authenticated;
GRANT ALL ON FUNCTION public.sync_push_watched_items(p_items jsonb, p_profile_id integer, p_origin_client_id text) TO service_role;


--
-- Name: FUNCTION sync_restore_account_backup(p_backup jsonb, p_mode text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.sync_restore_account_backup(p_backup jsonb, p_mode text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.sync_restore_account_backup(p_backup jsonb, p_mode text) TO postgres;
GRANT ALL ON FUNCTION public.sync_restore_account_backup(p_backup jsonb, p_mode text) TO anon;
GRANT ALL ON FUNCTION public.sync_restore_account_backup(p_backup jsonb, p_mode text) TO authenticated;
GRANT ALL ON FUNCTION public.sync_restore_account_backup(p_backup jsonb, p_mode text) TO service_role;


--
-- Name: FUNCTION sync_set_origin_client_id(p_origin_client_id text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.sync_set_origin_client_id(p_origin_client_id text) TO postgres;
GRANT ALL ON FUNCTION public.sync_set_origin_client_id(p_origin_client_id text) TO anon;
GRANT ALL ON FUNCTION public.sync_set_origin_client_id(p_origin_client_id text) TO authenticated;
GRANT ALL ON FUNCTION public.sync_set_origin_client_id(p_origin_client_id text) TO service_role;


--
-- Name: FUNCTION upsert_profile_tracker_settings(p_profile_id integer, p_tracker text, p_enabled_statuses text[], p_row_order text[], p_send_progress boolean); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.upsert_profile_tracker_settings(p_profile_id integer, p_tracker text, p_enabled_statuses text[], p_row_order text[], p_send_progress boolean) TO anon;
GRANT ALL ON FUNCTION public.upsert_profile_tracker_settings(p_profile_id integer, p_tracker text, p_enabled_statuses text[], p_row_order text[], p_send_progress boolean) TO authenticated;
GRANT ALL ON FUNCTION public.upsert_profile_tracker_settings(p_profile_id integer, p_tracker text, p_enabled_statuses text[], p_row_order text[], p_send_progress boolean) TO service_role;


--
-- Name: FUNCTION upsert_tracker_tokens(p_profile_id integer, p_tracker text, p_access_token text, p_refresh_token text, p_expires_in_seconds integer, p_tracker_user_id text, p_username text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.upsert_tracker_tokens(p_profile_id integer, p_tracker text, p_access_token text, p_refresh_token text, p_expires_in_seconds integer, p_tracker_user_id text, p_username text) TO anon;
GRANT ALL ON FUNCTION public.upsert_tracker_tokens(p_profile_id integer, p_tracker text, p_access_token text, p_refresh_token text, p_expires_in_seconds integer, p_tracker_user_id text, p_username text) TO authenticated;
GRANT ALL ON FUNCTION public.upsert_tracker_tokens(p_profile_id integer, p_tracker text, p_access_token text, p_refresh_token text, p_expires_in_seconds integer, p_tracker_user_id text, p_username text) TO service_role;


--
-- Name: FUNCTION verify_profile_pin(p_profile_id integer, p_pin text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.verify_profile_pin(p_profile_id integer, p_pin text) TO anon;
GRANT ALL ON FUNCTION public.verify_profile_pin(p_profile_id integer, p_pin text) TO authenticated;
GRANT ALL ON FUNCTION public.verify_profile_pin(p_profile_id integer, p_pin text) TO service_role;


--
-- Name: TABLE addons; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.addons TO authenticated;
GRANT ALL ON TABLE public.addons TO service_role;
GRANT SELECT ON TABLE public.addons TO supabase_monitor;


--
-- Name: TABLE collections; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.collections TO anon;
GRANT ALL ON TABLE public.collections TO authenticated;
GRANT ALL ON TABLE public.collections TO service_role;
GRANT SELECT ON TABLE public.collections TO supabase_monitor;


--
-- Name: TABLE library_item_events; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.library_item_events TO postgres;
GRANT ALL ON TABLE public.library_item_events TO service_role;
GRANT SELECT ON TABLE public.library_item_events TO supabase_monitor;


--
-- Name: SEQUENCE library_item_events_event_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.library_item_events_event_id_seq TO postgres;
GRANT ALL ON SEQUENCE public.library_item_events_event_id_seq TO anon;
GRANT ALL ON SEQUENCE public.library_item_events_event_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.library_item_events_event_id_seq TO service_role;


--
-- Name: TABLE plugins; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.plugins TO authenticated;
GRANT ALL ON TABLE public.plugins TO service_role;
GRANT SELECT ON TABLE public.plugins TO supabase_monitor;


--
-- Name: TABLE profile_settings_blobs; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.profile_settings_blobs TO anon;
GRANT ALL ON TABLE public.profile_settings_blobs TO authenticated;
GRANT ALL ON TABLE public.profile_settings_blobs TO service_role;
GRANT SELECT ON TABLE public.profile_settings_blobs TO supabase_monitor;


--
-- Name: TABLE profiles; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.profiles TO anon;
GRANT ALL ON TABLE public.profiles TO authenticated;
GRANT ALL ON TABLE public.profiles TO service_role;
GRANT SELECT ON TABLE public.profiles TO supabase_monitor;


--
-- Name: TABLE provider_credentials; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.provider_credentials TO postgres;
GRANT ALL ON TABLE public.provider_credentials TO anon;
GRANT ALL ON TABLE public.provider_credentials TO authenticated;
GRANT ALL ON TABLE public.provider_credentials TO service_role;
GRANT SELECT ON TABLE public.provider_credentials TO supabase_monitor;


--
-- Name: TABLE sync_push_audit_logs; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.sync_push_audit_logs TO service_role;
GRANT SELECT ON TABLE public.sync_push_audit_logs TO supabase_monitor;


--
-- Name: TABLE tracker_tv_login_sessions; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.tracker_tv_login_sessions TO anon;
GRANT ALL ON TABLE public.tracker_tv_login_sessions TO authenticated;
GRANT ALL ON TABLE public.tracker_tv_login_sessions TO service_role;
GRANT SELECT ON TABLE public.tracker_tv_login_sessions TO supabase_monitor;


--
-- Name: TABLE tv_login_sessions; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.tv_login_sessions TO anon;
GRANT ALL ON TABLE public.tv_login_sessions TO authenticated;
GRANT ALL ON TABLE public.tv_login_sessions TO service_role;
GRANT SELECT ON TABLE public.tv_login_sessions TO supabase_monitor;


--
-- Name: TABLE user_activity_events; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.user_activity_events TO service_role;
GRANT SELECT ON TABLE public.user_activity_events TO supabase_monitor;


--
-- Name: TABLE user_session_devices; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.user_session_devices TO postgres;
GRANT ALL ON TABLE public.user_session_devices TO service_role;
GRANT SELECT ON TABLE public.user_session_devices TO supabase_monitor;


--
-- Name: TABLE watch_progress_events; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.watch_progress_events TO service_role;
GRANT SELECT ON TABLE public.watch_progress_events TO supabase_monitor;


--
-- Name: SEQUENCE watch_progress_events_event_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.watch_progress_events_event_id_seq TO anon;
GRANT ALL ON SEQUENCE public.watch_progress_events_event_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.watch_progress_events_event_id_seq TO service_role;


--
-- Name: TABLE watched_item_events; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.watched_item_events TO anon;
GRANT ALL ON TABLE public.watched_item_events TO authenticated;
GRANT ALL ON TABLE public.watched_item_events TO service_role;
GRANT SELECT ON TABLE public.watched_item_events TO supabase_monitor;


--
-- Name: SEQUENCE watched_item_events_event_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.watched_item_events_event_id_seq TO anon;
GRANT ALL ON SEQUENCE public.watched_item_events_event_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.watched_item_events_event_id_seq TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON SEQUENCES TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON SEQUENCES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON SEQUENCES TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON SEQUENCES TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON FUNCTIONS TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON FUNCTIONS TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON FUNCTIONS TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON FUNCTIONS TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON TABLES TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON TABLES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON TABLES TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON TABLES TO service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT SELECT ON TABLES TO supabase_monitor;


--
-- PostgreSQL database dump complete
--




INSERT INTO nuvio_migrations.schema_migrations (version)
VALUES ('00000000000000')
ON CONFLICT (version) DO NOTHING;

COMMIT;
