-- Replies to a snap (Snapchat's "Replied to X's Snap"): a text sent from the
-- snap viewer points at the snap it answers. Clients only draw the link when
-- the snap is in the same thread they can already read, so pointing at a
-- message elsewhere shows nothing.
alter table public.messages
  add column reply_to uuid references public.messages (id) on delete set null;
