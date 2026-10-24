// A store's gateway sends its sensors' readings here (its own private address: /api/monitor/<token>).
// Each brand's format is translated to { id, at, temp_c | temp_f, door_open, battery } and handed to the database,
// which checks the limits and raises alarms. Milesight (built-in network server, HTTP data forwarding with the payload
// codec on), The Things Network / ChirpStack style uplinks, Monnit webhooks, and a plain format are understood.
import { createClient } from '@supabase/supabase-js';
import { translate } from '@/lib/monitorFormats';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

const URL_ = process.env.NEXT_PUBLIC_SUPABASE_URL || 'https://svaoljxdoaefdqvvshhv.supabase.co';
const KEY = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY || 'sb_publishable_KqvxfxaerUNeBkVQvwhvZQ_HFviMsbL';
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export async function POST(req, { params }) {
  const { token } = await params;
  if (!UUID.test(token || '')) return Response.json({ error: 'Unknown gateway.' }, { status: 404 });
  let body;
  try { body = await req.json(); } catch { return Response.json({ error: 'Send JSON.' }, { status: 400 }); }
  const readings = translate(body).slice(0, 200);
  if (!readings.length) return Response.json({ ok: true, recorded: 0, note: 'No sensor readings found in that message.' });
  const db = createClient(URL_, KEY, { auth: { persistSession: false } });
  const { data, error } = await db.rpc('monitor_ingest', { p_token: token, p_readings: readings });
  if (error) return Response.json({ error: error.message }, { status: /Unknown gateway/.test(error.message) ? 404 : 400 });
  return Response.json(data);
}

// A quick check from a browser that the address is right
export async function GET() {
  return Response.json({ ok: true, note: 'This is a Service Call Proof gateway address. Gateways POST their readings here.' });
}
