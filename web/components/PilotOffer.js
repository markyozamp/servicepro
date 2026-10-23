'use client';

// The contractor plans (Time Verify free → Base → Pro → Enterprise) and the founding-pilot offer.
// Used on the contractor's Upgrade screen and on the public demo page.
import { useState } from 'react';
import { supabase } from '@/lib/supabase';

export const CONTRACTOR_PLANS = [
  { key: 'verify', name: 'Time Verify', tag: 'Free', who: 'Any contractor a customer invites',
    items: ['Calls from your Time Verify customers', 'I\'m going / I\'m here / Leaving on the tech\'s phone', 'Check-in codes and parts runs', 'Send your bill in seconds against the customer\'s PO', 'Your rates on record with each customer'],
    note: 'Free for you when your customer uses Time Verify, always.' },
  { key: 'base', name: 'Base', tag: 'Coming', who: 'The 1–3 truck shop',
    items: ['Everything in Time Verify, plus:', 'All your own customers, not just the ones on Service Call Proof', 'Schedule your techs', 'Timesheets', 'Quotes, including install and project quotes sent straight to your customers to compare and approve', 'Billing from here: the bill is written for you from the verified time, your rates, trip fee and zones', 'Invoices to any customer', 'Bills go straight into your Time Verify customers\' portal: no mailing or emailing', 'Temperature monitoring for your customers: sensors in their coolers, freezers and buildings alert you and them when it gets too hot or too cold. Install it and bill it as a monthly service', 'Accounting: export to QuickBooks'],
    note: 'One flat monthly price, up to 3 technicians.' },
  { key: 'pro', name: 'Pro', tag: 'Coming', who: 'The growing shop, about 4–20 techs',
    items: ['Everything in Base, plus:', 'Dispatch board', 'Preventive maintenance and service agreements', 'Full estimating: good / better / best project quotes your customers approve with a tap', 'An approved quote becomes the job by itself; install handoff from sales to the crew', 'Job costing: labor, parts and profit per job', 'Accounting: live sync with QuickBooks Online and Xero', 'Bring your data: import customers, equipment and agreements from ServiceTitan, Housecall Pro, Jobber and others', 'Add-on: light CRM (leads, follow-ups, agreement renewals)'],
    note: 'Priced per active technician.' },
  { key: 'enterprise', name: 'Enterprise', tag: 'Coming', who: 'Multi-branch companies',
    items: ['Everything in Pro, plus:', 'Multiple branches', 'Full CRM and renewals', 'QR inventory: shelf and truck stock scanned to the job', 'Map-drawn service zones', 'Accounting: QuickBooks Desktop and Sage on request', 'We move your data over for you from ServiceTitan and others'],
    note: 'Priced by quote.' },
];

export function PilotForm({ source = 'app', defaults = {}, onDone }) {
  const [f, setF] = useState({ company: defaults.company || '', name: defaults.name || '', email: defaults.email || '', phone: defaults.phone || '', techs: '', plan: defaults.plan || 'base', note: '' });
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');
  const [ok, setOk] = useState(false);
  const set = (k) => (e) => setF({ ...f, [k]: e.target.value });
  if (ok) return <div className="notice small"><strong>Thanks, you're on the list.</strong> We'll reach out about the pilot soon.</div>;
  return (
    <form className="stack" style={{ gap: 6 }} onSubmit={async (e) => {
      e.preventDefault(); setBusy(true); setErr('');
      try {
        const { data } = await supabase.auth.getSession();
        const tok = data?.session?.access_token;
        const r = await fetch('/api/pilot', { method: 'POST', headers: { 'Content-Type': 'application/json', ...(tok ? { Authorization: `Bearer ${tok}` } : {}) }, body: JSON.stringify({ ...f, source }) });
        const j = await r.json();
        if (!r.ok) throw new Error(j.error || 'Something went wrong. Email support@servicecallproof.com.');
        setOk(true); onDone?.();
      } catch (x) { setErr(x.message); } finally { setBusy(false); }
    }}>
      <div className="row">
        <label className="grow">Company<input value={f.company} onChange={set('company')} required /></label>
        <label className="grow">Your name<input value={f.name} onChange={set('name')} required /></label>
      </div>
      <div className="row">
        <label className="grow">Email<input type="email" value={f.email} onChange={set('email')} /></label>
        <label className="grow">Phone<input type="tel" value={f.phone} onChange={set('phone')} /></label>
      </div>
      <div className="row">
        <label style={{ flex: '0 0 130px' }}>Technicians<input type="number" min="1" max="1000" value={f.techs} onChange={set('techs')} /></label>
        <label className="grow">Interested in<select value={f.plan} onChange={set('plan')}><option value="base">Base</option><option value="pro">Pro</option><option value="enterprise">Enterprise</option></select></label>
      </div>
      <label>Anything we should know? (optional)<input value={f.note} onChange={set('note')} placeholder="e.g. Refrigeration, 2 trucks, mostly grocery" /></label>
      {err && <div className="small" style={{ color: 'var(--red-fg)' }}>{err}</div>}
      <div><button className="primary" disabled={busy}>I want to pilot this</button></div>
    </form>
  );
}

export default function PilotOffer({ source = 'app', current = 'verify', defaults }) {
  const [form, setForm] = useState(false);
  return (
    <div className="stack" style={{ gap: 10 }}>
      <div className="pilot-offer stack" style={{ gap: 6 }}>
        <strong style={{ fontSize: 16 }}>Founding contractors wanted</strong>
        <div className="small">We're looking for a few contractors to pilot <strong>Base, Pro and Enterprise</strong> and help shape them before launch.
          Pilot contractors get <strong>2 years free</strong>, then <strong>50% off for as long as you're a customer</strong>.</div>
        <div className="small"><strong>Bring a customer onto Time Verify:</strong> $100 off your next renewal for every customer company that signs up.</div>
        {form ? <PilotForm source={source} defaults={defaults} /> : <div><button className="primary" onClick={() => setForm(true)}>I want to pilot this</button></div>}
      </div>
      <div className="small enhanced-note"><strong>Enhanced Time Verify for your customers, at no charge:</strong> when you're on Base or Pro, the customers you serve automatically get your bills right in their portal, matched to the call and PO, ready to download, export or forward to their accounting department.</div>
      <div className="plan-grid">
        {CONTRACTOR_PLANS.map((p) => (
          <div key={p.key} className={`panel panel-pad stack plan-card${p.key === current ? ' current' : ''}`} style={{ gap: 6 }}>
            <div className="spread"><strong style={{ fontSize: 16 }}>{p.name}</strong>
              <span className={p.tag === 'Free' ? 'chip tone-green' : 'chip tone-amber'}>{p.key === current ? 'Your plan' : p.tag === 'Free' ? 'Free' : 'Coming: piloting now'}</span></div>
            <div className="small muted">{p.who}</div>
            <ul className="small plan-list">{p.items.map((i) => <li key={i} className={i.endsWith('plus:') ? 'plus' : ''}>{i}</li>)}</ul>
            <div className="small muted">{p.note}</div>
          </div>
        ))}
      </div>
    </div>
  );
}
