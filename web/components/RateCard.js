'use client';

// What a contractor charges one customer: reference only (it doesn't change the bill check).
// The store enters rates (in force at once) or the contractor proposes them and the store accepts.
// Every change is kept with its start date, so you can see when a rate went up and by how much.
import { useCallback, useEffect, useState } from 'react';
import { act } from '@/lib/supabase';
import { money } from '@/lib/format';
const date = (d) => (d ? new Date(`${String(d).slice(0, 10)}T12:00:00`).toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' }) : '');
import { ErrorBox, Notice } from './bits';

export const RATE_FIELDS = [
  ['regular', 'Regular labor', '/hr'],
  ['after_hours', 'After hours / overtime', '/hr'],
  ['helper', 'Helper', '/hr'],
  ['helper_after_hours', 'Helper, after hours / overtime', '/hr'],
  ['apprentice', 'Apprentice', '/hr'],
  ['apprentice_after_hours', 'Apprentice, after hours / overtime', '/hr'],
  ['trip', 'Trip charge', ' per trip'],
  ['markup_pct', 'Parts markup', '%'],
];
const UNITS = { hr: '/hr', each: ' each', trip: ' per trip', pct: '%' };

export function fmtRate(v, unit) {
  if (v == null || v === '') return '—';
  return unit === '%' || unit === 'pct' ? `${Number(v)}%` : `${money(v)}${unit === '%' ? '' : (UNITS[unit] ?? unit)}`;
}
const change = (now, was) => {
  if (now == null || was == null || Number(was) === 0 || Number(now) === Number(was)) return null;
  const pct = Math.round(((Number(now) - Number(was)) / Number(was)) * 100);
  return `${pct > 0 ? '+' : ''}${pct}%`;
};

// The rows of a card (fixed rates + custom lines), optionally against what they replaced
export function RateRows({ rates, previous }) {
  if (!rates) return null;
  const rows = RATE_FIELDS.filter(([k]) => rates[k] != null).map(([k, label, unit]) => ({ label, now: rates[k], was: previous?.[k], unit }));
  (rates.custom || []).forEach((c) => rows.push({ label: c.name, now: c.amount, was: previous?.custom?.find((p) => p.name === c.name)?.amount, unit: c.unit }));
  return (
    <table><tbody>
      {rows.map((r) => {
        const ch = change(r.now, r.was);
        return (
          <tr key={r.label}><td className="small">{r.label}</td>
            <td className="num small"><strong>{fmtRate(r.now, r.unit)}</strong>
              {ch && <div className="muted" style={{ fontSize: 12 }}>was {fmtRate(r.was, r.unit)} ({ch})</div>}</td></tr>
        );
      })}
    </tbody></table>
  );
}

export function RateForm({ initial, onSave, onCancel, busy, withDate = true, saveLabel = 'Save rates' }) {
  const [f, setF] = useState(() => ({
    ...Object.fromEntries(RATE_FIELDS.map(([k]) => [k, initial?.[k] ?? ''])),
    custom: [...(initial?.custom || []).map((c) => ({ ...c })), ...Array(Math.max(0, 1 - (initial?.custom || []).length)).fill(0).map(() => ({ name: '', amount: '', unit: 'hr' }))],
    from: new Date().toISOString().slice(0, 10), note: '',
  }));
  const setC = (i, k, v) => setF({ ...f, custom: f.custom.map((c, j) => (j === i ? { ...c, [k]: v } : c)) });
  return (
    <form className="stack" style={{ gap: 6 }} onSubmit={(e) => {
      e.preventDefault();
      const rates = Object.fromEntries(RATE_FIELDS.map(([k]) => [k, f[k] === '' ? null : Number(f[k])]).filter(([, v]) => v != null));
      const custom = f.custom.filter((c) => c.name.trim() || c.amount !== '').map((c) => ({ name: c.name.trim(), amount: c.amount === '' ? null : Number(c.amount), unit: c.unit }));
      if (custom.length) rates.custom = custom;
      onSave(rates, f.from, f.note);
    }}>
      <div className="rate-grid">
        {RATE_FIELDS.map(([k, label, unit]) => (
          <label key={k}>{label} <span className="muted small">({unit.trim() === '%' ? '%' : `$${unit.trim()}`})</span>
            <input type="number" min="0" step="0.01" value={f[k]} onChange={(e) => setF({ ...f, [k]: e.target.value })} /></label>
        ))}
      </div>
      <div className="small muted">Other rates (up to 4), e.g. parts runner, holiday rate, emergency fee:</div>
      {f.custom.map((c, i) => (
        <div key={i} className="row">
          <input className="grow" placeholder="Name" value={c.name} onChange={(e) => setC(i, 'name', e.target.value)} />
          <input style={{ width: 100 }} type="number" min="0" step="0.01" placeholder="Amount" value={c.amount} onChange={(e) => setC(i, 'amount', e.target.value)} />
          <select style={{ width: 110 }} value={c.unit} onChange={(e) => setC(i, 'unit', e.target.value)}>
            <option value="hr">$/hr</option><option value="each">$ each</option><option value="trip">$ per trip</option><option value="pct">%</option>
          </select>
        </div>
      ))}
      {f.custom.length < 4 && <button type="button" className="linkish small" style={{ alignSelf: 'flex-start' }} onClick={() => setF({ ...f, custom: [...f.custom, { name: '', amount: '', unit: 'hr' }] })}>+ Another rate</button>}
      {withDate && (
        <div className="row">
          <label style={{ flex: '0 0 170px' }}>Starting<input type="date" value={f.from} onChange={(e) => setF({ ...f, from: e.target.value })} required /></label>
          <label className="grow">Note (optional)<input value={f.note} onChange={(e) => setF({ ...f, note: e.target.value })} placeholder="e.g. 2027 rates" /></label>
        </div>
      )}
      <div className="row"><button className="primary" disabled={busy}>{saveLabel}</button>{onCancel && <button type="button" onClick={onCancel}>Cancel</button>}</div>
    </form>
  );
}

// side: 'store' (can edit, accepts proposals) or 'contractor' (proposes). at: show the rates in force on this date.
export default function RateCard({ customerId, contractorId, side, at, canEdit = true, title }) {
  const [card, setCard] = useState(null);
  const [err, setErr] = useState('');
  const [msg, setMsg] = useState('');
  const [edit, setEdit] = useState(false);
  const [busy, setBusy] = useState(false);
  const [hist, setHist] = useState(false);
  const load = useCallback(() => act('rate_card', { p_customer: customerId, p_contractor: contractorId, p_at: at || null }).then(setCard).catch((e) => setErr(e.message)), [customerId, contractorId, at]);
  useEffect(() => { load(); }, [load]);
  async function run(fn, args, ok) {
    setBusy(true); setErr(''); setMsg('');
    try { setCard(await act(fn, args)); setEdit(false); setMsg(ok); if (at) load(); } catch (x) { setErr(x.message); } finally { setBusy(false); }
  }
  if (!card) return <ErrorBox error={err} />;
  const cur = card.current; const pend = card.pending;
  return (
    <div className="stack" style={{ gap: 6 }}>
      {title !== null && <strong className="small">{title || (side === 'store' ? `What ${card.contractor} charges you` : `Your rates for ${card.customer}`)}{at ? ` on ${date(at)}` : ''}</strong>}
      <ErrorBox error={err} /><Notice>{msg}</Notice>
      {cur ? (
        <>
          <RateRows rates={cur.rates} previous={card.previous?.rates} />
          <div className="small muted">In force since {date(cur.from)}{cur.side === 'contractor' ? ` · proposed by ${card.contractor}` : cur.by ? ` · entered by ${cur.by}` : ''}{card.previous ? ` · replaced the rates from ${date(card.previous.from)}` : ''}</div>
        </>
      ) : <div className="small muted">{side === 'store' ? 'No rates on record yet.' : 'No rates on record with them yet. Enter yours so both of you see the same numbers.'}</div>}
      {card.scheduled && !at && <div className="small">Coming {date(card.scheduled.from)}: <RateInline rates={card.scheduled.rates} /></div>}

      {pend && (
        <div className="notice small stack" style={{ gap: 6 }}>
          <div><strong>{side === 'store' ? `${card.contractor} proposed new rates` : 'Your proposal is waiting for them'}</strong>, from {date(pend.from)}{pend.note ? `: "${pend.note}"` : ''}</div>
          <RateRows rates={pend.rates} previous={cur?.rates} />
          {side === 'store' && canEdit && (
            <div className="row">
              <button className="primary" disabled={busy} onClick={() => run('decide_rates', { p_id: pend.id, p_accept: true }, 'Accepted. These rates are now on record.')}>Accept</button>
              <button disabled={busy} onClick={() => {
                const n = window.prompt('Why not? (the contractor sees this)');
                if (n && n.trim()) run('decide_rates', { p_id: pend.id, p_accept: false, p_note: n.trim() }, 'Declined. The contractor is told why.');
              }}>Decline</button>
            </div>
          )}
        </div>
      )}

      {canEdit && !at && (edit ? (
        <RateForm initial={pend?.rates || cur?.rates} busy={busy} onCancel={() => setEdit(false)}
          saveLabel={side === 'store' ? 'Save rates' : 'Send to them'}
          onSave={(rates, from, note) => run('save_rates', { p_customer: customerId, p_contractor: contractorId, p_rates: rates, p_from: from, p_note: note || null },
            side === 'store' ? 'Saved. The old rates are kept in the history.' : 'Sent. They accept them, and you\'re told.')} />
      ) : (
        <div className="row">
          <button onClick={() => setEdit(true)}>{side === 'store' ? (cur ? 'Change rates' : 'Enter rates') : (cur ? 'Propose new rates' : 'Enter your rates')}</button>
          {card.history.length > 1 && <button className="linkish small" onClick={() => setHist(!hist)}>{hist ? 'Hide' : 'Show'} rate history ({card.history.length})</button>}
        </div>
      ))}
      {hist && (
        <table><tbody>
          {card.history.map((h, i) => (
            <tr key={`${h.from}-${i}`}><td className="small">{date(h.from)}</td><td className="small"><RateInline rates={h.rates} /></td>
              <td className="small muted">{h.side === 'contractor' ? 'proposed by them' : h.by || ''}</td></tr>
          ))}
        </tbody></table>
      )}
    </div>
  );
}

export function RateInline({ rates }) {
  if (!rates) return <span className="muted">—</span>;
  const parts = RATE_FIELDS.filter(([k]) => rates[k] != null).map(([k, label, unit]) => `${label.split(' /')[0]} ${fmtRate(rates[k], unit)}`);
  (rates.custom || []).forEach((c) => parts.push(`${c.name} ${fmtRate(c.amount, c.unit)}`));
  return <span>{parts.join(' · ')}</span>;
}
