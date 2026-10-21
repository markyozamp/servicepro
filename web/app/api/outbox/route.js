// Sends waiting alerts to phones (web push) and email. Called every minute by the database's scheduler
// with the outbox key. Push works today; email turns on when RESEND_API_KEY and ALERT_FROM are set.
import webpush from 'web-push';
import { createClient } from '@supabase/supabase-js';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

const URL_ = process.env.NEXT_PUBLIC_SUPABASE_URL || 'https://svaoljxdoaefdqvvshhv.supabase.co';
const KEY = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY || 'sb_publishable_KqvxfxaerUNeBkVQvwhvZQ_HFviMsbL';
const VAPID_PUBLIC = 'BPA3sWa1d2hEphpa0xf8hRXStbDVc5sQas7SBtmM7Jcqo27JZe0tZi4cjui0VoxaBG4qjvcrMPkqSXf-CZj7MtE';

const realEmail = (e) => e && !/\.demo$|servicepro\.app$/i.test(e);

export async function POST(req) {
  const key = req.headers.get('x-outbox-key');
  if (!key || key !== process.env.OUTBOX_KEY) return new Response('Not allowed', { status: 401 });
  const db = createClient(URL_, KEY, { auth: { persistSession: false } });
  const { data: items, error } = await db.rpc('outbox_take', { p_key: key, p_limit: 100 });
  if (error) return Response.json({ error: error.message }, { status: 500 });

  const origin = process.env.APP_URL || new URL(req.url).origin;
  const canPush = !!process.env.VAPID_PRIVATE_KEY;
  if (canPush) webpush.setVapidDetails('mailto:alerts@servicepro.app', VAPID_PUBLIC, process.env.VAPID_PRIVATE_KEY);
  let pushed = 0; let emailed = 0;

  for (const n of items || []) {
    const link = `${origin}/${n.portal}${n.work_order_id && n.portal !== 'tech' ? `?call=${n.work_order_id}` : ''}`;
    if (canPush) {
      for (const s of n.push || []) {
        try {
          await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } },
            JSON.stringify({ title: n.number ? `All Service Flow · call #${n.number}` : 'All Service Flow', body: n.message, url: link, tag: n.work_order_id || n.id }),
            { TTL: 3600, urgency: 'high' });
          pushed++;
        } catch (e) {
          await db.rpc('outbox_push_failed', { p_key: key, p_endpoint: s.endpoint, p_gone: e.statusCode === 404 || e.statusCode === 410 });
        }
      }
    }
    if (process.env.RESEND_API_KEY && process.env.ALERT_FROM && realEmail(n.email)) {
      const r = await fetch('https://api.resend.com/emails', {
        method: 'POST',
        headers: { Authorization: `Bearer ${process.env.RESEND_API_KEY}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ from: process.env.ALERT_FROM, to: n.email, subject: n.number ? `Call #${n.number}: ${n.message.slice(0, 80)}` : n.message.slice(0, 90),
          text: `${n.message}\n\nOpen All Service Flow: ${link}\n\nYou get this because of your All Service Flow alert settings.` }),
      }).catch(() => null);
      if (r && r.ok) emailed++;
    }
  }
  return Response.json({ taken: (items || []).length, pushed, emailed });
}
