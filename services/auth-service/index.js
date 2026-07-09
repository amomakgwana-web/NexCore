// Hero service: real business logic, not just CRUD.
// Owns user_profiles and otp_codes. Brute-force lockout is enforced via the
// existing Postgres RPCs (record_login_attempt / check_login_lockout) added
// in migration 20250708000005 — the service calls those functions rather
// than re-implementing the throttling rule, so the DB stays the single
// source of truth for the lockout policy. login_attempts itself has an RLS
// policy denying all direct client access, so it is intentionally not
// exposed as a CRUD resource here.
const path = require('path');
const { createService, mountCrud, getSupabaseClient, start } = require(path.join(__dirname, '../_shared/serviceFactory'));

const { app } = createService('auth-service');
const supabase = getSupabaseClient();

mountCrud(app, { table: 'user_profiles', resource: 'profiles', supabase });
mountCrud(app, { table: 'otp_codes', resource: 'otp-codes', supabase });

app.post('/login-attempt', async (req, res) => {
  const { email, success } = req.body || {};
  if (!email || typeof success !== 'boolean') {
    return res.status(400).json({ error: 'email and success (boolean) are required' });
  }
  const { error } = await supabase.rpc('record_login_attempt', { p_email: email, p_success: success });
  if (error) return res.status(500).json({ error: error.message });
  res.status(201).json({ recorded: true });
});

app.get('/lockout-status', async (req, res) => {
  const { email } = req.query;
  if (!email) return res.status(400).json({ error: 'email query param is required' });
  const { data, error } = await supabase.rpc('check_login_lockout', { p_email: email });
  if (error) return res.status(500).json({ error: error.message });
  res.json({ email, locked: !!data });
});

app.get('/profiles/by-email/:email', async (req, res) => {
  // user_profiles has no email column directly (email lives in auth.users);
  // resolve it via the admin API rather than duplicating auth.users data.
  const { data: userList, error: userErr } = await supabase.auth.admin.listUsers();
  if (userErr) return res.status(500).json({ error: userErr.message });
  const match = userList.users.find(u => (u.email || '').toLowerCase() === req.params.email.toLowerCase());
  if (!match) return res.status(404).json({ error: 'no user with that email' });
  const { data, error } = await supabase.from('user_profiles').select('*').eq('id', match.id).maybeSingle();
  if (error) return res.status(500).json({ error: error.message });
  res.json({ data: { ...data, email: match.email } });
});

start(app, 'auth-service');
