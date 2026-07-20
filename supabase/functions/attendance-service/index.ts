import { createClient } from 'jsr:@supabase/supabase-js@2';
import { corsHeaders, jsonResponse, errorResponse } from './cors.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY')!;

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  try {
    const authHeader = req.headers.get('Authorization');
    if (!authHeader) return errorResponse('Missing authorization header', 401);

    const client = createClient(SUPABASE_URL, ANON_KEY, {
      global: { headers: { Authorization: authHeader } },
    });

    const { data: { user }, error: userError } = await client.auth.getUser();
    if (userError || !user) return errorResponse('Invalid or expired session', 401);

    const { action, ...body } = await req.json();

    switch (action) {
      case 'clock_in':
        return await clockIn(client, user.id, req);
      case 'clock_out':
        return await clockOut(client, user.id, req);
      case 'get_today':
        return await getToday(client, user.id);
      case 'get_summary':
        return await getSummary(client, body);
      default:
        return errorResponse('Unknown action', 400);
    }
  } catch (e) {
    console.error('[attendance-service] error:', e);
    return errorResponse('Internal error', 500);
  }
});

async function clockIn(client: any, employeeId: string, req: Request) {
  const today = new Date().toISOString().split('T')[0];

  const { data: openEvents } = await client
    .from('clock_events')
    .select('id, event_type')
    .eq('employee_id', employeeId)
    .eq('event_date', today)
    .order('event_ts', { ascending: false })
    .limit(1);

  if (openEvents?.length && openEvents[0].event_type === 'in') {
    return errorResponse('Already clocked in. Clock out first.', 409);
  }

  const { data, error } = await client
    .from('clock_events')
    .insert({
      employee_id: employeeId,
      event_type: 'in',
      ip_address: req.headers.get('x-forwarded-for') ?? 'unknown',
    })
    .select()
    .single();

  if (error) return errorResponse(error.message, 500);
  return jsonResponse({ event: data });
}

async function clockOut(client: any, employeeId: string, req: Request) {
  const today = new Date().toISOString().split('T')[0];

  const { data: openEvents } = await client
    .from('clock_events')
    .select('id, event_type')
    .eq('employee_id', employeeId)
    .eq('event_date', today)
    .order('event_ts', { ascending: false })
    .limit(1);

  if (!openEvents?.length || openEvents[0].event_type === 'out') {
    return errorResponse('Not currently clocked in.', 409);
  }

  const { data, error } = await client
    .from('clock_events')
    .insert({
      employee_id: employeeId,
      event_type: 'out',
      ip_address: req.headers.get('x-forwarded-for') ?? 'unknown',
    })
    .select()
    .single();

  if (error) return errorResponse(error.message, 500);
  return jsonResponse({ event: data });
}

async function getToday(client: any, employeeId: string) {
  const today = new Date().toISOString().split('T')[0];
  const { data, error } = await client
    .from('clock_events')
    .select('event_type, event_time, event_ts')
    .eq('employee_id', employeeId)
    .eq('event_date', today)
    .order('event_ts', { ascending: true });

  if (error) return errorResponse(error.message, 500);
  return jsonResponse({ events: data });
}

async function getSummary(client: any, { from, to, employee_id }: any) {
  // Callers may omit the range entirely (e.g. the ESS attendance widget) —
  // default to a rolling 30-day window instead of building a query with
  // literal "undefined" bounds.
  const todayStr = new Date().toISOString().split('T')[0];
  if (!to) to = todayStr;
  if (!from) {
    const d = new Date();
    d.setDate(d.getDate() - 30);
    from = d.toISOString().split('T')[0];
  }

  let query = client
    .from('clock_events')
    .select('employee_id, event_type, event_date, event_time')
    .gte('event_date', from)
    .lte('event_date', to)
    .order('event_date', { ascending: false });

  if (employee_id) query = query.eq('employee_id', employee_id);

  const { data, error } = await query;
  if (error) return errorResponse(error.message, 500);
  return jsonResponse({ events: data });
}
