-- Ideas have no lifecycle any more: an idea is an idea (optionally under a
-- project), a todo is open or done (done_at).
alter table public.ideas drop column status;
