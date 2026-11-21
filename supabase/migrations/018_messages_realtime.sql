-- 018_messages_realtime.sql
-- Private, per-user Broadcast notifications for direct messages.
--
-- Messages remain inaccessible through the Data API. Realtime only carries a
-- message id; clients fetch the actual conversation through dm_thread(), which
-- performs the existing server-side authorization and read-state update.
--
-- Each authenticated user may subscribe only to user:<their auth uid>.
-- No message body, video id, or other private content is broadcast.

drop policy if exists "Users receive their own YapChat events" on realtime.messages;
create policy "Users receive their own YapChat events"
  on realtime.messages
  for select
  to authenticated
  using (
    extension = 'broadcast'
    and realtime.topic() = 'user:' || (select auth.uid())::text
  );

create or replace function public.broadcast_direct_message()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform realtime.send(
    jsonb_build_object('message_id', new.id),
    'new_message',
    'user:' || new.receiver_id::text,
    true
  );
  return new;
exception
  -- A recipient who is offline may not have opened today's Realtime
  -- partition yet. Never let a best-effort notification roll back a message.
  when others then
    raise warning 'YapChat realtime notification skipped for message %: %', new.id, sqlerrm;
    return new;
end;
$$;

revoke all on function public.broadcast_direct_message() from public, anon, authenticated;

drop trigger if exists messages_broadcast_insert on public.messages;
create trigger messages_broadcast_insert
  after insert on public.messages
  for each row
  execute function public.broadcast_direct_message();

create or replace function public.broadcast_message_read()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform realtime.send(
    jsonb_build_object('message_id', new.id),
    'message_read',
    'user:' || new.sender_id::text,
    true
  );
  return new;
exception
  -- Read receipts are best-effort and must never block the conversation.
  when others then
    raise warning 'YapChat read receipt skipped for message %: %', new.id, sqlerrm;
    return new;
end;
$$;

revoke all on function public.broadcast_message_read() from public, anon, authenticated;

drop trigger if exists messages_broadcast_read on public.messages;
create trigger messages_broadcast_read
  after update of read_at on public.messages
  for each row
  when (old.read_at is null and new.read_at is not null)
  execute function public.broadcast_message_read();
