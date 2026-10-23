// "I want to pilot this": save the contractor's interest and email it to us (support@ forwards to Mark).
import { createClient } from '@supabase/supabase-js';
import { sendEmail } from '@/lib/email';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

const URL_ = process.env.NEXT_PUBLIC_SUPABASE_URL || 'https://svaoljxdoaefdqvvshhv.supabase.co';
const KEY = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY || 'sb_publishable_KqvxfxaerUNeBkVQvwhvZQ_HFviMsbL';
const PLANS = { base: 'Base', pro: 'Pro', enterprise: 'Enterprise' };

export async function POST(req) {
  const b = await req.json().catch(() => ({}));
  const auth = req.headers.get('authorization');
  const db = createClient(URL_, KEY, { auth: { persistSession: false }, global: auth ? { headers: { Authorization: auth } } : {} });
  const { error } = await db.rpc('pilot_signup', {
    p_company: b.company || '', p_name: b.name || '', p_email: b.email || null, p_phone: b.phone || null,
    p_techs: b.techs ? Number(b.techs) : null, p_plan: b.plan || null, p_note: b.note || null, p_source: b.source === 'demo' ? 'demo' : 'app',
  });
  if (error) return Response.json({ error: error.message }, { status: 400 });
  if (process.env.RESEND_API_KEY && process.env.ALERT_FROM) {
    await sendEmail({
      to: 'support@servicecallproof.com',
      subject: `Pilot contractor: ${b.company} (${PLANS[b.plan] || 'any plan'})`,
      greeting: 'New pilot sign-up',
      lines: [
        `Company: ${b.company}`, `Name: ${b.name}`, `Email: ${b.email || '—'}`, `Phone: ${b.phone || '—'}`,
        `Technicians: ${b.techs || '—'}`, `Interested in: ${PLANS[b.plan] || 'not sure yet'}`,
        `From: ${b.source === 'demo' ? 'the demo page' : 'the app (Upgrade screen)'}`, b.note ? `Note: ${b.note}` : '',
      ].filter(Boolean),
    }).catch(() => {});
  }
  return Response.json({ ok: true });
}
