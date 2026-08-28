-- ============================================================
-- HAKI POTTER: COMMENT YOUR PFP'S  —  Supabase setup
-- ------------------------------------------------------------
-- HOW TO USE:
--   1. Create a FREE project at https://supabase.com (sign in
--      with Google/GitHub -> New project -> wait ~1 minute).
--   2. Open "SQL Editor" in the left sidebar.
--   3. Paste ALL of this file in, then press "Run".
--   4. Copy the ADMIN PASSCODE from the output at the bottom.
--   5. Project Settings -> API -> copy "Project URL" and the
--      "anon" (public) key, and paste them into the two quotes
--      at the top of the <script> in index.html.
-- ============================================================

-- Active requests that fill the 12 queue slots.
create table if not exists public.requests (
  id            bigint generated always as identity primary key,
  name          text not null,
  request       text not null,
  faction       text not null check (faction in ('council', 'resistance', 'egoists')),
  social        text not null default '',
  created_at    timestamptz not null default now(),
  completed_at  timestamptz
);

-- Safe place for the admin passcode. It is NEVER stored in the
-- website file — only in this database.
create table if not exists public.settings (
  key   text primary key,
  value text not null
);

-- Sets the initial passcode (randomly generated on first run).
-- To change it later, run:
--   update public.settings set value = 'YOUR_NEW_PASSCODE' where key = 'admin_key';
insert into public.settings (key, value)
values ('admin_key', substr(encode(digest(gen_random_uuid()::text, 'sha256'), 'base64'), 1, 18))
on conflict (key) do nothing;

-- Row-level security: anyone (anon) may READ the active queue,
-- but NOBODY may insert/update/delete directly. All writes go
-- through the secure functions below.
alter table public.requests enable row level security;

drop policy if exists "public can read active requests" on public.requests;
create policy "public can read active requests"
  on public.requests for select
  to anon, authenticated
  using (true);

grant select on public.requests to anon, authenticated;

-- ------------------------------------------------------------
-- SUBMIT: enforces the 12-slot limit + duplicate check on the
-- SERVER, so it applies to every profile, device and browser.
-- ------------------------------------------------------------
create or replace function public.submit_request(
  p_name     text,
  p_request  text,
  p_faction  text,
  p_social   text default ''
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_active  int;
  v_id      bigint;
  v_created timestamptz;
begin
  if p_faction not in ('council', 'resistance', 'egoists') then
    return json_build_object('ok', false, 'message', 'Pick a valid faction.');
  end if;

  select count(*) into v_active from requests where completed_at is null;
  if v_active >= 12 then
    return json_build_object('ok', false, 'is_full', true,
      'message', 'All 12 request slots are currently full.');
  end if;

  select count(*) into v_active
  from requests
  where completed_at is null
    and lower(name) = lower(p_name)
    and lower(request) = lower(p_request);
  if v_active > 0 then
    return json_build_object('ok', false,
      'message', 'That exact request is already in the queue.');
  end if;

  insert into requests (name, request, faction, social)
  values (p_name, p_request, p_faction, coalesce(p_social, ''))
  returning id, created_at into v_id, v_created;

  select count(*) into v_active from requests where completed_at is null;
  return json_build_object(
    'ok', true,
    'id', v_id,
    'created_at', v_created,
    'slot', v_active,
    'active', v_active,
    'completed', (select count(*) from requests where completed_at is not null)
  );
end;
$$;

grant execute on function public.submit_request(text, text, text, text) to anon, authenticated;

-- ------------------------------------------------------------
-- ADMIN CHECK: returns true only if the passcode matches the one
-- stored in the database.
-- ------------------------------------------------------------
create or replace function public.admin_ok(p_key text)
returns boolean
language sql
security definer
set search_path = public
as $$
  select exists (select 1 from settings where key = 'admin_key' and value = p_key);
$$;

grant execute on function public.admin_ok(text) to anon, authenticated;

-- ------------------------------------------------------------
-- REMOVE: only succeeds when the correct admin passcode is sent.
-- ------------------------------------------------------------
create or replace function public.remove_request(p_id bigint, p_key text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_active int;
begin
  if not exists (select 1 from settings where key = 'admin_key' and value = p_key) then
    return json_build_object('ok', false, 'message', 'Not authorized.');
  end if;

  update requests set completed_at = now()
  where id = p_id and completed_at is null;
  if not found then
    return json_build_object('ok', false, 'message', 'Request not found.');
  end if;

  select count(*) into v_active from requests where completed_at is null;
  return json_build_object(
    'ok', true,
    'active', v_active,
    'completed', (select count(*) from requests where completed_at is not null)
  );
end;
$$;

grant execute on function public.remove_request(bigint, text) to anon, authenticated;

-- ------------------------------------------------------------
-- STATS: active vs completed counts for the creator dashboard.
-- ------------------------------------------------------------
create or replace function public.queue_stats()
returns json
language sql
security definer
set search_path = public
as $$
  select json_build_object(
    'active',    (select count(*) from requests where completed_at is null),
    'completed', (select count(*) from requests where completed_at is not null)
  );
$$;

grant execute on function public.queue_stats() to anon, authenticated;

-- Prints the admin passcode once so you can save it.
select format('ADMIN PASSCODE: %s', value) as setup_result from settings where key = 'admin_key';