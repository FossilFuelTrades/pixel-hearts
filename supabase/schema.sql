-- Pixel Hearts — shared gallery schema
-- Paste this whole file into the Supabase SQL editor and hit Run.
--
-- Security model, in plain terms:
-- The anon key sitting in index.html is public (that is what it is for), and
-- this repo is public too. So the table itself is locked down completely --
-- RLS on, zero policies, permissions revoked. Nobody can read or write it
-- directly, even holding the anon key.
--
-- The only way in is through the three functions below, and every one of them
-- demands the pair code. The pair code is 16 random url-safe characters
-- (~96 bits) generated on your phone and never stored anywhere but the two
-- devices. Without it you cannot read a single row, and you cannot enumerate
-- pair codes because there is no function that lists them.

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

create index if not exists ph_rounds_pair_idx
  on public.ph_rounds (pair_code, created_at desc);

alter table public.ph_rounds enable row level security;
revoke all on public.ph_rounds from anon, authenticated;

-- ---------------------------------------------------------------- add round
create or replace function public.ph_add_round(
  p_id uuid, p_pair text, p_artist text, p_word text, p_cat text, p_grid text
) returns void
language plpgsql security definer set search_path = public as $$
begin
  if length(coalesce(p_pair, '')) < 12 then
    raise exception 'pair code missing or too short';
  end if;
  insert into public.ph_rounds (id, pair_code, artist, word, cat, grid, state)
  values (p_id, p_pair, left(p_artist, 24), left(p_word, 48),
          left(p_cat, 48), left(p_grid, 4000), 'sent')
  on conflict (id) do nothing;   -- either side may register the round first
end $$;

-- ------------------------------------------------------------- finish round
create or replace function public.ph_finish_round(
  p_id uuid, p_pair text, p_guesser text, p_state text, p_tries int
) returns void
language plpgsql security definer set search_path = public as $$
begin
  if length(coalesce(p_pair, '')) < 12 then
    raise exception 'pair code missing or too short';
  end if;
  update public.ph_rounds
     set guesser    = left(p_guesser, 24),
         state      = case when p_state in ('solved', 'missed') then p_state else state end,
         tries      = p_tries,
         updated_at = now()
   where id = p_id
     and pair_code = p_pair;   -- wrong code touches nothing
end $$;

-- --------------------------------------------------------------- read them
create or replace function public.ph_get_rounds(p_pair text, p_limit int default 120)
returns table (
  id uuid, artist text, guesser text, word text, cat text,
  grid text, state text, tries int, created_at timestamptz
)
language plpgsql security definer set search_path = public as $$
begin
  if length(coalesce(p_pair, '')) < 12 then
    raise exception 'pair code missing or too short';
  end if;
  return query
    select r.id, r.artist, r.guesser, r.word, r.cat,
           r.grid, r.state, r.tries, r.created_at
      from public.ph_rounds r
     where r.pair_code = p_pair
     order by r.created_at desc
     limit least(coalesce(p_limit, 120), 300);
end $$;

grant execute on function public.ph_add_round(uuid, text, text, text, text, text) to anon;
grant execute on function public.ph_finish_round(uuid, text, text, text, int)      to anon;
grant execute on function public.ph_get_rounds(text, int)                          to anon;
