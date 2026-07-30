-- Pixel Hearts — accounts + shared gallery
-- Paste this whole file into the Supabase SQL editor and hit Run.
-- Safe to re-run; it drops and recreates the functions.
--
-- Security model, in plain terms:
--   The anon key in index.html is public and this repo is public, so both
--   tables are locked completely: RLS on, zero policies, permissions revoked.
--   Nothing can read or write them directly even holding the anon key.
--
--   The only way in is the functions below. Claiming or logging in costs a
--   username + PIN; everything after that costs a session token handed back by
--   login. PINs are bcrypt-hashed and never returned. Ten bad PINs locks the
--   account for 15 minutes, because a 4-digit PIN is only 10k guesses.
--
--   The pair code is now internal plumbing, not something either of you holds.

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------- tables
create table if not exists public.ph_users (
  username        text primary key,             -- lowercase, 3-16 [a-z0-9_]
  display         text        not null,         -- what shows in the UI
  pin_hash        text        not null,
  pair_code       text        not null,         -- shared by a paired couple
  partner         text        references public.ph_users(username),
  failed          int         not null default 0,
  locked_until    timestamptz,
  created_at      timestamptz not null default now()
);

create table if not exists public.ph_sessions (
  token       text primary key,
  username    text        not null references public.ph_users(username) on delete cascade,
  created_at  timestamptz not null default now()
);
create index if not exists ph_sessions_user_idx on public.ph_sessions (username);

create table if not exists public.ph_pair_requests (
  from_user   text        not null references public.ph_users(username) on delete cascade,
  to_user     text        not null references public.ph_users(username) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (from_user, to_user)
);

create table if not exists public.ph_rounds (
  id          uuid primary key,
  pair_code   text        not null,
  artist      text        not null,
  guesser     text,
  word        text        not null,
  cat         text,
  grid        text        not null,
  state       text        not null default 'sent',   -- sent | solved | missed
  tries       int,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists ph_rounds_pair_idx on public.ph_rounds (pair_code, created_at desc);

alter table public.ph_users         enable row level security;
alter table public.ph_sessions      enable row level security;
alter table public.ph_pair_requests enable row level security;
alter table public.ph_rounds        enable row level security;
revoke all on public.ph_users, public.ph_sessions,
              public.ph_pair_requests, public.ph_rounds from anon, authenticated;

-- ------------------------------------------------------------- internals
create or replace function public.ph_norm(p text) returns text
language sql immutable as $$ select lower(trim(coalesce(p, ''))) $$;

-- resolves a session token to a username, or raises
create or replace function public.ph_uid(p_token text) returns text
language plpgsql security definer set search_path = public as $$
declare u text;
begin
  select s.username into u from public.ph_sessions s where s.token = p_token;
  if u is null then raise exception 'not signed in'; end if;
  return u;
end $$;

create or replace function public.ph_new_token() returns text
language sql volatile as $$ select encode(gen_random_bytes(24), 'hex') $$;

-- ------------------------------------------------------------------ claim
create or replace function public.ph_claim(p_username text, p_display text, p_pin text)
returns text
language plpgsql security definer set search_path = public as $$
declare u text := public.ph_norm(p_username); t text;
begin
  if u !~ '^[a-z0-9_]{3,16}$' then
    raise exception 'username must be 3-16 letters, numbers or underscores';
  end if;
  if p_pin !~ '^[0-9]{4,8}$' then
    raise exception 'PIN must be 4-8 digits';
  end if;
  if exists (select 1 from public.ph_users where username = u) then
    raise exception 'that username is taken';
  end if;

  insert into public.ph_users (username, display, pin_hash, pair_code)
  values (u, left(coalesce(nullif(trim(p_display), ''), p_username), 24),
          crypt(p_pin, gen_salt('bf', 10)),
          encode(gen_random_bytes(12), 'hex'));

  t := public.ph_new_token();
  insert into public.ph_sessions (token, username) values (t, u);
  return t;
end $$;

-- ------------------------------------------------------------------ login
create or replace function public.ph_login(p_username text, p_pin text)
returns text
language plpgsql security definer set search_path = public as $$
declare r public.ph_users; t text;
begin
  select * into r from public.ph_users where username = public.ph_norm(p_username);
  if r.username is null then raise exception 'wrong username or PIN'; end if;

  if r.locked_until is not null and r.locked_until > now() then
    raise exception 'too many tries, locked until %', to_char(r.locked_until, 'HH24:MI');
  end if;

  if r.pin_hash <> crypt(p_pin, r.pin_hash) then
    update public.ph_users
       set failed = failed + 1,
           locked_until = case when failed + 1 >= 10 then now() + interval '15 minutes' end
     where username = r.username;
    raise exception 'wrong username or PIN';
  end if;

  update public.ph_users set failed = 0, locked_until = null where username = r.username;
  t := public.ph_new_token();
  insert into public.ph_sessions (token, username) values (t, r.username);
  return t;
end $$;

create or replace function public.ph_logout(p_token text) returns void
language sql security definer set search_path = public as $$
  delete from public.ph_sessions where token = p_token;
$$;

-- --------------------------------------------------------------- whoami
create or replace function public.ph_me(p_token text)
returns table (username text, display text, partner text, partner_display text, pending text[])
language plpgsql security definer set search_path = public as $$
declare me text := public.ph_uid(p_token);
begin
  return query
    select u.username, u.display, u.partner,
           (select p.display from public.ph_users p where p.username = u.partner),
           coalesce((select array_agg(r.from_user order by r.created_at)
                       from public.ph_pair_requests r where r.to_user = u.username), '{}')
      from public.ph_users u
     where u.username = me;
end $$;

-- ---------------------------------------------------------------- pairing
create or replace function public.ph_request_pair(p_token text, p_partner text)
returns text
language plpgsql security definer set search_path = public as $$
declare me text := public.ph_uid(p_token); them text := public.ph_norm(p_partner);
begin
  if them = me then raise exception 'that is you'; end if;
  if not exists (select 1 from public.ph_users where username = them) then
    raise exception 'no one goes by that username';
  end if;

  -- they already asked you: treat this as accepting
  if exists (select 1 from public.ph_pair_requests where from_user = them and to_user = me) then
    perform public.ph_accept_pair(p_token, them);
    return 'paired';
  end if;

  insert into public.ph_pair_requests (from_user, to_user) values (me, them)
  on conflict do nothing;
  return 'requested';
end $$;

create or replace function public.ph_accept_pair(p_token text, p_from text)
returns void
language plpgsql security definer set search_path = public as $$
declare me text := public.ph_uid(p_token);
        them text := public.ph_norm(p_from);
        shared text;
begin
  if not exists (select 1 from public.ph_pair_requests where from_user = them and to_user = me) then
    raise exception 'no pending request from that username';
  end if;

  select pair_code into shared from public.ph_users where username = me;

  -- move their history onto the shared code so neither gallery is lost
  update public.ph_rounds
     set pair_code = shared
   where pair_code = (select pair_code from public.ph_users where username = them);

  update public.ph_users set pair_code = shared, partner = me   where username = them;
  update public.ph_users set                    partner = them  where username = me;

  delete from public.ph_pair_requests
   where (from_user = them and to_user = me) or (from_user = me and to_user = them);
end $$;

create or replace function public.ph_unpair(p_token text) returns void
language plpgsql security definer set search_path = public as $$
declare me text := public.ph_uid(p_token); them text;
begin
  select partner into them from public.ph_users where username = me;
  -- leaver takes a fresh empty code; the history stays with the other one
  update public.ph_users
     set pair_code = encode(gen_random_bytes(12), 'hex'), partner = null
   where username = me;
  if them is not null then
    update public.ph_users set partner = null where username = them;
  end if;
end $$;

-- ----------------------------------------------------------------- rounds
create or replace function public.ph_add_round(
  p_token text, p_id uuid, p_word text, p_cat text, p_grid text
) returns void
language plpgsql security definer set search_path = public as $$
declare me text := public.ph_uid(p_token); code text; disp text;
begin
  select pair_code, display into code, disp from public.ph_users where username = me;
  insert into public.ph_rounds (id, pair_code, artist, word, cat, grid, state)
  values (p_id, code, disp, left(p_word, 48), left(p_cat, 48), left(p_grid, 4000), 'sent')
  on conflict (id) do nothing;   -- either side may register it first
end $$;

create or replace function public.ph_finish_round(
  p_token text, p_id uuid, p_state text, p_tries int
) returns void
language plpgsql security definer set search_path = public as $$
declare me text := public.ph_uid(p_token); code text; disp text;
begin
  select pair_code, display into code, disp from public.ph_users where username = me;
  update public.ph_rounds
     set guesser = disp,
         state = case when p_state in ('solved','missed') then p_state else state end,
         tries = p_tries,
         updated_at = now()
   where id = p_id and pair_code = code;
end $$;

create or replace function public.ph_get_rounds(p_token text, p_limit int default 120)
returns table (id uuid, artist text, guesser text, word text, cat text,
               grid text, state text, tries int, created_at timestamptz)
language plpgsql security definer set search_path = public as $$
declare me text := public.ph_uid(p_token); code text;
begin
  select pair_code into code from public.ph_users where username = me;
  return query
    select r.id, r.artist, r.guesser, r.word, r.cat,
           r.grid, r.state, r.tries, r.created_at
      from public.ph_rounds r
     where r.pair_code = code
     order by r.created_at desc
     limit least(coalesce(p_limit, 120), 300);
end $$;

-- ------------------------------------------------------------------ grants
revoke all on function public.ph_uid(text), public.ph_new_token() from anon, authenticated;
grant execute on function public.ph_claim(text, text, text)          to anon;
grant execute on function public.ph_login(text, text)                to anon;
grant execute on function public.ph_logout(text)                     to anon;
grant execute on function public.ph_me(text)                         to anon;
grant execute on function public.ph_request_pair(text, text)         to anon;
grant execute on function public.ph_accept_pair(text, text)          to anon;
grant execute on function public.ph_unpair(text)                     to anon;
grant execute on function public.ph_add_round(text, uuid, text, text, text) to anon;
grant execute on function public.ph_finish_round(text, uuid, text, int)     to anon;
grant execute on function public.ph_get_rounds(text, int)            to anon;
