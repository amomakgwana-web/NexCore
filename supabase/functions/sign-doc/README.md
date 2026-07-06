# sign-doc

Public e-signature endpoint (deployed to the live project, verify_jwt=false —
the unguessable 128-bit token is the credential; 14-day expiry, single use).

- GET  ?token=...  -> mobile-friendly signing page (document + pointer-events
  signature pad that works with finger/stylus/mouse)
- POST {token, signature} -> stores the PNG signature, records IP + timestamp,
  marks the request signed

The deployed source is maintained via the Supabase MCP deploy; see the
project's Edge Functions dashboard for the live version.
