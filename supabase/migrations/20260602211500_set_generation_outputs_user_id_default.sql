alter table public.generation_outputs
alter column user_id set default auth.uid();
