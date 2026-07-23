-- Two prior migrations (20250704000001, 20250705000001) already tried to
-- revoke EXECUTE on audit_write/nx_check_rate/rls_auto_enable from anon and
-- authenticated, and this session's own 20260720000001 just tried again --
-- yet the security advisor still flagged all three as callable by anon.
-- Reason: Postgres grants EXECUTE ... TO PUBLIC by default when a function
-- is created, and none of those migrations ever revoked from PUBLIC itself.
-- Revoking from a named role is a no-op when PUBLIC still holds the grant,
-- since every role's effective privileges are the union of its own grants
-- and PUBLIC's. Fix it at the actual source this time.

revoke execute on function public.audit_write(text, text, text, numeric, text, jsonb) from public;
revoke execute on function public.nx_check_rate(uuid, text, integer, integer) from public;
revoke execute on function public.rls_auto_enable() from public;

-- Keep them usable for server-side/internal callers (service_role, triggers).
grant execute on function public.audit_write(text, text, text, numeric, text, jsonb) to service_role;
grant execute on function public.nx_check_rate(uuid, text, integer, integer) to service_role;
grant execute on function public.rls_auto_enable() to service_role;
