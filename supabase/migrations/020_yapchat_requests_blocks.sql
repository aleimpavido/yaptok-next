-- 020_yapchat_requests_blocks.sql
-- Message requests and blocking. Non-followed senders start in Requests;
-- the recipient must accept before the conversation becomes readable/replyable.
-- Blocking is symmetric for delivery and hides the conversation from both sides.

create table if not exists public.message_requests (
  sender_id uuid not null references public.profiles(id) on delete cascade,
  receiver_id uuid not null references public.profiles(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending','accepted','declined')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key(sender_id, receiver_id),
  constraint message_requests_not_self check (sender_id <> receiver_id)
);
create index if not exists message_requests_receiver_idx
  on public.message_requests(receiver_id, created_at desc) where status = 'pending';
alter table public.message_requests enable row level security;
revoke all on public.message_requests from anon, authenticated;

-- Existing conversations predate requests. Mark every existing pair accepted
-- so this rollout never locks out people who already chat with each other.
insert into public.message_requests(sender_id, receiver_id, status, created_at, updated_at)
select
  least(m.sender_id, m.receiver_id),
  greatest(m.sender_id, m.receiver_id),
  'accepted',
  min(m.created_at),
  max(m.created_at)
from public.messages m
group by least(m.sender_id, m.receiver_id), greatest(m.sender_id, m.receiver_id)
on conflict (sender_id, receiver_id) do nothing;


create table if not exists public.message_blocks (
  blocker_id uuid not null references public.profiles(id) on delete cascade,
  blocked_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key(blocker_id, blocked_id),
  constraint message_blocks_not_self check (blocker_id <> blocked_id)
);
alter table public.message_blocks enable row level security;
revoke all on public.message_blocks from anon, authenticated;

-- Runs before the existing send_message() inserts. A recipient who follows
-- the sender gets a normal conversation; otherwise the first message opens a
-- request. A pending recipient cannot reply until they accept.
create or replace function public.guard_message_delivery()
returns trigger
language plpgsql
security definer
set search_path = ''
as $q$
declare
  request_row public.message_requests;
  followed boolean;
begin
  if exists (
    select 1 from public.message_blocks b
    where (b.blocker_id = new.sender_id and b.blocked_id = new.receiver_id)
       or (b.blocker_id = new.receiver_id and b.blocked_id = new.sender_id)
  ) then
    raise exception 'user_blocked' using errcode = 'P0001';
  end if;

  select * into request_row from public.message_requests r
    where (r.sender_id = new.sender_id and r.receiver_id = new.receiver_id)
       or (r.sender_id = new.receiver_id and r.receiver_id = new.sender_id)
    limit 1;

  if request_row.sender_id is not null then
    if request_row.status = 'declined' then
      raise exception 'request_declined' using errcode = 'P0001';
    end if;
    if request_row.status = 'pending' and request_row.receiver_id = new.sender_id then
      raise exception 'request_pending' using errcode = 'P0001';
    end if;
    return new;
  end if;

  select exists (
    select 1 from public.follows f
    where f.follower_id = new.receiver_id and f.followee_id = new.sender_id
  ) into followed;

  insert into public.message_requests(sender_id, receiver_id, status)
  values (new.sender_id, new.receiver_id, case when followed then 'accepted' else 'pending' end);

  return new;
end;
$q$;

revoke execute on function public.guard_message_delivery() from public, anon, authenticated;
drop trigger if exists messages_guard_delivery on public.messages;
create trigger messages_guard_delivery
  before insert on public.messages
  for each row execute function public.guard_message_delivery();

-- Hide inbound pending requests and blocked/declined conversations from the
-- ordinary inbox. The sender can still see the request they initiated.
create or replace function public.dm_threads(p_limit int default 40)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $q$
  select case when not public.flag_on('messages', (select auth.uid())) then '[]'::jsonb
  else coalesce((
    select jsonb_agg(jsonb_build_object(
      'with', public.creator_card(p, (select auth.uid())),
      'last', public.message_card(t.last, (select auth.uid())),
      'unread', t.unread
    ) order by (t.last).id desc)
    from (
      select
        case when m.sender_id = (select auth.uid()) then m.receiver_id else m.sender_id end as other,
        (array_agg(m order by m.id desc))[1] as last,
        count(*) filter (where m.receiver_id = (select auth.uid()) and m.read_at is null) as unread
      from public.messages m
      where (select auth.uid()) in (m.sender_id, m.receiver_id)
        and not exists (
          select 1 from public.message_requests r
          where r.status = 'pending' and r.sender_id = case when m.sender_id = (select auth.uid()) then m.receiver_id else m.sender_id end
            and r.receiver_id = (select auth.uid())
        )
        and not exists (
          select 1 from public.message_requests r
          where r.status = 'declined'
            and ((r.sender_id = m.sender_id and r.receiver_id = m.receiver_id)
              or (r.sender_id = m.receiver_id and r.receiver_id = m.sender_id))
        )
        and not exists (
          select 1 from public.message_blocks b
          where (b.blocker_id = (select auth.uid()) and b.blocked_id = case when m.sender_id = (select auth.uid()) then m.receiver_id else m.sender_id end)
             or (b.blocked_id = (select auth.uid()) and b.blocker_id = case when m.sender_id = (select auth.uid()) then m.receiver_id else m.sender_id end)
        )
      group by 1
      order by max(m.id) desc
      limit least(greatest(coalesce(p_limit, 40), 1), 100)
    ) t
    join public.profiles p on p.id = t.other and p.banned_at is null
  ), '[]'::jsonb) end;
$q$;

create or replace function public.dm_thread(p_username text, p_limit int default 60, p_before bigint default null)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $q$
declare
  me uuid := (select auth.uid());
  other public.profiles;
  out jsonb;
begin
  if me is null or not public.flag_on('messages', me) then return null; end if;
  select * into other from public.profiles p
    where lower(p.username) = lower(p_username) and p.banned_at is null;
  if other.id is null or other.id = me then return null; end if;

  if exists (
    select 1 from public.message_blocks b
    where (b.blocker_id = me and b.blocked_id = other.id)
       or (b.blocker_id = other.id and b.blocked_id = me)
  ) then return null; end if;

  if exists (
    select 1 from public.message_requests r
    where ((r.sender_id = me and r.receiver_id = other.id)
        or (r.sender_id = other.id and r.receiver_id = me))
      and r.status = 'declined'
  ) then return null; end if;

  if exists (
    select 1 from public.message_requests r
    where r.sender_id = other.id and r.receiver_id = me and r.status = 'pending'
  ) then return null; end if;

  select jsonb_build_object(
    'with', public.creator_card(other, me),
    'messages', coalesce((
      select jsonb_agg(public.message_card(m, me) order by m.id)
      from (
        select x.* from public.messages x
        where ((x.sender_id = me and x.receiver_id = other.id) or (x.sender_id = other.id and x.receiver_id = me))
          and (p_before is null or x.id < p_before)
        order by x.id desc
        limit least(greatest(coalesce(p_limit, 60), 1), 100)
      ) m
    ), '[]'::jsonb)
  ) into out;

  update public.messages m set read_at = now()
   where m.receiver_id = me and m.sender_id = other.id and m.read_at is null;
  return out;
end;
$q$;

-- Pending requests addressed to the caller. Message contents are returned only
-- to that recipient, never to the public inbox.
create or replace function public.dm_requests()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $q$
  select case when not public.flag_on('messages', (select auth.uid())) then '[]'::jsonb
  else coalesce((
    select jsonb_agg(jsonb_build_object(
      'from', public.creator_card(p, (select auth.uid())),
      'last', public.message_card(m.last_message, (select auth.uid())),
      'created_at', r.created_at
    ) order by r.created_at desc)
    from public.message_requests r
    join public.profiles p on p.id = r.sender_id and p.banned_at is null
    cross join lateral (
      select x as last_message from public.messages x
      where x.sender_id = r.sender_id and x.receiver_id = r.receiver_id
      order by x.id desc limit 1
    ) m
    where r.receiver_id = (select auth.uid()) and r.status = 'pending'
      and not exists (select 1 from public.message_blocks b where (b.blocker_id = r.receiver_id and b.blocked_id = r.sender_id) or (b.blocker_id = r.sender_id and b.blocked_id = r.receiver_id))
  ), '[]'::jsonb) end;
$q$;

create or replace function public.dm_request_action(p_sender uuid, p_accept boolean)
returns text
language plpgsql
volatile
security definer
set search_path = ''
as $q$
declare
  me uuid := (select auth.uid());
  current_status text;
begin
  if me is null then raise exception 'not_signed_in' using errcode = 'P0001'; end if;
  if not public.flag_on('messages', me) then raise exception 'messages_off' using errcode = 'P0001'; end if;
  if public.is_banned(me) then raise exception 'banned' using errcode = 'P0001'; end if;

  select status into current_status from public.message_requests
    where sender_id = p_sender and receiver_id = me for update;
  if p_accept is null then raise exception 'request_action_invalid' using errcode = 'P0001'; end if;
  if current_status is distinct from 'pending' then
    raise exception 'request_not_found' using errcode = 'P0001';
  end if;

  update public.message_requests set status = case when p_accept then 'accepted' else 'declined' end,
    updated_at = now()
    where sender_id = p_sender and receiver_id = me;

  update public.messages set read_at = now()
    where sender_id = p_sender and receiver_id = me and read_at is null;
  if p_accept then return 'accepted'; end if;
  return 'declined';
end;
$q$;

create or replace function public.block_user(p_user uuid)
returns boolean
language plpgsql
volatile
security definer
set search_path = ''
as $q$
declare
  me uuid := (select auth.uid());
begin
  if me is null then raise exception 'not_signed_in' using errcode = 'P0001'; end if;
  if not public.flag_on('messages', me) then raise exception 'messages_off' using errcode = 'P0001'; end if;
  if public.is_banned(me) then raise exception 'banned' using errcode = 'P0001'; end if;
  if p_user = me then raise exception 'self' using errcode = 'P0001'; end if;
  if not exists (select 1 from public.profiles p where p.id = p_user and p.banned_at is null) then
    raise exception 'not_found' using errcode = 'P0001';
  end if;

  insert into public.message_blocks(blocker_id, blocked_id)
  values(me, p_user) on conflict do nothing;
  update public.message_requests set status = 'declined', updated_at = now()
    where status = 'pending'
      and ((sender_id = me and receiver_id = p_user) or (sender_id = p_user and receiver_id = me));
  return true;
end;
$q$;

create or replace function public.unblock_user(p_user uuid)
returns boolean
language plpgsql
volatile
security definer
set search_path = ''
as $q$
declare
  me uuid := (select auth.uid());
begin
  if me is null then raise exception 'not_signed_in' using errcode = 'P0001'; end if;
  if not public.flag_on('messages', me) then raise exception 'messages_off' using errcode = 'P0001'; end if;
  delete from public.message_blocks where blocker_id = me and blocked_id = p_user;
  return true;
end;
$q$;

create or replace function public.my_message_blocks()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $q$
  select case when not public.flag_on('messages', (select auth.uid())) then '[]'::jsonb
    else coalesce(jsonb_agg(jsonb_build_object(
      'id', p.id, 'username', p.username, 'display_name', p.display_name, 'avatar_url', p.avatar_url
    ) order by p.username), '[]'::jsonb) end
  from public.message_blocks b
  join public.profiles p on p.id = b.blocked_id
  where b.blocker_id = (select auth.uid());
$q$;

-- Realtime still carries only an id. A pending request gets a distinct event;
-- the recipient fetches its preview via dm_requests().
create or replace function public.broadcast_direct_message()
returns trigger
language plpgsql
security definer
set search_path = ''
as $q$
declare
  event_name text := 'new_message';
begin
  if exists (
    select 1 from public.message_requests r
    where r.sender_id = new.sender_id and r.receiver_id = new.receiver_id and r.status = 'pending'
  ) then
    event_name := 'message_request';
  end if;
  perform realtime.send(
    jsonb_build_object('message_id', new.id),
    event_name,
    'user:' || new.receiver_id::text,
    true
  );
  return new;
exception when others then
  raise warning 'YapChat realtime notification skipped for message %: %', new.id, sqlerrm;
  return new;
end;
$q$;

revoke execute on function public.dm_requests() from public, anon;
revoke execute on function public.dm_request_action(uuid, boolean) from public, anon;
revoke execute on function public.block_user(uuid) from public, anon;
revoke execute on function public.unblock_user(uuid) from public, anon;
revoke execute on function public.my_message_blocks() from public, anon;
grant execute on function public.dm_requests() to authenticated;
grant execute on function public.dm_request_action(uuid, boolean) to authenticated;
grant execute on function public.block_user(uuid) to authenticated;
grant execute on function public.unblock_user(uuid) to authenticated;
grant execute on function public.my_message_blocks() to authenticated;
