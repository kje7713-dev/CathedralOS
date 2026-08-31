-- The project snapshot canonicalization trigger is SECURITY INVOKER. Accept All
-- uses the service_role client to update project_snapshots, so service_role must
-- be able to execute the immutable helper called by that trigger.
-- Keep the helper private: do not grant PUBLIC, anon, or authenticated access.
grant execute on function public.project_snapshot_identity_key(jsonb)
  to service_role;
