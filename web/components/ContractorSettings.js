'use client';

// Store admin: your contractors (Time Verify or full), who gets which trade, inviting a contractor,
// and the PIN employees use with the QR stickers.
import { useEffect, useState } from 'react';
import { supabase, act, q } from '@/lib/supabase';
import { ErrorBox, Notice } from './bits';

export default function ContractorSettings({ onClose }) {
  const [cc, setCc] = useState([]);
  const [trades, setTrades] = useState([]);
  const [tc, setTc] = useState([]);
  const [sites, setSites] = useState([]);
  const [links, setLinks] = useState([]);
  const [inv, setInv] = useState(null);
  const [sent, setSent] = useState(null);
  const [pins, setPins] = useState({});
  const [err, setErr] = useState('');
  const [msg, setMsg] = useState('');
  const [busy, setBusy] = useState(false);

  async function load() {
    try {
      const [a, b, c, d, e] = await Promise.all([
        q(supabase.from('customer_contractors').select('contractor_id, mode, pays_travel, unverified_time, terms_accepted_at, accept_emergency_min, accept_normal_min, min_hours, increment_min, is_primary, contractors(name, phone, email)').order('created_at')),
        q(supabase.from('trades').select('id, name').order('id')),
        q(supabase.from('trade_contractors').select('site_id, trade_id, contractor_id')),
        q(supabase.from('sites').select('id, name').order('name')),
        q(supabase.from('join_links').select('token, full_name, email, phone, used_at, expires_at, contractors(name)').eq('kind', 'contractor_owner').order('created_at', { ascending: false })),
      ]);
      const recs = await Promise.all(a.map((r) => act('contractor_record', { p_contractor: r.contractor_id }).catch(() => null)));
      setCc(a.map((r, i) => ({ ...r, rec: recs[i] }))); setTrades(b); setTc(c); setLinks(e);
      const has = await Promise.all(d.map((s) => act('site_has_report_pin', { p_site: s.id })));
      setSites(d.map((s, i) => ({ ...s, has_pin: has[i] })));
    } catch (x) { setErr(x.message); }
  }
  useEffect(() => { load(); }, []);

  async function run(fn, args, done) {
    setBusy(true); setErr(''); setMsg('');
    try { const r = await act(fn, args); if (done) done(r); await load(); } catch (x) { setErr(x.message); } finally { setBusy(false); }
  }
  const setRow = (id, k, v) => setCc(cc.map((r) => (r.contractor_id === id ? { ...r, [k]: v } : r)));
  const link = (tok) => `${window.location.origin}/join/${tok}`;

  return (
    <div className="panel panel-pad stack">
      <div className="spread"><h2>Contractors &amp; reporting</h2><button onClick={onClose}>Close</button></div>
      <ErrorBox error={err} /><Notice>{msg}</Notice>

      <h3>Your contractors</h3>
      {cc.map((r) => (
        <div key={r.contractor_id} className="stack" style={{ gap: 6, borderTop: '1px solid var(--line)', paddingTop: 10 }}>
          <div><strong>{r.contractors?.name}</strong> <span className="small muted">{r.contractors?.phone || ''}</span></div>
          <div className="row">
            <label className="grow">How you work with them
              <select value={r.mode} onChange={(e) => setRow(r.contractor_id, 'mode', e.target.value)}>
                <option value="verify">Time Verify — PO, accept, verified time, invoice check</option>
                <option value="full">Full — approval letters, live cost, photos</option>
              </select></label>
            <label className="grow">We pay travel time
              <select value={r.pays_travel} onChange={(e) => setRow(r.contractor_id, 'pays_travel', e.target.value)}>
                <option value="yes">Yes</option><option value="no">No</option><option value="after_hours">After hours only</option>
              </select></label>
          </div>
          <div className="row">
            <label className="grow">Emergency calls must be accepted within (min)<input type="number" min="5" max="240" value={r.accept_emergency_min} onChange={(e) => setRow(r.contractor_id, 'accept_emergency_min', e.target.value)} /></label>
            <label className="grow">Other calls within (min)<input type="number" min="15" max="4320" step="15" value={r.accept_normal_min} onChange={(e) => setRow(r.contractor_id, 'accept_normal_min', e.target.value)} /></label>
          </div>
          <label>Time not verified in All Service Flow
            <select value={r.unverified_time} onChange={(e) => setRow(r.contractor_id, 'unverified_time', e.target.value)}>
              <option value="review">We review it case by case</option>
              <option value="no_pay">We don't pay it</option>
            </select></label>
          <div className="small muted">Their terms: {Number(r.min_hours)} h minimum per visit, billed in {r.increment_min}-minute steps (they set this).
            {r.terms_accepted_at ? ` Accepted your terms ${new Date(r.terms_accepted_at).toLocaleDateString()}.` : ''}</div>
          {r.rec && <Record rec={r.rec} />}
          <button disabled={busy} onClick={async () => {
            await run('set_unverified_rule', { p_contractor: r.contractor_id, p_rule: r.unverified_time });
            await run('set_contractor_terms', { p_contractor: r.contractor_id, p_mode: r.mode, p_pays_travel: r.pays_travel,
              p_accept_emergency_min: Number(r.accept_emergency_min), p_accept_normal_min: Number(r.accept_normal_min) }, () => setMsg(`Saved ${r.contractors?.name}.`));
          }}>Save</button>
        </div>
      ))}

      <h3 style={{ marginTop: 8 }}>Who gets which kind of call (all locations)</h3>
      <table><tbody>
        {trades.map((t) => {
          const cur = tc.find((x) => !x.site_id && x.trade_id === t.id)?.contractor_id || '';
          return (
            <tr key={t.id}><td>{t.name}</td><td>
              <select value={cur} disabled={busy} onChange={(e) => run('set_trade_contractor', { p_site: null, p_trade: t.id, p_contractor: e.target.value || null })}>
                <option value="">Main contractor</option>
                {cc.map((c) => <option key={c.contractor_id} value={c.contractor_id}>{c.contractors?.name}</option>)}
              </select></td></tr>
          );
        })}
      </tbody></table>

      <h3 style={{ marginTop: 8 }}>Invite a contractor to Time Verify</h3>
      <div className="small muted">Free for them. They get a sign-in link — no password. Calls for the trades you pick go to them.</div>
      {sent ? (
        <div className="notice stack" style={{ gap: 6 }}>
          <div>Send this sign-in link to <strong>{sent.name}</strong> (works once, for 7 days):</div>
          <input readOnly value={link(sent.token)} onFocus={(e) => e.target.select()} />
          <div className="row">
            <button onClick={() => navigator.clipboard?.writeText(link(sent.token)).then(() => setMsg('Link copied.'))}>Copy link</button>
            {sent.email && <a className="button" href={`mailto:${sent.email}?subject=${encodeURIComponent('Service calls from us — your sign-in link')}&body=${encodeURIComponent(`Hi ${sent.name},\n\nWe'll send our service calls through All Service Flow. It's free for you. Tap to sign in (no password):\n${link(sent.token)}\n\nThanks`)}`}><button type="button">Email it</button></a>}
            {sent.phone && <a href={`sms:${sent.phone}?&body=${encodeURIComponent(`Our service calls now come through All Service Flow (free for you). Sign in: ${link(sent.token)}`)}`}><button type="button">Text it</button></a>}
            <button onClick={() => setSent(null)}>Done</button>
          </div>
        </div>
      ) : inv ? (
        <form className="stack" style={{ gap: 6 }} onSubmit={(e) => {
          e.preventDefault();
          run('invite_contractor', { p_company: inv.company, p_contact_name: inv.name, p_email: inv.email || null, p_phone: inv.phone || null,
            p_trade_ids: inv.trades }, (r) => { setSent({ token: r.token, name: inv.name, email: inv.email, phone: inv.phone }); setInv(null); });
        }}>
          <div className="row">
            <label className="grow">Company<input value={inv.company} onChange={(e) => setInv({ ...inv, company: e.target.value })} required /></label>
            <label className="grow">Contact name<input value={inv.name} onChange={(e) => setInv({ ...inv, name: e.target.value })} required /></label>
          </div>
          <div className="row">
            <label className="grow">Email<input type="email" value={inv.email} onChange={(e) => setInv({ ...inv, email: e.target.value })} /></label>
            <label className="grow">Mobile<input value={inv.phone} onChange={(e) => setInv({ ...inv, phone: e.target.value })} /></label>
          </div>
          <div className="row" style={{ gap: 10 }}>
            {trades.map((t) => (
              <label key={t.id} className="row small" style={{ gap: 4, fontWeight: 400 }}>
                <input type="checkbox" style={{ width: 'auto' }} checked={inv.trades.includes(t.id)}
                  onChange={(e) => setInv({ ...inv, trades: e.target.checked ? [...inv.trades, t.id] : inv.trades.filter((x) => x !== t.id) })} />{t.name}
              </label>
            ))}
          </div>
          <div className="row"><button className="primary" disabled={busy}>Create sign-in link</button><button type="button" onClick={() => setInv(null)}>Cancel</button></div>
        </form>
      ) : <button onClick={() => setInv({ company: '', name: '', email: '', phone: '', trades: [] })}>+ Invite a contractor</button>}
      {links.filter((l) => !l.used_at).length > 0 && (
        <div className="small muted">Waiting to sign in: {links.filter((l) => !l.used_at).map((l) => `${l.contractors?.name} (${l.full_name}${new Date(l.expires_at) < new Date() ? ', link expired' : ''})`).join(', ')}</div>
      )}

      <h3 style={{ marginTop: 8 }}>QR stickers on your equipment</h3>
      <div className="small muted">Any employee scans the sticker on a unit, enters the store PIN, picks the problem — the call goes to the right contractor and knows which unit it is.</div>
      {sites.map((s) => (
        <div key={s.id} className="row">
          <span className="grow">{s.name} {s.has_pin ? <span className="chip tone-green">PIN set</span> : <span className="chip tone-amber">no PIN yet</span>}</span>
          <input style={{ width: 120 }} inputMode="numeric" placeholder="New PIN" value={pins[s.id] || ''} onChange={(e) => setPins({ ...pins, [s.id]: e.target.value.replace(/\D/g, '') })} />
          <button disabled={busy || (pins[s.id] || '').length < 4} onClick={() => run('set_report_pin', { p_site: s.id, p_pin: pins[s.id] }, () => { setPins({ ...pins, [s.id]: '' }); setMsg(`PIN saved for ${s.name}.`); })}>Save PIN</button>
        </div>
      ))}
      <a href="/store/stickers" target="_blank" rel="noreferrer"><button type="button">Print QR stickers</button></a>
    </div>
  );
}

// How this contractor has worked with you over the last 90 days
function Record({ rec }) {
  const pct = (a, b) => (b ? `${Math.round((a / b) * 100)}%` : '—');
  const rows = [
    ['Calls', rec.calls],
    ['Accepted on time', `${pct(rec.accepted_on_time, rec.accept_due)} (${rec.accepted_on_time} of ${rec.accept_due})`],
    ['Trips checked in with your code', `${pct(rec.checked_in_code, rec.trips)} (${rec.checked_in_code} of ${rec.trips})`],
    ['Arrivals your staff had to record', rec.arrival_by_store],
    ['Missed time windows', rec.missed_windows],
    ['Unscheduled visits', rec.unscheduled_visits],
    ['Invoices with unexplained hours', `${rec.invoices_unexplained} of ${rec.invoices} (${Number(rec.hours_unexplained).toFixed(2)} h of ${Number(rec.hours_billed).toFixed(2)} h billed)`],
    ['Repeat calls (same unit, 30 days)', rec.repeat_calls],
  ];
  return (
    <details>
      <summary className="small" style={{ cursor: 'pointer' }}>Their record — last {rec.days} days</summary>
      <table><tbody>{rows.map(([k, v]) => <tr key={k}><td className="small">{k}</td><td className="num small">{v}</td></tr>)}</tbody></table>
    </details>
  );
}
