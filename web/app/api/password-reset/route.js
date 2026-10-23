import { sendEmail } from '@/lib/email';
// "Forgot password?": issue a one-time reset link and email it. Always answers the same way,
// so the form never reveals whether an email has a login.
import { createClient } from '@supabase/supabase-js';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

const URL_ = process.env.NEXT_PUBLIC_SUPABASE_URL || 'https://svaoljxdoaefdqvvshhv.supabase.co';
const KEY = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY || 'sb_publishable_KqvxfxaerUNeBkVQvwhvZQ_HFviMsbL';

export async function POST(req) {
  const { email } = await req.json().catch(() => ({}));
  const done = Response.json({ ok: true });
  if (!email || !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return done;
  if (!process.env.OUTBOX_KEY || !process.env.RESEND_API_KEY || !process.env.ALERT_FROM) return Response.json({ error: 'Password reset email is not set up yet.' }, { status: 503 });
  const db = createClient(URL_, KEY, { auth: { persistSession: false } });
  const { data, error } = await db.rpc('request_password_reset', { p_key: process.env.OUTBOX_KEY, p_email: email });
  if (error) return Response.json({ error: 'Password reset isn\'t available right now. Ask your administrator for a new sign-in link.' }, { status: 503 });
  if (!data?.ok || !data.token) return done;
  const origin = process.env.APP_URL || new URL(req.url).origin;
  const link = `${origin}/reset/${data.token}`;
  await sendEmail({ to: email, subject: 'Reset your Service Call Proof password',
    greeting: data.name ? `Hi ${String(data.name).split(' ')[0]},` : null,
    lines: ['Someone asked to reset the password for this email on Service Call Proof. The link works once, for 1 hour.'],
    button: { label: 'Set a new password', url: link },
    footerNote: "If this wasn't you, ignore this email; your password stays the same." });
  return done;
}
