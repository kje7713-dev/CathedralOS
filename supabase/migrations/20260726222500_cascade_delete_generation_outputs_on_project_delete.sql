-- Cascade delete generation outputs when a project is deleted via Delete Everywhere.
--
-- Bug: delete_project_lineage previously only removed rows from project_snapshots,
-- leaving generation_outputs orphans in the cloud. On the next sync those orphan
-- outputs were pulled, and GenerationOutputSyncService synthesized a phantom
-- fallback project (GenerationOutputRecoveryProjectResolver.resolveProject) to
-- hold them. The fallback uploaded to cloud under fresh UUIDs, appearing as a
-- "resurrection" of the deleted project under a different (local_project_id,
-- lineage_id) pair — e.g. "Funky monkey" came back as fresh lineage 13b3490c /
-- local 47548DFC after the original 760de5d8 / F107CBAA had been tombstoned
-- and removed.
--
-- Fix: extend delete_project_lineage to also delete matching generation_outputs
-- rows under the same advisory lock. The tombstone pattern, advisory lock, and
-- return contract are unchanged so existing iOS callers continue to work
-- identically; only the side effect of "are all of the user's cloud state for
-- this project gone?" is now actually true.
--
-- Scope: only rows owned by the calling user (SECURITY INVOKER + RLS equivalent)
-- whose project_local_id matches the deleted project's UUID are removed. Output
-- tombstones (sync_tombstones.entity_type = 'generation_output') are intentionally
-- not written here — the delete is the user's intent and matches the existing
-- semantics of project deletion.
--
-- Rollback: drop the additional DELETE statement from delete_project_lineage and
-- recreate the function from migration 20260722165831.

create or replace function public.delete_project_lineage(
  p_lineage_id uuid,
  p_local_project_id text
)
returns table (deleted_count bigint, deletion_confirmed boolean)
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare
  caller_id uuid := (select auth.uid());
  was_previously_deleted boolean;
begin
  if caller_id is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(caller_id::text || ':' || p_lineage_id::text, 0)
  );

  select exists (
    select 1 from public.sync_tombstones t
    where t.user_id = caller_id
      and t.entity_type = 'project'
      and t.lineage_id = p_lineage_id
      and t.deletion_scope = 'everywhere'
      and t.deletion_confirmed_at is not null
  ) into was_previously_deleted;

  insert into public.sync_tombstones (
    user_id, entity_type, local_entity_id, lineage_id, deletion_scope
  ) values (
    caller_id, 'project', p_local_project_id, p_lineage_id, 'everywhere'
  )
  on conflict (user_id, entity_type, lineage_id)
    where entity_type = 'project' and lineage_id is not null
  do update set
    local_entity_id = excluded.local_entity_id,
    deletion_scope = 'everywhere',
    deleted_at = now();

  delete from public.project_snapshots
  where user_id = caller_id and lineage_id = p_lineage_id;
  get diagnostics deleted_count = row_count;

  -- Cascade: also delete any generation_outputs whose local_project_id matches
  -- the deleted project's UUID. Without this, orphan outputs in cloud would be
  -- pulled on the next sync and trigger
  -- GenerationOutputRecoveryProjectResolver to fabricate a fallback project,
  -- which then uploaded to cloud as a phantom "resurrection" of the deleted
  -- project under fresh UUIDs. Same caller, same advisory lock, same
  -- transaction — so a concurrent sync either sees the project + outputs both
  -- alive, or both gone, never the inconsistent state that produced the bug.
  delete from public.generation_outputs
  where user_id = caller_id
    and project_local_id = p_local_project_id;

  if deleted_count = 0 and not was_previously_deleted then
    -- Raising rolls the tombstone insert back too. The client therefore keeps
    -- its local project and may retry after resolving sync state.
    raise exception 'no owned project snapshots found for lineage'
      using errcode = 'P0002';
  end if;
  if deleted_count > 0 then
    update public.sync_tombstones
    set deletion_confirmed_at = now()
    where user_id = caller_id
      and entity_type = 'project'
      and lineage_id = p_lineage_id;
  end if;
  deletion_confirmed := deleted_count > 0 or was_previously_deleted;
  return next;
end;
$$;

revoke all on function public.delete_project_lineage(uuid, text) from public, anon;
grant execute on function public.delete_project_lineage(uuid, text) to authenticated;
