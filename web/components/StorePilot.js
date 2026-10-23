'use client';

// "Pilot stores wanted" on the demo page: the offer and a short sign-up (saved, and emailed to us).
import { useState } from 'react';

export default function StorePilot() {
  const [open, setOpen] = useState(false);
  const [f, setF] = useState({ company: '', name: '', role: '', email: '', phone: '', locations: '', trades: '', calls: '', contractors: '', note: '' });
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');
  const [ok, setOk] = useState(false);
  const set = (k) => (e) => setF({ ...f, [k]: e.target.value });
  return (
    <div className="pilot-offer stack" style={{ gap: 8 }} id="pilot-stores">
      <strong style={{ fontSize: 17 }}>Pilot stores wanted</strong>
      <div className="small">Time Verify is in its pilot phase. We're looking for <strong>4 store companies</strong> to use it on real service calls and help us make it better.</div>
      <ul className="small plan-list">
        <li><strong>Free for the first year,</strong> up to 5 locations.</li>
        <li>After that, <strong>$295 per location</strong> (instead of $395), locked for as long as you're a customer.</li>
        <li>More than 5 locations? The extra ones are $295 each from day one.</li>
        <li>Your contractors join free, as always.</li>
        <li>What we ask: use it on real calls with at least one of your contractors, and a short check-in call with us once a month.</li>
      </ul>
      {ok ? <div className="notice small"><strong>Thank you.</strong> We'll be in touch within a couple of business days.</div>
        : !open ? <div><button className="primary" onClick={() => setOpen(true)}>Apply to be a pilot store</button></div> : (
        <form className="stack" style={{ gap: 6 }} onSubmit={async (e) => {
          e.preventDefault(); setBusy(true); setErr('');
          const note = [f.role && `Role: ${f.role}`, f.trades && `Trades: ${f.trades}`, f.calls && `Service calls per month: ${f.calls}`,
            f.contractors && `Contractors: ${f.contractors}`, f.note && `Note: ${f.note}`].filter(Boolean).join(' · ');
          try {
            const r = await fetch('/api/pilot', { method: 'POST', headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({ company: f.company, name: f.name, email: f.email, phone: f.phone, techs: f.locations, plan: 'store', note, source: 'demo' }) });
            const j = await r.json();
            if (!r.ok) throw new Error(j.error || 'Something went wrong. Email support@servicecallproof.com.');
            setOk(true);
          } catch (x) { setErr(x.message); } finally { setBusy(false); }
        }}>
          <div className="row">
            <label className="grow">Company<input value={f.company} onChange={set('company')} required /></label>
            <label className="grow">Your name<input value={f.name} onChange={set('name')} required /></label>
          </div>
          <div className="row">
            <label className="grow">Your role<select value={f.role} onChange={set('role')}><option value="">Choose…</option><option>Owner</option><option>Director / operations</option><option>Facilities or maintenance manager</option><option>Store manager</option><option>Other</option></select></label>
            <label style={{ flex: '0 0 130px' }}>Locations<input type="number" min="1" max="1000" value={f.locations} onChange={set('locations')} required /></label>
          </div>
          <div className="row">
            <label className="grow">Email<input type="email" value={f.email} onChange={set('email')} /></label>
            <label className="grow">Phone<input type="tel" value={f.phone} onChange={set('phone')} /></label>
          </div>
          <div className="row">
            <label className="grow">Trades you call contractors for<input value={f.trades} onChange={set('trades')} placeholder="e.g. refrigeration, plumbing, HVAC" /></label>
            <label style={{ flex: '0 0 170px' }}>Service calls a month (about)<input value={f.calls} onChange={set('calls')} placeholder="e.g. 10" /></label>
          </div>
          <label>Your contractors (optional)<input value={f.contractors} onChange={set('contractors')} placeholder="e.g. Arctic Air for refrigeration, Prairie Plumbing" /></label>
          <label>Anything else? (optional)<input value={f.note} onChange={set('note')} /></label>
          {err && <div className="small" style={{ color: 'var(--red-fg)' }}>{err}</div>}
          <div className="row"><button className="primary" disabled={busy}>Apply to be a pilot store</button><button type="button" onClick={() => setOpen(false)}>Cancel</button></div>
          <div className="small muted">We pick the 4 pilot stores and contact you either way.</div>
        </form>
      )}
    </div>
  );
}
