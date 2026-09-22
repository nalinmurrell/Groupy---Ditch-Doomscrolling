-- Video snaps. Same storage path scheme as photos (photo_path holds the
-- .mov); the two checks on messages just need to admit the new kind.
alter table public.messages drop constraint messages_kind_check;
alter table public.messages add constraint messages_kind_check
  check (kind in ('text', 'photo', 'video'));

alter table public.messages drop constraint messages_check;
alter table public.messages add constraint messages_check check (
  (kind = 'text'  and body is not null and photo_path is null) or
  (kind in ('photo', 'video') and photo_path is not null and body is null)
);
