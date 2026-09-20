-- Delete your own messages (and the photo behind them). Run once in the
-- SQL editor. (schema.sql includes it for fresh projects.)

-- Only the sender can delete a message.
create policy "senders delete their own messages"
  on public.messages for delete to authenticated
  using (sender_id = auth.uid());

-- The photo file goes too. Gated on the message you sent that points at
-- it, so nobody can remove someone else's snap from a shared folder.
create policy "senders delete their snaps"
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'snaps'
    and exists (
      select 1 from public.messages m
      where m.photo_path = storage.objects.name and m.sender_id = auth.uid()
    )
  );
