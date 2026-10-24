'use client';

// Base: "we write the bill for you". The bill is built from the record (verified hours at this customer's rates,
// trip charge per trip, parts used, a PM's flat price). Check it, change or add any line, then send: it goes
// through the same check as the light bill, and the customer gets the itemized bill with a printable copy.
import { useCallback, useEffect, useState } from 'react';
import { act } from '@/lib/supabase';
import { money } from '@/lib/format';
import { TAX_OPTS, defaultTax, lineAmount, taxTotals, pct } from '@/lib/tax';
import TaxBox from './TaxBox';

const h = (n) => `${Number(n || 0).toFixed(2)} h`;
const KIND = { labor: 'Labor', after_hours: 'After hours', helper: 'Helper', trip: 'Trip', part: 'Part', flat: 'Flat', task: 'Task', equipment: 'Equipment', other: 'Other' };
const amt = lineAmount;

export default function BillBuilder({ wo, busy, onSent, onLight }) {
  const [s, setS] = useState(null);
  const [lines, setLines] = useState([]);
  const [no, setNo] = useState('');
  const [note, setNote] = useState('');
  const [reason, setReason] = useState('');
  const [overOk, setOverOk] = useState(false);
  const [dirty, setDirty] = useState(false);
  const [working, setWorking] = useState(false);
  const [err, setErr] = useState('');
  const [msg, setMsg] = useState('');
  const [book, setBook] = useState(null);     // price book (flat-rate tasks), loaded when needed
  const [pick, setPick] = useState('');

  const take = (r) => { setS(r); setLines((r.lines || []).map((l) => ({ ...l }))); setNo(r.invoice_number || r.suggested_no || ''); setNote(r.note || ''); setDirty(false); };
  const load = useCallback(async () => {
    try { take(await act('bill_draft', { p_wo: wo.id })); } catch (x) { setErr(x.message); }
  }, [wo.id]);
  useEffect(() => { load(); }, [load]);

  async function call(fn, args, after) {
    setWorking(true); setErr(''); setMsg('');
    try { const r = await act(fn, args); after?.(r); } catch (x) { setErr(x.message); } finally { setWorking(false); }
  }
  const save = (after) => call('save_bill', { p_wo: wo.id, p_lines: lines, p_invoice_number: no, p_note: note }, (r) => { take(r); after?.(r); });
  const edit = (i, k, v) => { setLines(lines.map((l, j) => (j === i ? { ...l, [k]: v } : l))); setDirty(true); };
  const setTax = (i, v) => {
    const l = lines[i]; edit(i, 'tax', v);
    if (l.part_id && (v === 'use') !== (l.tax === 'use')) act('set_part_built_in', { p_part: l.part_id, p_built_in: v === 'use' }).catch(() => {});
  };
  const refreshTax = async () => { try { const r = await act('bill_draft', { p_wo: wo.id }); setS(r); } catch (x) { setErr(x.message); } };
  const openBook = async () => { try { setBook(await act('price_book', { p_customer: wo.customer_id })); } catch (x) { setErr(x.message); } };
  const addTask = (id) => {
    const i = (book || []).find((x) => x.id === id); if (!i) return;
    setLines([...lines, { kind: 'task', description: `${i.code ? `${i.code} ` : ''}${i.name}`, qty: 1, unit: 'ea', rate: Number(i.price), tax: 'sales', auto: false }]); setDirty(true); setPick('');
  };
  const add = (kind) => { setLines([...lines, { kind, description: '', qty: 1, unit: kind === 'part' ? 'ea' : '', rate: '', tax: defaultTax(kind, s?.tax?.area), auto: false }]); setDirty(true); };
  const remove = (i) => { setLines(lines.filter((_, j) => j !== i)); setDirty(true); };

  if (!s) return err ? <div className="error">{err}</div> : <div className="small muted">Building your bill…</div>;
  const tt = taxTotals(lines, s.tax);
  const total = tt.subtotal;
  const labor = lines.filter((l) => ['labor', 'after_hours', 'helper'].includes(l.kind)).reduce((t, l) => t + Number(l.qty || 0), 0);
  const verified = Number(s.verified_h || 0);
  const extra = !s.flat && labor - verified > 0.009;
  const missing = lines.some((l) => l.rate === '' || l.rate == null);
  const cap = s.cap == null ? null : Number(s.cap);
  const over = cap != null && total > cap + 0.004;
  const ready = lines.length && !missing && !tt.missing && no.trim() && total > 0 && (!extra || reason.trim().length >= 5) && (!over || overOk);

  return (
    <div className="stack billbuilder" style={{ gap: 8, borderTop: '1px solid var(--line)', paddingTop: 8 }}>
      <div className="spread">
        <h3>Your bill · PO {wo.store_po_number || `PO${wo.number}`}</h3>
        <span className="chip tone-green">Written for you (Base){s.flat ? ' · flat rate' : ''}</span>
      </div>
      <div className="small muted">Built from the record: verified hours at {s.rates?.source === 'rate_card' ? 'your rates for this customer' : 'your company rates'}, a trip charge per trip, and parts used. Change anything, add lines, then send.</div>
      <div className="tablewrap">
        <table className="billtable">
          <thead><tr><th>What</th><th className="num">Qty</th><th>Unit</th><th className="num">Rate</th><th className="num">Amount</th><th /></tr></thead>
          <tbody>
            {lines.map((l, i) => (
              <tr key={i}>
                <td><span className="small muted">{KIND[l.kind] || 'Other'}</span>
                  <input value={l.description} onChange={(e) => edit(i, 'description', e.target.value)} placeholder="Description" />
                  {tt.on && (
                    <div className="row small" style={{ gap: 6, marginTop: 4, alignItems: 'center' }}>
                      <select value={l.tax || defaultTax(l.kind, tt.area)} onChange={(e) => setTax(i, e.target.value)} style={{ width: 'auto' }} aria-label="Tax on this line">
                        {TAX_OPTS.map(([k, n]) => <option key={k} value={k}>{n}</option>)}
                      </select>
                      {(l.tax || defaultTax(l.kind, tt.area)) === 'use' && <label className="row" style={{ gap: 4, fontWeight: 400 }}>your cost/ea
                        <input type="number" step="0.01" min="0" value={l.cost ?? ''} onChange={(e) => edit(i, 'cost', e.target.value)} style={{ width: 90 }} placeholder="cost" /></label>}
                    </div>
                  )}</td>
                <td className="num"><input type="number" step="0.25" min="0" value={l.qty} onChange={(e) => edit(i, 'qty', e.target.value)} style={{ width: 80 }} /></td>
                <td><input value={l.unit || ''} onChange={(e) => edit(i, 'unit', e.target.value)} style={{ width: 60 }} /></td>
                <td className="num"><input type="number" step="0.01" min="0" value={l.rate ?? ''} onChange={(e) => edit(i, 'rate', e.target.value)} placeholder="rate"
                  style={{ width: 90, ...(l.rate === '' || l.rate == null ? { borderColor: 'var(--red-fg)' } : {}) }} /></td>
                <td className="num">{amt(l) == null ? <span className="small" style={{ color: 'var(--red-fg)' }}>set rate</span> : money(amt(l))}</td>
                <td><button type="button" className="linkbtn small" aria-label="Remove line" onClick={() => remove(i)}>✕</button></td>
              </tr>
            ))}
            {tt.on && <tr><td colSpan={4}>Subtotal{cap != null && <span className="small muted"> · this call allows {money(cap)} before tax</span>}</td><td className="num" style={over ? { color: 'var(--red-fg)' } : {}}>{money(total)}</td><td /></tr>}
            {tt.on && <tr><td colSpan={4}>{tt.exempt ? 'Sales tax: exempt' : tt.area ? `Sales tax ${pct(tt.rate)} on ${money(tt.taxable)}` : 'Sales tax: pick the rate below'}</td><td className="num">{money(tt.salesTax)}</td><td /></tr>}
            <tr><td colSpan={4}><strong>Total</strong>{!tt.on && cap != null && <span className="small muted"> · this call allows {money(cap)}</span>}</td>
              <td className="num"><strong style={!tt.on && over ? { color: 'var(--red-fg)' } : {}}>{money(tt.total)}</strong></td><td /></tr>
          </tbody>
        </table>
      </div>
      {tt.on && <TaxBox siteId={wo.site_id} onChanged={refreshTax} />}
      {tt.on && tt.useBasis + tt.noCost > 0 && <div className="small muted">Only you see this: use tax you owe on built-in parts, {money(tt.useTax)} ({pct(tt.rate)} of your {money(tt.useBasis)} cost){tt.noCost ? `. Add your cost on ${tt.noCost} built-in line${tt.noCost > 1 ? 's' : ''}` : ''}.</div>}
      <div className="row small" style={{ gap: 6 }}>
        {book ? (
          <select value={pick} onChange={(e) => addTask(e.target.value)} style={{ width: 'auto', maxWidth: 280 }}>
            <option value="">+ From price book…</option>
            {book.map((i) => <option key={i.id} value={i.id}>{i.code ? `${i.code} ` : ''}{i.name} · {money(i.price)}</option>)}
          </select>
        ) : <button type="button" onClick={openBook}>+ From price book</button>}
        <button type="button" onClick={() => add('part')}>+ Part</button>
        <button type="button" onClick={() => add('other')}>+ Other line</button>
        <button type="button" disabled={working} onClick={() => call('rebuild_bill', { p_wo: wo.id }, take)} title="Fills the lines in again from the record; lines you added stay">↻ Rebuild from the record</button>
      </div>
      {s.flat ? <div className="small">Flat rate: the bill is the tasks done (the tech adds them on the phone, or add them here). The customer sees the verified time on site, <strong>{h(verified)}</strong>, for reference only.</div> : <div className="small">Labor on the bill: <strong>{h(labor)}</strong> · verified: <strong>{h(verified)}</strong>
        {Math.abs(labor - verified) < 0.01 ? <span style={{ color: 'var(--green-fg)' }}> ✓ matches</span> : extra ? <span style={{ color: 'var(--red-fg)' }}> · {h(labor - verified)} more than verified</span> : <span className="muted"> · less than verified</span>}</div>}
      {extra && <label>What was the extra {h(labor - verified)} for? <span className="muted" style={{ fontWeight: 400 }}>(the customer sees this)</span>
        <input value={reason} onChange={(e) => setReason(e.target.value)} placeholder="e.g. Shop time rebuilding the valve" /></label>}
      {missing && <div className="small" style={{ color: 'var(--red-fg)' }}>Set a rate on every line. Tip: put your rates for this customer on the rate card so they fill in next time.</div>}
      {over && (
        <div className="notice small stack" style={{ gap: 6 }}>
          <div><strong>That&apos;s {money(total - cap)} over what this call allows.</strong> Best: ask the customer first with <em>Request approval for more</em>.</div>
          <label className="row" style={{ gap: 6, fontWeight: 400 }}><input type="checkbox" style={{ width: 'auto' }} checked={overOk} onChange={(e) => setOverOk(e.target.checked)} /> Send it anyway, marked over the PO</label>
        </div>
      )}
      <div className="row">
        <label className="grow">Invoice #<input value={no} onChange={(e) => { setNo(e.target.value); setDirty(true); }} /></label>
        <label className="grow">Note on the bill <span className="muted" style={{ fontWeight: 400 }}>(optional)</span><input value={note} onChange={(e) => { setNote(e.target.value); setDirty(true); }} placeholder="e.g. Thank you for your business" /></label>
      </div>
      {err && <div className="error">{err}</div>}
      {msg && <div className="notice small">{msg}</div>}
      <div className="row">
        <button className="primary" disabled={busy || working || !ready} onClick={() => save(() => call('send_built_bill', { p_wo: wo.id, p_reason: extra ? reason.trim() : null, p_over_ok: over && overOk }, () => { setMsg('Sent. The customer has the itemized bill.'); onSent?.(); }))}>Send the bill</button>
        <button disabled={working || !dirty} onClick={() => save(() => setMsg('Saved.'))}>Save</button>
        <button type="button" disabled={working} onClick={() => save(() => window.open(`/bill/${wo.id}`, '_blank'))}>Preview / print</button>
      </div>
      {onLight && <button type="button" className="linkish small" style={{ alignSelf: 'flex-start' }} onClick={onLight}>Or just enter my own invoice total instead</button>}
    </div>
  );
}
