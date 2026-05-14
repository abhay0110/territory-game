-- Phase 1.3 — Streak server-side promotion.
--
-- Backup table for StreakService local state. The CLIENT is authoritative
-- for current state (StreakService.computeTransition runs locally on
-- every capture). The server is a backup that:
--
--   1. Survives device reinstall — user sees their longest_streak return
--   2. Syncs across devices — capturing on iOS and Android same account
--      preserves the longer streak / older last_capture_date
--
-- No trigger logic. No streak compute in plpgsql. Client pushes its
-- post-transition state via upsert; client pulls on first read after
-- app start and merges (server max wins for longest_streak; server
-- values win when local has no data, e.g. fresh install).
--
-- Idempotent.

create table if not exists public.user_streaks (
  user_id uuid primary key references auth.users(id) on delete cascade,
  current_streak integer not null default 0,
  longest_streak integer not null default 0,
  last_capture_date date,
  freezes_available integer not null default 0,
  freeze_week_anchor text,
  updated_at timestamptz not null default now()
);

-- Update updated_at on every modification so we can debug "which device
-- last touched this".
create or replace function public.user_streaks_set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists trg_user_streaks_set_updated_at on public.user_streaks;
create trigger trg_user_streaks_set_updated_at
  before update on public.user_streaks
  for each row
  execute function public.user_streaks_set_updated_at();

-- RLS: users can only see/modify their own row.
alter table public.user_streaks enable row level security;

drop policy if exists user_streaks_select_own on public.user_streaks;
create policy user_streaks_select_own
  on public.user_streaks for select
  using (auth.uid() = user_id);

drop policy if exists user_streaks_upsert_own on public.user_streaks;
create policy user_streaks_upsert_own
  on public.user_streaks for insert
  with check (auth.uid() = user_id);

drop policy if exists user_streaks_update_own on public.user_streaks;
create policy user_streaks_update_own
  on public.user_streaks for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);
