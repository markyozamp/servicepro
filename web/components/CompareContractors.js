'use client';

// Store: every contractor's current rates side by side, plus quotes from companies wanting the account.
import { useCallback, useEffect, useState } from 'react';
import { supabase, act, q } from '@/lib/supabase';
const date = (d) => (d ? new Date(`${String(d).slice(0, 10)}T12:00:00`).toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' }) : '');
import { ErrorBox, Notice } from './bits';
import { RATE_FIELDS, RateForm, fmtRate } from './RateCard';

export default function CompareContractors({ canEdit }) {
  const [trades, setTrades] = useState([]);
  const [trade, setTrade] = useState('');
  const [d, setD] = useState(null);
  const [err, setErr] = useState('');
  const [msg, setMsg] = useState('');
  const [add, setAdd] = useState(null);
  const [busy, setBusy] = useState(false);
  const load = useCallback(() => act('compare_contractors', { p_trade: trade ? Number(trade) : null }).then(setD).catch((e) => setErr(e.message)), [trade]);
  useEffect(() => { q(supabase.from('trades').select('id, name').order('id')).then(setTrades).catch(() => {}); }, []);
  useEffect(() => { load(); }, [load]);
  if (!d) return <ErrorBox error={err} />;

  const cols = [
    ...d.contractors.map((c) => ({ key: c.contractor_id, name: c.name, rates: c.card?.rates, prev: c.previous?.rates, sub: c.card ? `since ${date(c.card.from)}` : 'no rates on record', pending: c.pending, kind: 'yours' })),
    ...d.prospects.map((p) => ({ key: p.id, name: p.name, rates: p.rates, sub: `quote · ${date(p.at)}`, note: p.note, kind: 'prospect' })),
  ];
  const customNames = [...new Set(cols.flatMap((c) => (c.rates?.custom || []).map((x) => x.name)))];
  const rows = [
    ...RATE_FIELDS.map(([k, label, unit]) => ({ label, unit, get: (r) => r?.[k] })),
    ...customNames.map((n) => ({ label: n, get: (r) => r?.custom?.find((x) => x.name === n)?.amount, unitOf: (r) => r?.custom?.find((x) => x.name === n)?.unit })),
  ];
  const low = (row) => {
    const vals = cols.map((c) => row.get(c.rates)).filter((v) => v != null).map(Number);
    return vals.length > 1 ? Math.min(...vals) : null;
  };

  return (
    <div className="stack">
      <ErrorBox error={err} /><Notice>{msg}</Notice>
      <div className="row" style={{ alignItems: 'flex-end' }}>
        <label style={{ maxWidth: 240 }}>Trade<select value={trade} onChange={(e) => setTrade(e.target.value)}>
          <option value="">All trades</option>{trades.map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}</select></label>
        {canEdit && !add && <button onClick={() => setAdd({ name: '', trades: trade ? [Number(trade)] : [], note: '' })}>+ Add a quote from another company</button>}
      </div>
      {add && (
        <div className="panel panel-pad stack" style={{ gap: 6 }}>
          <strong>A quote from a company that wants your account</strong>
          <div className="row">
            <label className="grow">Company<input value={add.name} onChange={(e) => setAdd({ ...add, name: e.target.value })} required /></label>
            <label className="grow">Note<input value={add.note} onChange={(e) => setAdd({ ...add, note: e.target.value })} placeholder="e.g. Walked in with a quote in September" /></label>
          </div>
          <div className="row" style={{ gap: 10 }}>{trades.map((t) => (
            <label key={t.id} className="row small" style={{ gap: 4, fontWeight: 400 }}><input type="checkbox" style={{ width: 'auto' }} checked={add.trades.includes(t.id)}
              onChange={(e) => setAdd({ ...add, trades: e.target.checked ? [...add.trades, t.id] : add.trades.filter((x) => x !== t.id) })} />{t.name}</label>))}</div>
          <RateForm withDate={false} busy={busy} saveLabel="Add to the comparison" onCancel={() => setAdd(null)} onSave={async (rates) => {
            setBusy(true); setErr('');
            try { await act('save_prospect', { p_id: null, p_name: add.name, p_rates: rates, p_trade_ids: add.trades, p_note: add.note || null }); setAdd(null); setMsg('Added. It shows as a quote next to your contractors.'); await load(); }
            catch (x) { setErr(x.message); } finally { setBusy(false); }
          }} />
        </div>
      )}
      {cols.length === 0 ? <div className="small muted">No contractors for this trade yet.</div> : (
        <div className="tablewrap">
          <table className="compare">
            <thead><tr><th />{cols.map((c) => (
              <th key={c.key} className={c.kind === 'prospect' ? 'prospect' : ''}>{c.name}
                <div className="small muted" style={{ fontWeight: 400 }}>{c.sub}{c.pending ? ' · new rates proposed' : ''}</div></th>))}</tr></thead>
            <tbody>
              {rows.map((r) => {
                const lo = low(r);
                return (
                  <tr key={r.label}><td className="small">{r.label}</td>
                    {cols.map((c) => {
                      const v = r.get(c.rates); const was = r.get(c.prev);
                      return (
                        <td key={c.key} className={`num small${c.kind === 'prospect' ? ' prospect' : ''}`} style={lo != null && v != null && Number(v) === lo ? { color: 'var(--green-fg)', fontWeight: 700 } : {}}>
                          {fmtRate(v, r.unit || r.unitOf?.(c.rates))}
                          {was != null && v != null && Number(was) !== Number(v) && <div className="muted" style={{ fontSize: 11, fontWeight: 400 }}>was {fmtRate(was, r.unit || r.unitOf?.(c.prev))}</div>}
                        </td>
                      );
                    })}</tr>
                );
              })}
              {d.prospects.length > 0 && canEdit && (
                <tr><td />{cols.map((c) => <td key={c.key} className="num small">{c.kind === 'prospect' && (
                  <button className="linkish small" onClick={async () => { try { await act('archive_prospect', { p_id: c.key }); await load(); } catch (x) { setErr(x.message); } }}>Remove quote</button>)}</td>)}</tr>
              )}
            </tbody>
          </table>
        </div>
      )}
      <div className="small muted">Green = the lowest for that rate. Rates are what each contractor charges you, for reference; they don&apos;t change how bills are checked.</div>
    </div>
  );
}
