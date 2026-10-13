-- Notes: free text, next to ideas and todos in the same table (same sync,
-- same capture paths). A note keeps its whole text in `notes`; `title` is its
-- first line, so lists, search and older apps show something sensible.
alter table public.ideas drop constraint ideas_kind_check;
alter table public.ideas add constraint ideas_kind_check check (kind in ('idea', 'todo', 'note'));
