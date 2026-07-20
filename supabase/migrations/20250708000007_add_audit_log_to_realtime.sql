-- Audit Trail was pinned to a hardcoded seed array with no live updates.
-- Add audit_log to the realtime publication so INSERTs (writeAudit() calls
-- from any signed-in device) stream to every open Audit Trail page, matching
-- the pattern already used for chat_messages/approvals/notifications etc.
ALTER PUBLICATION supabase_realtime ADD TABLE audit_log;
