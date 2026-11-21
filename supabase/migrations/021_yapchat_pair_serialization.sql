-- 021_yapchat_pair_serialization.sql
-- Serialize first-contact messages, request decisions and block changes for
-- each user pair. Without a shared transaction lock, simultaneous first
-- messages in opposite directions could create two request rows, or a message
-- could slip through while a block/accept action is being committed.

create or replace function public.lock_message_pair(p_a uuid, p_b uuid)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  if p_a is null or p_b is null or p_a = p_b then
    raise exception 'message_pair_invalid' using errcode = 'P0001';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'yapchat:' || least(p_a, p_b)::text || ':' || greatest(p_a, p_b)::text,
      0
    )
  );
end;
$$;
revoke all on function public.lock_message_pair(uuid, uuid) from public, anon, authenticated;

create or replace function public.lock_message_pair_before_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.lock_message_pair(new.sender_id, new.receiver_id);
  return new;
end;
$$;
revoke all on function public.lock_message_pair_before_insert() from public, anon, authenticated;

-- Trigger names are ordered alphabetically by PostgreSQL. The 00 prefix makes
-- this lock run before messages_guard_delivery on the same INSERT.
drop trigger if exists messages_00_pair_lock on public.messages;
create trigger messages_00_pair_lock
  before insert on public.messages
  for each row execute function public.lock_message_pair_before_insert();

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
  if p_accept is null then raise exception 'request_action_invalid' using errcode = 'P0001'; end if;

  perform public.lock_message_pair(me, p_sender);
  select status into current_status from public.message_requests
    where sender_id = p_sender and receiver_id = me for update;
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

  perform public.lock_message_pair(me, p_user);
  insert into public.message_blocks(blocker_id, blocked_id)
  values(me, p_user) on conflict do nothing;
  update public.message_requests set status = 'blocked', updated_at = now()
    where status = 'pending'
      and ((sender_id = me and receiver_id = p_user) or (sender_id = p_user and receiver_id = me));
  update public.messages set read_at = now()
    where receiver_id = me and sender_id = p_user and read_at is null;
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
  if public.is_banned(me) then raise exception 'banned' using errcode = 'P0001'; end if;
  if p_user = me then raise exception 'self' using errcode = 'P0001'; end if;

  perform public.lock_message_pair(me, p_user);
  delete from public.message_blocks where blocker_id = me and blocked_id = p_user;
  delete from public.message_requests where status = 'blocked'
    and ((sender_id = me and receiver_id = p_user) or (sender_id = p_user and receiver_id = me));
  return true;
end;
$q$;

-- CREATE OR REPLACE preserves the existing authenticated grants from 020.
