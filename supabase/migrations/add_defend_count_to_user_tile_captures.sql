-- Phase 1.2a — Defended-count tile metadata.
--
-- Adds a `defend_count` column to user_tile_captures and a BEFORE-INSERT/UPDATE
-- trigger that increments it whenever a user re-captures a hex they had
-- previously owned but lost to another player.
--
-- Semantics ("defend = reclaim, not initial capture"):
--   * First capture of a hex by user U  -> defend_count stays 0
--   * Re-capture by U while U still owns -> defend_count unchanged (refresh)
--   * Re-capture by U after losing to V  -> defend_count incremented by 1
--
-- The trigger fires on user_tile_captures (per-user history table). The
-- "did this user lose it" signal comes from `tile_captures.owner_user_id`
-- which is upserted AFTER user_tile_captures by the client, so during this
-- trigger the OLD owner is still authoritative.
--
-- Idempotent: safe to run multiple times. Uses IF EXISTS / IF NOT EXISTS.

-- 1. Column ------------------------------------------------------------------

alter table if exists public.user_tile_captures
  add column if not exists defend_count integer not null default 0;

-- 2. Trigger function --------------------------------------------------------

create or replace function public.user_tile_captures_increment_defend_count()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  current_owner uuid;
begin
  -- Look up the *current* owner BEFORE this user's re-capture lands in
  -- tile_captures. If the current owner row doesn't exist, this is a brand
  -- new tile and not a reclaim.
  select owner_user_id
    into current_owner
    from public.tile_captures
   where h3_res = new.h3_res
     and h3_hex = new.h3_hex
   limit 1;

  if tg_op = 'INSERT' then
    -- First time this user is capturing this hex. Reclaim only if some
    -- *other* user currently owns it.
    if current_owner is not null and current_owner <> new.user_id then
      new.defend_count := 1;
    else
      new.defend_count := coalesce(new.defend_count, 0);
    end if;
    return new;
  end if;

  -- UPDATE path (upsert ON CONFLICT). Preserve OLD.defend_count by default;
  -- only increment when the most recent owner of record is not this user.
  if current_owner is not null and current_owner <> new.user_id then
    new.defend_count := coalesce(old.defend_count, 0) + 1;
  else
    new.defend_count := coalesce(old.defend_count, 0);
  end if;
  return new;
end;
$$;

-- 3. Trigger -----------------------------------------------------------------

drop trigger if exists trg_user_tile_captures_defend_count
  on public.user_tile_captures;

create trigger trg_user_tile_captures_defend_count
  before insert or update on public.user_tile_captures
  for each row
  execute function public.user_tile_captures_increment_defend_count();
