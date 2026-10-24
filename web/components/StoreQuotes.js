'use client';

// Store: installs and projects. Ask one or more of your contractors to quote a job, compare the quotes side by side,
// approve one with a tap: it becomes the job (a call to that contractor, with the quote total as the limit).
import { useCallback, useEffect, useState } from 'react';
import { supabase, act, q as query } from '@/lib/supabase';
import { money, date } from '@/lib/format';

const STATUS = { sent: ['Waiting for you', 'tone-amber'], approved: ['Approved', 'tone-green'], declined: ['Declined', 'tone-red'],
  not_chosen: ['Not chosen', 'tone-slate'], withdrawn: ['Withdrawn', 'tone-slate'] };

function QuoteCard({ q, canApprove, onDecided, onOpenCall }) {
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');
  async function decide(approve) {
    let note = null;
    if (!approve) { note = window.prompt('Why not? (they see this, so they can adjust it)', ''); if (!note) return; }
    setBusy(true); setErr('');
    try { const r = await act('decide_quote', { p_quote: q.id, p_approve: approve, p_note: note }); onDecided(approve ? `Approved. Call #${r.call_number} is open for it.` : 'Declined. They’ve been told.'); }
    catch (x) { setErr(x.message); } finally { setBusy(false); }
  }
  return (
    <div className="panel panel-pad stack quotecard" style={{ gap: 6 }}>
      <div className="spread"><strong>{q.contractor}</strong><span className={`chip ${STATUS[q.status]?.[1] || 'tone-slate'}`}>{STATUS[q.status]?.[0] || q.status}</span></div>
      <div className="small muted">{q.number} · {q.title}{q.valid_until ? ` · good until ${date(q.valid_until)}` : ''}</div>
      <table className="small">
        <tbody>
          {(q.lines || []).map((l, i) => <tr key={i}><td>{l.description}{Number(l.qty) !== 1 ? ` × ${Number(l.qty)}` : ''}</td><td className="num">{money(l.amount)}</td></tr>)}
          <tr><td><strong>Total</strong></td><td className="num"><strong style={{ fontSize: 18 }}>{money(q.total)}</strong></td></tr>
        </tbody>
      </table>
      {q.notes && <div className="small">{q.notes}</div>}
      {q.status === 'sent' && canApprove && (
        <div className="row" style={{ gap: 6 }}>
          <button className="primary" disabled={busy} onClick={() => decide(true)}>Approve: make it the job</button>
          <button disabled={busy} onClick={() => decide(false)}>No thanks</button>
        </div>
      )}
      {q.status === 'approved' && q.work_order_id && <button className="linkbtn small" style={{ alignSelf: 'flex-start' }} onClick={() => onOpenCall(q.work_order_id)}>Open call #{q.call_number}</button>}
      {err && <div className="error small">{err}</div>}
    </div>
  );
}

export default function StoreQuotes({ profile, sites, onClose, onOpenCall }) {
  const [d, setD] = useState(null);
  const [contractors, setContractors] = useState([]);
  const [asking, setAsking] = useState(false);
  const [f, setF] = useState({ site: sites.length === 1 ? sites[0].id : '', title: '', details: '', due: '', who: [] });
  const [err, setErr] = useState('');
  const [msg, setMsg] = useState('');
  const load = useCallback(async () => {
    try {
      setD(await act('store_quotes', {}));
      const cc = await query(supabase.from('customer_contractors').select('contractor_id, store_removed_at, contractors(name)').eq('customer_id', profile.customer_id)).catch(() => []);
      setContractors((cc || []).filter((c) => !c.store_removed_at).map((c) => ({ id: c.contractor_id, name: c.contractors?.name })).sort((a, b) => (a.name || '').localeCompare(b.name || '')));
    } catch (x) { setErr(x.message); }
  }, [profile]);
  useEffect(() => { load(); }, [load]);
  const canApprove = profile.can_approve || profile.is_org_admin;
  const quotesFor = (rid) => (d?.quotes || []).filter((q) => q.request_id === rid);
  const loose = (d?.quotes || []).filter((q) => !q.request_id);

  return (
    <div className="panel panel-pad stack work-panel" style={{ gap: 12 }}>
      <div className="spread"><h2 style={{ margin: 0 }}>Installs and project quotes</h2><button onClick={onClose}>Close</button></div>
      <div className="small muted">Describe the job, pick the contractors to quote it, compare the quotes side by side and approve one. It becomes the job, with the quote total as the limit.</div>
      {msg && <div className="notice small">{msg}</div>}
      {err && <div className="error">{err}</div>}
      {!asking ? <div><button className="primary" onClick={() => setAsking(true)}>+ Ask for quotes</button></div> : (
        <form className="stack" style={{ gap: 8, border: '1px solid var(--line)', borderRadius: 10, padding: 10 }} onSubmit={async (e) => {
          e.preventDefault(); setErr('');
          try {
            const r = await act('request_quotes', { p_site: f.site, p_title: f.title, p_details: f.details || null, p_contractors: f.who, p_due: f.due || null });
            setAsking(false); setF({ ...f, title: '', details: '', due: '', who: [] }); setMsg(`Asked ${r.asked} contractor${r.asked === 1 ? '' : 's'}. Their quotes show up here.`); load();
          } catch (x) { setErr(x.message); }
        }}>
          <div className="row">
            <label className="grow">Location<select value={f.site} onChange={(e) => setF({ ...f, site: e.target.value })} required>
              <option value="">Pick…</option>{sites.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</select></label>
            <label style={{ flex: '0 0 170px' }}>Quotes by<input type="date" value={f.due} onChange={(e) => setF({ ...f, due: e.target.value })} /></label>
          </div>
          <label>What do you want quoted?<input value={f.title} onChange={(e) => setF({ ...f, title: e.target.value })} required placeholder="e.g. Replace the walk-in cooler condensing unit" /></label>
          <label>Details <span className="muted" style={{ fontWeight: 400 }}>(size, model, timing, anything they should know)</span><textarea rows={2} value={f.details} onChange={(e) => setF({ ...f, details: e.target.value })} /></label>
          <div className="stack" style={{ gap: 4 }}><strong className="small">Who should quote it?</strong>
            {contractors.map((c) => (
              <label key={c.id} className="row small" style={{ gap: 6, fontWeight: 400 }}><input type="checkbox" style={{ width: 'auto' }} checked={f.who.includes(c.id)}
                onChange={(e) => setF({ ...f, who: e.target.checked ? [...f.who, c.id] : f.who.filter((x) => x !== c.id) })} />{c.name}</label>
            ))}
            {!contractors.length && <div className="small muted">Add your contractors first (Contractors & QR).</div>}
          </div>
          <div className="row"><button className="primary" disabled={!f.site || !f.title.trim() || !f.who.length}>Send the request</button><button type="button" onClick={() => setAsking(false)}>Cancel</button></div>
        </form>
      )}
      {!d ? <div className="muted">Loading…</div> : (
        <>
          {(d.requests || []).map((r) => {
            const qs = quotesFor(r.id);
            return (
              <div key={r.id} className="stack" style={{ gap: 6 }}>
                <div className="spread"><span><strong>{r.title}</strong> · {r.site}{r.due_on ? ` · quotes by ${date(r.due_on)}` : ''}{r.closed_at ? <span className="chip tone-slate" style={{ marginLeft: 6 }}>Done</span> : null}</span>
                  <span className="small muted">Asked: {(r.asked || []).map((a) => `${a.contractor}${a.passed ? ' (can’t quote)' : ''}`).join(', ')}</span></div>
                {qs.length ? <div className="quotegrid">{qs.map((q) => <QuoteCard key={q.id} q={q} canApprove={canApprove} onOpenCall={onOpenCall} onDecided={(m) => { setMsg(m); load(); }} />)}</div>
                  : <div className="small muted">No quotes in yet.</div>}
              </div>
            );
          })}
          {loose.length > 0 && (
            <div className="stack" style={{ gap: 6 }}>
              <strong>Quotes sent to you</strong>
              <div className="quotegrid">{loose.map((q) => <QuoteCard key={q.id} q={q} canApprove={canApprove} onOpenCall={onOpenCall} onDecided={(m) => { setMsg(m); load(); }} />)}</div>
            </div>
          )}
          {!(d.requests || []).length && !loose.length && <div className="small muted">No quotes yet.</div>}
        </>
      )}
      {!canApprove && <div className="small muted">You can ask for quotes; someone with approval rights approves them.</div>}
    </div>
  );
}
