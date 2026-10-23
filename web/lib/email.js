// One way to send email: plain text + a simple HTML version (spam filters trust that more than text alone),
// a reply-to people can answer, and the same short footer every time.
const esc = (s) => String(s ?? '').replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

export function buildEmail({ greeting, lines = [], button, footerNote }) {
  const site = 'servicecallproof.com';
  const text = [greeting, ...lines, button ? `${button.label}: ${button.url}` : null,
    footerNote, `Service Call Proof · ${site}\nQuestions? Reply to this email or write support@${site}.`].filter(Boolean).join('\n\n');
  const html = `<!doctype html><html><body style="margin:0;padding:0;background:#f3f5f7">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f3f5f7;padding:24px 12px"><tr><td align="center">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:520px;background:#ffffff;border-radius:10px;font-family:Arial,Helvetica,sans-serif;color:#1b2733">
<tr><td style="padding:18px 22px;border-bottom:1px solid #e1e6eb;font-weight:800;font-size:16px">Service Call <span style="color:#1565c0">Proof</span></td></tr>
<tr><td style="padding:20px 22px;font-size:15px;line-height:1.5">
${greeting ? `<p style="margin:0 0 12px">${esc(greeting)}</p>` : ''}
${lines.map((l) => `<p style="margin:0 0 12px">${esc(l).replace(/\n/g, '<br>')}</p>`).join('\n')}
${button ? `<p style="margin:18px 0"><a href="${esc(button.url)}" style="display:inline-block;background:#1565c0;color:#ffffff;text-decoration:none;font-weight:700;padding:11px 18px;border-radius:8px">${esc(button.label)}</a></p>
<p style="margin:0 0 12px;font-size:12px;color:#5b6b7a">Or copy this link: ${esc(button.url)}</p>` : ''}
${footerNote ? `<p style="margin:12px 0 0;font-size:12px;color:#5b6b7a">${esc(footerNote)}</p>` : ''}
</td></tr>
<tr><td style="padding:14px 22px;border-top:1px solid #e1e6eb;font-size:12px;color:#5b6b7a">Service Call Proof · ${site}<br>Questions? Reply to this email or write support@${site}.</td></tr>
</table></td></tr></table></body></html>`;
  return { text, html };
}

export async function sendEmail({ to, subject, ...content }) {
  if (!process.env.RESEND_API_KEY || !process.env.ALERT_FROM) return { ok: false, status: 503, detail: 'Email is not set up' };
  const { text, html } = buildEmail(content);
  const r = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: { Authorization: `Bearer ${process.env.RESEND_API_KEY}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ from: process.env.ALERT_FROM, to, subject, text, html, reply_to: 'support@servicecallproof.com' }),
  }).catch(() => null);
  return { ok: !!(r && r.ok), status: r?.status, detail: r && !r.ok ? (await r.text()).slice(0, 300) : undefined };
}
