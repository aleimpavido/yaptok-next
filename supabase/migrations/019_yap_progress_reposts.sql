-- 019_yap_progress_reposts.sql
-- Personal posting streaks, native reposts, XP and a free cosmetic catalogue.
--
-- Streak days are derived from currently valid public clips, not cached counters:
-- deleted, private, failed, removed, or banned-owner clips never count.
-- A user's IANA timezone determines the calendar day.
-- Reposts reference the original video; they never duplicate media or video rows.
-- XP and cosmetic ownership are written only by database functions/triggers.

-- A validated IANA timezone for daily boundaries.
alter table public.profiles
  add column if not exists timezone text not null default 'UTC';

create or replace function public.set_my_timezone(p_timezone text)
returns text
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  me uuid := (select auth.uid());
  chosen text := coalesce(nullif(trim(p_timezone), ''), 'UTC');
begin
  if me is null then
    raise exception 'not_signed_in' using errcode = 'P0001';
  end if;
  if public.is_banned(me) then
    raise exception 'banned' using errcode = 'P0001';
  end if;
  if not exists (select 1 from pg_catalog.pg_timezone_names z where z.name = chosen) then
    raise exception 'timezone_invalid' using errcode = 'P0001';
  end if;
  update public.profiles set timezone = chosen where id = me;
  return chosen;
end;
$$;

revoke execute on function public.set_my_timezone(text) from public, anon;
grant execute on function public.set_my_timezone(text) to authenticated;

-- Reposts point to the source clip; the original video remains the only media row.
alter table public.videos
  add column if not exists repost_count integer not null default 0;

-- Extend every normal feed/profile card with the viewer's repost state.



create table if not exists public.reposts (
  user_id uuid not null references public.profiles(id) on delete cascade,
  video_id uuid not null references public.videos(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, video_id)
);

create index if not exists reposts_user_idx on public.reposts(user_id, created_at desc);
create index if not exists reposts_video_idx on public.reposts(video_id, created_at desc);

-- Extend every normal feed/profile card with the viewer's repost state.
create or replace function public.video_card(v public.videos, viewer uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $q$
  select jsonb_build_object(
    'id', v.id,
    'caption', v.caption,
    'hashtags', to_jsonb(v.hashtags),
    'visibility', v.visibility,
    'status', v.status,
    'duration_s', v.duration_s,
    'width', v.width,
    'height', v.height,
    'hls_key', v.hls_key,
    'thumbnail_url', v.thumbnail_url,
    'like_count', v.like_count,
    'comment_count', v.comment_count,
    'view_count', v.view_count,
    'share_count', v.share_count,
    'save_count', v.save_count,
    'repost_count', v.repost_count,
    'published_at', v.published_at,
    'created_at', v.created_at,
    'removed', v.removed_at is not null,
    'author', jsonb_build_object(
      'id', p.id,
      'username', p.username,
      'display_name', p.display_name,
      'avatar_url', p.avatar_url,
      'verified', p.verified
    ),
    'liked', viewer is not null
      and exists (select 1 from public.likes l where l.video_id = v.id and l.user_id = viewer),
    'following', viewer is not null
      and exists (select 1 from public.follows f where f.follower_id = viewer and f.followee_id = v.owner_id),
    'saved', viewer is not null
      and exists (select 1 from public.saves s where s.video_id = v.id and s.user_id = viewer),
    'reposted', viewer is not null
      and exists (select 1 from public.reposts r where r.video_id = v.id and r.user_id = viewer),
    'mine', viewer is not null and v.owner_id = viewer
  )
  from public.profiles p
  where p.id = v.owner_id;
$q$;

alter table public.reposts enable row level security;
create or replace function public.repost_is_visible(p_user uuid, p_video uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $q$
  select exists (
    select 1 from public.reposts r
    join public.videos v on v.id = r.video_id
    join public.profiles creator on creator.id = v.owner_id
    join public.profiles actor on actor.id = r.user_id
    where r.user_id = p_user and r.video_id = p_video
      and v.visibility = 'public' and v.status = 'ready' and v.removed_at is null
      and creator.banned_at is null and actor.banned_at is null
  );
$q$;
revoke execute on function public.repost_is_visible(uuid, uuid) from public;
grant execute on function public.repost_is_visible(uuid, uuid) to anon, authenticated;

drop policy if exists "public reposts of public clips are readable" on public.reposts;
create policy "public reposts of public clips are readable"
  on public.reposts for select to anon, authenticated
  using (public.repost_is_visible(user_id, video_id));

revoke all on public.reposts from anon, authenticated;
grant select on public.reposts to anon, authenticated;

create or replace function public.reposts_count()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.videos v
    set repost_count = greatest(v.repost_count + case when tg_op = 'INSERT' then 1 else -1 end, 0)
    where v.id = coalesce(new.video_id, old.video_id);
  return null;
end;
$$;

drop trigger if exists reposts_count on public.reposts;
create trigger reposts_count after insert or delete on public.reposts
  for each row execute function public.reposts_count();

-- Add repost to the existing activity inbox vocabulary.
alter table public.notifications drop constraint if exists notifications_kind_valid;
alter table public.notifications add constraint notifications_kind_valid
  check (kind in ('like', 'comment', 'reply', 'comment_like', 'follow', 'repost'));

create or replace function public.notify_on_repost()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  creator uuid;
begin
  select owner_id into creator from public.videos where id = new.video_id;
  perform public.notify(creator, new.user_id, 'repost', new.video_id, null);
  return null;
end;
$$;

drop trigger if exists reposts_notify on public.reposts;
create trigger reposts_notify after insert on public.reposts
  for each row execute function public.notify_on_repost();

-- Toggle is idempotent when p_on is supplied. A user cannot repost their own clip.
create or replace function public.toggle_repost(p_video uuid, p_on boolean default null)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  me uuid := (select auth.uid());
  creator uuid;
  has_repost boolean;
  want boolean;
begin
  if me is null then raise exception 'not_signed_in' using errcode = 'P0001'; end if;
  if not public.flag_on('reposts', me) then raise exception 'reposts_off' using errcode = 'P0001'; end if;
  if public.is_banned(me) then raise exception 'banned' using errcode = 'P0001'; end if;

  select v.owner_id into creator
    from public.videos v join public.profiles p on p.id = v.owner_id
    where v.id = p_video and v.visibility = 'public' and v.status = 'ready'
      and v.removed_at is null and p.banned_at is null;
  if creator is null then raise exception 'not_found' using errcode = 'P0001'; end if;
  if creator = me then raise exception 'cannot_repost_own' using errcode = 'P0001'; end if;

  select exists(select 1 from public.reposts r where r.user_id = me and r.video_id = p_video)
    into has_repost;
  want := coalesce(p_on, not has_repost);
  if want and not has_repost then
    insert into public.reposts(user_id, video_id) values (me, p_video) on conflict do nothing;
  elsif not want and has_repost then
    delete from public.reposts where user_id = me and video_id = p_video;
  end if;

  return jsonb_build_object(
    'reposted', want,
    'repost_count', (select v.repost_count from public.videos v where v.id = p_video)
  );
end;
$$;

-- A page of the signed-in user's reposts, newest first.
create or replace function public.my_reposts(p_username text, p_limit int default 24, p_before timestamptz default null)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(
    public.video_card(v, (select auth.uid())) ||
    jsonb_build_object('reposted_at', r.created_at, 'reposted_by', p.username)
    order by r.created_at desc
  ), '[]'::jsonb)
  from (
    select x.* from public.reposts x
    join public.profiles actor on actor.id = x.user_id
    where lower(actor.username) = lower(p_username)
      and actor.banned_at is null
      and public.flag_on('reposts', (select auth.uid()))
      and (x.user_id = (select auth.uid()) or public.flag_on('profiles', (select auth.uid())))
      and (p_before is null or x.created_at < p_before)
    order by x.created_at desc
    limit least(greatest(coalesce(p_limit, 24), 1), 60)
  ) r
  join public.videos v on v.id = r.video_id
  join public.profiles creator on creator.id = v.owner_id
  join public.profiles p on p.id = r.user_id
  where v.visibility = 'public' and v.status = 'ready' and v.removed_at is null
    and creator.banned_at is null;
$$;

-- Reposts made by people the caller follows. The source clip is returned once,
-- with attribution, not duplicated in storage or the videos table.
create or replace function public.following_reposts(p_limit int default 20, p_before timestamptz default null)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(
    public.video_card(v, (select auth.uid())) ||
    jsonb_build_object('reposted_at', r.created_at, 'reposted_by', actor.username)
    order by r.created_at desc
  ), '[]'::jsonb)
  from (
    select x.* from public.reposts x
    join public.follows f on f.follower_id = (select auth.uid()) and f.followee_id = x.user_id
    where public.flag_on('following', (select auth.uid()))
      and public.flag_on('reposts', (select auth.uid()))
      and (p_before is null or x.created_at < p_before)
    order by x.created_at desc
    limit least(greatest(coalesce(p_limit, 20), 1), 40)
  ) r
  join public.profiles actor on actor.id = r.user_id and actor.banned_at is null
  join public.videos v on v.id = r.video_id
  join public.profiles creator on creator.id = v.owner_id and creator.banned_at is null
  where v.visibility = 'public' and v.status = 'ready' and v.removed_at is null;
$$;

-- XP ledger: unique source keys make retries harmless. No client can insert or edit XP.
create table if not exists public.prestige_xp (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  source_key text not null,
  amount integer not null check (amount <> 0 and amount between -1000 and 1000),
  created_at timestamptz not null default now(),
  unique(user_id, source_key)
);
create index if not exists prestige_xp_user_idx on public.prestige_xp(user_id, created_at desc);
alter table public.prestige_xp enable row level security;
revoke all on public.prestige_xp from anon, authenticated;

create or replace function public.award_prestige_xp(p_user uuid, p_source text, p_amount integer)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_user is null or p_source is null or p_source = '' or p_amount = 0
     or p_amount < -1000 or p_amount > 1000 then return; end if;
  insert into public.prestige_xp(user_id, source_key, amount)
  values (p_user, p_source, p_amount)
  on conflict (user_id, source_key) do nothing;
end;
$$;
revoke execute on function public.award_prestige_xp(uuid, text, integer) from public, anon, authenticated;

-- One daily publishing reward, regardless of how many clips are posted that day.
create or replace function public.reward_daily_publication()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  zone text;
  local_day date;
  streak_days integer := 0;
begin
  if new.visibility <> 'public' or new.status <> 'ready' or new.removed_at is not null
     or not public.flag_on('prestige', new.owner_id) then
    return new;
  end if;
  select p.timezone into zone from public.profiles p
    where p.id = new.owner_id and p.banned_at is null;
  if zone is null then return new; end if;
  local_day := (coalesce(new.published_at, now()) at time zone zone)::date;
  perform public.award_prestige_xp(new.owner_id, 'daily_post:' || local_day::text, 20);

  -- One-time milestone bonuses; the ledger key prevents repeat claims.
  with days as (
    select distinct (v.published_at at time zone zone)::date as day
    from public.videos v
    where v.owner_id = new.owner_id and v.visibility = 'public'
      and v.status = 'ready' and v.removed_at is null and v.published_at is not null
  ), grouped as (
    select day, day - (row_number() over(order by day))::integer as grp from days
  )
  select count(*)::integer into streak_days
    from grouped
    where grp = (select grp from grouped order by day desc limit 1);
  if streak_days = 3 then
    perform public.award_prestige_xp(new.owner_id, 'streak_milestone:3', 20);
  elsif streak_days = 7 then
    perform public.award_prestige_xp(new.owner_id, 'streak_milestone:7', 50);
  elsif streak_days = 14 then
    perform public.award_prestige_xp(new.owner_id, 'streak_milestone:14', 100);
  elsif streak_days = 30 then
    perform public.award_prestige_xp(new.owner_id, 'streak_milestone:30', 250);
  elsif streak_days = 100 then
    perform public.award_prestige_xp(new.owner_id, 'streak_milestone:100', 1000);
  end if;
  return new;
end;
$$;
revoke execute on function public.reward_daily_publication() from public, anon, authenticated;
drop trigger if exists videos_daily_publication_xp on public.videos;
create trigger videos_daily_publication_xp
  after insert or update of status, visibility, removed_at on public.videos
  for each row
  when (new.visibility = 'public' and new.status = 'ready' and new.removed_at is null)
  execute function public.reward_daily_publication();

create or replace function public.reward_repost_xp()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  zone text;
  today_local date;
  repost_rewards_today integer;
begin
  if public.flag_on('prestige', new.user_id) then
    select p.timezone into zone from public.profiles p
      where p.id = new.user_id and p.banned_at is null;
    zone := coalesce(zone, 'UTC');
    today_local := (now() at time zone zone)::date;
    select count(*)::integer into repost_rewards_today
      from public.prestige_xp x
      where x.user_id = new.user_id
        and left(x.source_key, 7) = 'repost:'
        and (x.created_at at time zone zone)::date = today_local;
    -- Hard daily cap: repost XP cannot be farmed by mass reposting.
    if repost_rewards_today < 10 then
      perform public.award_prestige_xp(new.user_id, 'repost:' || new.video_id::text, 5);
    end if;
  end if;
  return new;
end;
$$;
revoke execute on function public.reward_repost_xp() from public, anon, authenticated;
drop trigger if exists reposts_reward_xp on public.reposts;
create trigger reposts_reward_xp after insert on public.reposts
  for each row execute function public.reward_repost_xp();

-- A free catalogue. unlock_level/xp are earned through participation, never payment.
create table if not exists public.prestige_cosmetics (
  id text primary key,
  name text not null,
  category text not null check (category in ('avatar_frame','profile_effect','banner','nameplate','chat_effect','title')),
  rarity text not null check (rarity in ('common','rare','epic','legendary')),
  unlock_level integer not null default 1 check (unlock_level between 1 and 1000),
  required_xp integer not null default 0 check (required_xp >= 0),
  style jsonb not null default '{}'::jsonb,
  active boolean not null default true
);
alter table public.prestige_cosmetics enable row level security;
drop policy if exists "active cosmetics are public" on public.prestige_cosmetics;
create policy "active cosmetics are public" on public.prestige_cosmetics
  for select to anon, authenticated using (active);
revoke all on public.prestige_cosmetics from anon, authenticated;
grant select on public.prestige_cosmetics to anon, authenticated;

create table if not exists public.user_cosmetics (
  user_id uuid not null references public.profiles(id) on delete cascade,
  cosmetic_id text not null references public.prestige_cosmetics(id) on delete cascade,
  unlocked_at timestamptz not null default now(),
  equipped boolean not null default false,
  primary key(user_id, cosmetic_id)
);
alter table public.user_cosmetics enable row level security;
drop policy if exists "people read their own cosmetics" on public.user_cosmetics;
create policy "people read their own cosmetics" on public.user_cosmetics
  for select to authenticated using ((select auth.uid()) = user_id);
revoke all on public.user_cosmetics from anon, authenticated;
grant select on public.user_cosmetics to authenticated;

insert into public.prestige_cosmetics(id,name,category,rarity,unlock_level,required_xp,style)
values
 ('frame_spark','Spark Frame','avatar_frame','common',2,100,'{"effect":"spark"}'),
 ('frame_neon','Neon Pulse','avatar_frame','rare',5,500,'{"effect":"neon"}'),
 ('frame_glitch','Glitch Circuit','avatar_frame','epic',10,1500,'{"effect":"glitch"}'),
 ('frame_galaxy','Event Horizon','avatar_frame','legendary',25,6000,'{"effect":"galaxy"}'),
 ('banner_sunset','Afterglow','banner','common',3,200,'{"effect":"sunset"}'),
 ('banner_aurora','Aurora Flow','banner','rare',8,1000,'{"effect":"aurora"}'),
 ('profile_particles','Particle Field','profile_effect','epic',12,2200,'{"effect":"particles"}'),
 ('nameplate_chrome','Chrome Nameplate','nameplate','rare',6,700,'{"effect":"chrome"}'),
 ('chat_lightning','Lightning Chat','chat_effect','epic',15,3000,'{"effect":"lightning"}'),
 ('title_creator','Rising Creator','title','common',4,300,'{"label":"Rising Creator"}'),
 ('title_icon','Icon','title','rare',9,1200,'{"label":"Icon"}'),
 ('title_legend','Legend','title','legendary',30,8000,'{"label":"Legend"}')
on conflict (id) do nothing;

-- Read personal progression and a 90-day calendar. Current streak remains
-- alive through the day after the last post, giving the creator the full day
-- to publish again. Multiple posts in one day count once.
create or replace function public.my_yap_progress()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  me uuid := (select auth.uid());
  zone text;
  today_local date;
  current_days integer := 0;
  best_days integer := 0;
  xp_total integer := 0;
  level_now integer := 1;
  calendar jsonb;
begin
  if me is null then raise exception 'not_signed_in' using errcode = 'P0001'; end if;
  if not (public.flag_on('streaks', me) or public.flag_on('prestige', me) or public.flag_on('collection', me)) then
    raise exception 'streaks_off' using errcode = 'P0001';
  end if;
  if public.is_banned(me) then raise exception 'banned' using errcode = 'P0001'; end if;

  select coalesce(p.timezone,'UTC') into zone from public.profiles p where p.id = me;
  today_local := (now() at time zone zone)::date;

  with days as (
    select distinct (v.published_at at time zone zone)::date as day
    from public.videos v
    where v.owner_id = me and v.visibility = 'public' and v.status = 'ready'
      and v.removed_at is null and v.published_at is not null
  ), grouped as (
    select day, day - (row_number() over(order by day))::integer as grp from days
  ), runs as (
    select grp, count(*)::integer as length, max(day) as last_day from grouped group by grp
  )
  select
    coalesce(max(length),0),
    coalesce(max(length) filter(where last_day >= today_local - 1),0)
  into best_days, current_days from runs;

  select coalesce(sum(amount),0)::integer into xp_total from public.prestige_xp where user_id = me;
  level_now := greatest(1, floor(sqrt(greatest(xp_total,0)::numeric / 100))::integer + 1);

  select coalesce(jsonb_agg(jsonb_build_object(
    'date', d::date::text,
    'posted', exists (
      select 1 from public.videos v where v.owner_id = me
        and v.visibility = 'public' and v.status = 'ready' and v.removed_at is null
        and v.published_at is not null and (v.published_at at time zone zone)::date = d::date
    )
  ) order by d), '[]'::jsonb)
  into calendar from generate_series(today_local - 89, today_local, interval '1 day') as g(d);

  return jsonb_build_object(
    'timezone', zone, 'today', today_local, 'current_streak', current_days,
    'best_streak', best_days, 'xp', xp_total, 'level', level_now,
    'next_level_xp', level_now * level_now * 100,
    'calendar', calendar
  );
end;
$$;

-- Claim only cosmetics whose requirements have actually been earned.
create or replace function public.claim_cosmetic(p_cosmetic text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  me uuid := (select auth.uid());
  total integer;
  level_now integer;
  item public.prestige_cosmetics;
begin
  if me is null then raise exception 'not_signed_in' using errcode = 'P0001'; end if;
  if not public.flag_on('collection', me) then raise exception 'collection_off' using errcode = 'P0001'; end if;
  if public.is_banned(me) then raise exception 'banned' using errcode = 'P0001'; end if;

  select * into item from public.prestige_cosmetics where id = p_cosmetic and active;
  if item.id is null then raise exception 'cosmetic_not_found' using errcode = 'P0001'; end if;
  select coalesce(sum(amount),0)::integer into total from public.prestige_xp where user_id = me;
  level_now := greatest(1, floor(sqrt(greatest(total,0)::numeric / 100))::integer + 1);
  if total < item.required_xp or level_now < item.unlock_level then
    raise exception 'cosmetic_locked' using errcode = 'P0001';
  end if;

  insert into public.user_cosmetics(user_id,cosmetic_id)
    values(me,item.id) on conflict do nothing;
  return jsonb_build_object('cosmetic_id',item.id,'unlocked',true);
end;
$$;

revoke execute on function public.reposts_count() from public, anon, authenticated;
revoke execute on function public.notify_on_repost() from public, anon, authenticated;

-- Equip one already-earned cosmetic per category. This only changes the
-- signed-in user's own selection; it cannot unlock or purchase an item.
create or replace function public.equip_cosmetic(p_cosmetic text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $q$
declare
  me uuid := (select auth.uid());
  item public.prestige_cosmetics;
begin
  if me is null then raise exception 'not_signed_in' using errcode = 'P0001'; end if;
  if not public.flag_on('collection', me) then raise exception 'collection_off' using errcode = 'P0001'; end if;
  if public.is_banned(me) then raise exception 'banned' using errcode = 'P0001'; end if;
  select c.* into item from public.prestige_cosmetics c
    join public.user_cosmetics uc on uc.cosmetic_id = c.id and uc.user_id = me
    where c.id = p_cosmetic and c.active;
  if item.id is null then raise exception 'cosmetic_locked' using errcode = 'P0001'; end if;

  perform pg_advisory_xact_lock(hashtextextended('cosmetic:' || me::text || ':' || item.category, 0));
  update public.user_cosmetics uc set equipped = false
    from public.prestige_cosmetics c
    where uc.user_id = me and uc.cosmetic_id = c.id and c.category = item.category;
  update public.user_cosmetics set equipped = true
    where user_id = me and cosmetic_id = item.id;
  return jsonb_build_object('equipped', item.id, 'category', item.category);
end;
$q$;

revoke execute on function public.toggle_repost(uuid, boolean) from public, anon;
revoke execute on function public.my_reposts(text, int, timestamptz) from public, anon;
revoke execute on function public.following_reposts(int, timestamptz) from public, anon;
revoke execute on function public.my_yap_progress() from public, anon;
revoke execute on function public.claim_cosmetic(text) from public, anon;
revoke execute on function public.equip_cosmetic(text) from public, anon;
grant execute on function public.toggle_repost(uuid, boolean) to authenticated;
grant execute on function public.my_reposts(text, int, timestamptz) to authenticated;
grant execute on function public.following_reposts(int, timestamptz) to authenticated;
grant execute on function public.my_yap_progress() to authenticated;
grant execute on function public.claim_cosmetic(text) to authenticated;
grant execute on function public.equip_cosmetic(text) to authenticated;

insert into public.feature_flags(key,label,description,mode)
values
 ('streaks','YapStreak','Personal daily posting streaks, calendar and milestones.','off'),
 ('reposts','YapRepost','Repost public clips without duplicating the original video.','off'),
 ('prestige','YapTok Prestige','XP, levels, titles and achievements.','off'),
 ('collection','YapTok Collection','Free earned cosmetics unlocked through activity and levels.','off')
on conflict(key) do nothing;
