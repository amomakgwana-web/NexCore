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
      case 'request_leave':   return await requestLeave(client, user.id, body);
      case 'get_my_leave':    return await getMyLeave(client, user.id);
      case 'get_balance':     return await getBalance(client, user.id);
      case 'approve_leave':   return await reviewLeave(client, user.id, body.request_id, 'approved');
      case 'reject_leave':    return await reviewLeave(client, user.id, body.request_id, 'rejected');
      case 'get_all_leave':   return await getAllLeave(client, body.status);
      case 'get_all_balances': return await getAllBalances(client);
      case 'request_medical': return await requestMedical(client, body.request_id);
      case 'attach_medical_report': return await attachMedicalReport(client, body.request_id, body.url);
      default: return errorResponse('Unknown action', 400);
    }
  } catch (e) {
    console.error('[leave-service] error:', e);
    return errorResponse('Internal error', 500);
  }
});

function daysBetween(from: string, to: string): number {
  const d1 = new Date(from), d2 = new Date(to);
  return Math.round((d2.getTime() - d1.getTime()) / 86400000) + 1;
}

async function requestLeave(client: any, employeeId: string, { leave_type, date_from, date_to, reason }: any) {
  if (!leave_type || !date_from || !date_to) {
    return errorResponse('leave_type, date_from, and date_to are required', 400);
  }
  if (new Date(date_to) < new Date(date_from)) {
    return errorResponse('date_to must be on or after date_from', 400);
  }

  const days = daysBetween(date_from, date_to);

  const { data, error } = await client
    .from('leave_requests')
    .insert({
      employee_id: employeeId,
      leave_type,
      date_from,
      date_to,
      days_count: days,
      reason: reason ?? null,
      status: 'pending',
    })
    .select()
    .single();

  if (error) return errorResponse(error.message, 500);
  return jsonResponse({ request: data });
}

async function getMyLeave(client: any, employeeId: string) {
  const { data, error } = await client
    .from('leave_requests')
    .select('*')
    .eq('employee_id', employeeId)
    .order('created_at', { ascending: false });

  if (error) return errorResponse(error.message, 500);
  return jsonResponse({ requests: data });
}

async function getBalance(client: any, employeeId: string) {
  const { data, error } = await client
    .from('leave_balances')
    .select('*')
    .eq('employee_id', employeeId)
    .single();

  if (error && error.code !== 'PGRST116') return errorResponse(error.message, 500);

  return jsonResponse({
    balance: data ?? {
      employee_id: employeeId,
      paid_used: 0, paid_max: 21,
      sick_used: 0, sick_max: 30,
      unpaid_used: 0,
    },
  });
}

/* Two-stage review mirroring the Claims SOP (manager, then final sign-off):
   pending -> manager_approved -> approved. Reject is allowed from either
   open stage. Leave balance is only credited on the final approval, not the
   manager stage, matching how claims only post to GL once fully approved. */
async function reviewLeave(client: any, reviewerId: string, requestId: string, decision: 'approved' | 'rejected') {
  if (!requestId) return errorResponse('request_id required', 400);

  const { data: current, error: fetchErr } = await client
    .from('leave_requests')
    .select('*')
    .eq('id', requestId)
    .single();
  if (fetchErr || !current) return errorResponse('Request not found', 404);

  if (decision === 'rejected') {
    const { data, error } = await client
      .from('leave_requests')
      .update({ status: 'rejected', reviewed_by: reviewerId, reviewed_at: new Date().toISOString() })
      .eq('id', requestId)
      .in('status', ['pending', 'manager_approved'])
      .select()
      .single();
    if (error || !data) {
      return errorResponse('Could not reject — it may already be reviewed or you lack permission.', 403);
    }
    return jsonResponse({ request: data, stage: 'rejected' });
  }

  if (current.status === 'pending') {
    const { data, error } = await client
      .from('leave_requests')
      .update({ status: 'manager_approved', reviewed_by: reviewerId, reviewed_at: new Date().toISOString() })
      .eq('id', requestId)
      .eq('status', 'pending')
      .select()
      .single();
    if (error || !data) {
      return errorResponse('Could not approve — it may already be reviewed or you lack permission.', 403);
    }
    return jsonResponse({ request: data, stage: 'manager_approved' });
  }

  if (current.status === 'manager_approved') {
    const { data, error } = await client
      .from('leave_requests')
      .update({ status: 'approved', reviewed_by: reviewerId, reviewed_at: new Date().toISOString() })
      .eq('id', requestId)
      .eq('status', 'manager_approved')
      .select()
      .single();
    if (error || !data) {
      return errorResponse('Could not finalize — it may already be reviewed or you lack permission.', 403);
    }

    const balanceField = data.leave_type === 'paid' ? 'paid_used'
                        : data.leave_type === 'sick' ? 'sick_used'
                        : data.leave_type === 'unpaid' ? 'unpaid_used'
                        : null;
    if (balanceField) {
      const { data: bal } = await client
        .from('leave_balances')
        .select('*')
        .eq('employee_id', data.employee_id)
        .single();

      const currentBal = bal?.[balanceField] ?? 0;
      await client
        .from('leave_balances')
        .upsert({ employee_id: data.employee_id, [balanceField]: currentBal + Number(data.days_count) });
    }
    return jsonResponse({ request: data, stage: 'approved' });
  }

  return errorResponse('This request has already been fully reviewed.', 400);
}

async function getAllLeave(client: any, status?: string) {
  let query = client.from('leave_requests').select('*, user_profiles!employee_id(full_name)').order('created_at', { ascending: false });
  if (status) query = query.eq('status', status);
  const { data, error } = await query;
  if (error) return errorResponse(error.message, 500);
  return jsonResponse({ requests: data });
}

async function getAllBalances(client: any) {
  const { data, error } = await client
    .from('leave_balances')
    .select('*, user_profiles!employee_id(full_name)');
  if (error) return errorResponse(error.message, 500);
  return jsonResponse({ balances: data });
}

async function requestMedical(client: any, requestId: string) {
  if (!requestId) return errorResponse('request_id required', 400);
  const { data, error } = await client
    .from('leave_requests')
    .update({ medical_requested: true })
    .eq('id', requestId)
    .select()
    .single();
  if (error || !data) return errorResponse('Could not flag medical request — you may lack permission.', 403);
  return jsonResponse({ request: data });
}

async function attachMedicalReport(client: any, requestId: string, url: string) {
  if (!requestId || !url) return errorResponse('request_id and url are required', 400);
  const { data, error } = await client
    .from('leave_requests')
    .update({ medical_report_url: url })
    .eq('id', requestId)
    .select()
    .single();
  if (error || !data) return errorResponse('Could not attach report — you may lack permission.', 403);
  return jsonResponse({ request: data });
}
