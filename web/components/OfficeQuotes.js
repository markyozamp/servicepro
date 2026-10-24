'use client';

// Contractor: quotes. Requests from customers waiting for a quote (write one, or say you can't quote it), and
// every quote you've written: draft, sent, approved (it became a call), declined, not chosen.
// Base contractors can also write a quote for any of their customers without being asked.
import { useCallback, useEffect, useState } from 'react';
import { act } from '@/lib/supabase';
import { money, date } from '@/lib/format';
import { TAX_OPTS, defaultTax, taxTotals, pct } from '@/lib/tax';
import TaxBox from './TaxBox';

const STATUS = { draft: ['Draft', 'tone-slate'], sent: ['Sent, waiting', 'tone-amber'], approved: ['Approved', 'tone-green'], declined: ['Declined', 'tone-red'],
  not_chosen: ['Not chosen', 'tone-slate'], withdrawn: ['Withdrawn', 'tone-slate'] };
const KINDS = [['equipment', 'Equipment'], ['part', 'Part'], ['labor', 'Labor'], ['task', 'Task'], ['other', 'Other']];
const amt = (l) => Math.round(Number(l.qty || 0) * Number(l.rate || 0) * 100) / 100;
const today = () => new Date().toISOString().slice(0, 10);

function QuoteEditor({ quote, request, sites, onDone, onCancel }) {
  const [f, setF] = useState(() => ({
    site: quote?.site_id || request?.site_id || '', title: quote?.title || request?.title || '', notes: quote?.notes || '',
    valid: quote?.valid_until || '', lines: (quote?.lines || []).map((l) => ({ ...l })),
  }));
  const [book, setBook] = useState(null);
  const [tax, setTax] = useState(null);      // the location's tax (rate, exempt)
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');
  const set = (k) => (e) => setF({ ...f, [k]: e.target.value });
  const edit = (i, k, v) => setF({ ...f, lines: f.lines.map((l, j) => (j === i ? { ...l, [k]: v } : l)) });
  const add = (kind) => setF({ ...f, lines: [...f.lines, { kind, description: '', qty: 1, unit: kind === 'labor' ? 'hr' : 'ea', rate: '', cost: '',
    tax: kind === 'equipment' ? 'use' : defaultTax(kind, tax?.area) }] });
  const total = f.lines.reduce((t, l) => t + amt(l), 0);
  const txInfo = tax ? { on: tax.on, area: tax.area, exempt: !!tax.exempt && (!tax.exempt_until || tax.exempt_until >= today()) } : null;
  const tt = taxTotals(f.lines, txInfo);
  const costed = f.lines.filter((l) => l.cost !== '' && l.cost != null);
  const cost = costed.reduce((t, l) => t + Number(l.qty || 0) * Number(l.cost), 0);
  const costedSales = costed.reduce((t, l) => t + amt(l), 0);
  async function save(send) {
    setBusy(true); setErr('');
    try {
      const q = await act('save_quote', { p_id: quote?.id || null, p_site: f.site, p_title: f.title, p_lines: f.lines, p_notes: f.notes || null,
        p_valid_until: f.valid || null, p_request: quote?.request_id || request?.id || null });
      if (send) {
        let email = null;
        try { const r = await act('send_quote', { p_id: q.id }); onDone(r.portal ? `Sent ${r.number}. It's in their portal.` : `Sent ${r.number} to ${r.emailed_to}.`); return; }
        catch (x) {
          if (/Add an email/.test(x.message)) { email = window.prompt('Their email (to send the quote):', ''); if (!email) throw x; const r = await act('send_quote', { p_id: q.id, p_email: email }); onDone(`Sent ${r.number} to ${r.emailed_to}.`); return; }
          throw x;
        }
      }
      onDone('Saved as a draft.');
    } catch (x) { setErr(x.message); } finally { setBusy(false); }
  }
  return (
    <div className="panel panel-pad stack" style={{ gap: 8 }}>
      <h3 style={{ margin: 0 }}>{quote?.number ? `Quote ${quote.number}` : 'New quote'}{request ? ` for: ${request.customer}` : ''}</h3>
      {request?.details && <div className="small muted">They asked: “{request.details}”</div>}
      <div className="row">
        {!request && (
          <label className="grow">Customer and location
            <select value={f.site} onChange={set('site')} required>
              <option value="">Pick…</option>
              {sites.map((s) => <option key={s.site_id} value={s.site_id}>{s.customer} · {s.name}</option>)}
            </select></label>
        )}
        <label className="grow">What it's for<input value={f.title} onChange={set('title')} placeholder="e.g. New walk-in condensing unit, installed" /></label>
      </div>
      <div className="tablewrap">
        <table className="billtable">
          <thead><tr><th>What</th><th className="num">Qty</th><th>Unit</th><th className="num">Price</th><th className="num">Amount</th><th /></tr></thead>
          <tbody>
            {f.lines.map((l, i) => (
              <tr key={i}>
                <td><select value={l.kind} onChange={(e) => edit(i, 'kind', e.target.value)} style={{ width: 'auto', marginBottom: 4 }}>{KINDS.map(([k, n]) => <option key={k} value={k}>{n}</option>)}</select>
                  <input value={l.description} onChange={(e) => edit(i, 'description', e.target.value)} placeholder="Description" />
                  <div className="row small" style={{ gap: 6, marginTop: 4, alignItems: 'center' }}>
                    {tt.on && <select value={l.tax || defaultTax(l.kind, tt.area)} onChange={(e) => edit(i, 'tax', e.target.value)} style={{ width: 'auto' }} aria-label="Tax on this line">
                      {TAX_OPTS.map(([k, n]) => <option key={k} value={k}>{n}</option>)}</select>}
                    <label className="row" style={{ gap: 4, fontWeight: 400 }}>your cost/{l.unit || 'ea'}
                      <input type="number" step="0.01" min="0" value={l.cost ?? ''} onChange={(e) => edit(i, 'cost', e.target.value)} style={{ width: 90 }} placeholder="private" /></label>
                  </div></td>
                <td className="num"><input type="number" step="0.25" min="0" value={l.qty} onChange={(e) => edit(i, 'qty', e.target.value)} style={{ width: 80 }} /></td>
                <td><input value={l.unit || ''} onChange={(e) => edit(i, 'unit', e.target.value)} style={{ width: 60 }} /></td>
                <td className="num"><input type="number" step="0.01" min="0" value={l.rate ?? ''} onChange={(e) => edit(i, 'rate', e.target.value)} style={{ width: 100 }} /></td>
                <td className="num">{money(amt(l))}</td>
                <td><button type="button" className="linkbtn small" aria-label="Remove line" onClick={() => setF({ ...f, lines: f.lines.filter((_, j) => j !== i) })}>✕</button></td>
              </tr>
            ))}
            {tt.on && <tr><td colSpan={4}>Subtotal</td><td className="num">{money(total)}</td><td /></tr>}
            {tt.on && <tr><td colSpan={4}>{tt.exempt ? 'Sales tax: exempt' : tt.area ? `Sales tax ${pct(tt.rate)} on ${money(tt.taxable)}` : 'Sales tax: pick the rate below'}</td><td className="num">{money(tt.salesTax)}</td><td /></tr>}
            <tr><td colSpan={4}><strong>Total</strong></td><td className="num"><strong>{money(tt.total)}</strong></td><td /></tr>
          </tbody>
        </table>
      </div>
      {f.site && <TaxBox siteId={f.site} onInfo={setTax} />}
      {costed.length > 0 && (
        <div className="panel panel-pad small stack" style={{ gap: 2, background: 'var(--panel-2, #f7f7f5)' }}>
          <strong>Only you see this</strong>
          <div>Your cost {money(cost)} on {money(costedSales)} of lines{costed.length < f.lines.length ? ` (${f.lines.length - costed.length} line${f.lines.length - costed.length > 1 ? 's' : ''} with no cost entered)` : ''}
            {cost > 0 ? ` · markup ${Math.round((costedSales / cost - 1) * 100)}%` : ''}</div>
          {tt.on && tt.useBasis > 0 && <div>Use tax you&apos;ll owe on built-in items: {money(tt.useTax)} ({pct(tt.rate)} of your {money(tt.useBasis)} cost)</div>}
          <div><strong>Left after cost{tt.on && tt.useTax > 0 ? ' and use tax' : ''}: {money(costedSales - cost - (tt.on ? tt.useTax : 0))}</strong></div>
          {tt.on && tt.noCost > 0 && <div style={{ color: 'var(--red-fg)' }}>Enter your cost on {tt.noCost} built-in line{tt.noCost > 1 ? 's' : ''} so the use tax is figured.</div>}
        </div>
      )}
      <div className="row small" style={{ gap: 6 }}>
        <button type="button" onClick={() => add('equipment')}>+ Equipment</button>
        <button type="button" onClick={() => add('part')}>+ Part</button>
        <button type="button" onClick={() => add('labor')}>+ Labor</button>
        {book ? (
          <select value="" onChange={(e) => { const i = book.find((x) => x.id === e.target.value); if (i) setF({ ...f, lines: [...f.lines, { kind: 'task', description: `${i.code ? `${i.code} ` : ''}${i.name}`, qty: 1, unit: 'ea', rate: Number(i.price), tax: 'sales', cost: '' }] }); }} style={{ width: 'auto', maxWidth: 260 }}>
            <option value="">+ From price book…</option>
            {book.map((i) => <option key={i.id} value={i.id}>{i.name} · {money(i.price)}</option>)}
          </select>
        ) : <button type="button" onClick={async () => { try { setBook(await act('price_book', {})); } catch (x) { setErr(x.message); } }}>+ From price book</button>}
      </div>
      <div className="row">
        <label className="grow">Notes on the quote <span className="muted" style={{ fontWeight: 400 }}>(what's included, warranty, timing)</span><textarea rows={2} value={f.notes} onChange={set('notes')} /></label>
        <label style={{ flex: '0 0 170px' }}>Good until<input type="date" value={f.valid} onChange={set('valid')} placeholder="30 days" /></label>
      </div>
      {err && <div className="error">{err}</div>}
      <div className="row">
        <button className="primary" disabled={busy || !f.site || !f.title.trim() || !f.lines.length || total <= 0 || tt.missing} onClick={() => save(true)}>Send the quote</button>
        <button disabled={busy || !f.site || !f.title.trim()} onClick={() => save(false)}>Save draft</button>
        <button type="button" onClick={onCancel}>Cancel</button>
      </div>
      <div className="small muted">Customers who use Service Call Proof get it in their portal to compare and approve. Others get an email with a link: they approve or decline there, no account needed. Approved, it becomes a call to you with the quote total as the limit.</div>
    </div>
  );
}

export default function OfficeQuotes({ book, base, onOpenCall }) {
  const [d, setD] = useState(null);
  const [edit, setEdit] = useState(null);       // { quote?, request? }
  const [err, setErr] = useState('');
  const [msg, setMsg] = useState('');
  const load = useCallback(async () => { try { setD(await act('my_quotes', {})); } catch (x) { setErr(x.message); } }, []);
  useEffect(() => { load(); }, [load]);
  const sites = (book || []).flatMap((c) => c.sites.map((s) => ({ ...s, customer: c.name })));
  if (edit) return <QuoteEditor quote={edit.quote} request={edit.request} sites={sites} onCancel={() => setEdit(null)} onDone={(m) => { setEdit(null); setMsg(m); load(); }} />;
  if (!d) return err ? <div className="error">{err}</div> : <div className="muted">Loading quotes…</div>;
  const open = (d.requests || []).filter((r) => !r.passed);
  return (
    <div className="stack" style={{ gap: 12 }}>
      {msg && <div className="notice small">{msg}</div>}
      {err && <div className="error">{err}</div>}
      {base ? <div><button className="primary" onClick={() => setEdit({})}>+ New quote</button></div>
        : <div className="small muted">Answer your customers' quote requests here. Writing quotes for any customer without being asked comes with Base.</div>}
      {open.length > 0 && (
        <div className="panel panel-pad stack" style={{ gap: 8, borderColor: '#e6c98a', background: '#fffcf3' }}>
          <strong>Asked to quote ({open.length})</strong>
          {open.map((r) => {
            const mine = (d.quotes || []).find((q) => q.id === r.quote_id);
            return (
              <div key={r.id} className="spread" style={{ borderTop: '1px solid var(--line)', paddingTop: 6 }}>
                <span><strong>{r.title}</strong> · {r.customer}, {r.site}{r.due_on ? <span className="chip tone-amber" style={{ marginLeft: 6 }}>by {date(r.due_on)}</span> : null}
                  {r.details && <div className="small muted">{r.details}</div>}</span>
                <span className="row" style={{ gap: 6 }}>
                  {mine ? <span className={`chip ${STATUS[mine.status]?.[1]}`}>{STATUS[mine.status]?.[0]}</span> : null}
                  <button className="primary" onClick={() => setEdit({ request: r, quote: mine && ['draft', 'sent'].includes(mine.status) ? mine : null })}>{mine ? 'Change quote' : 'Write a quote'}</button>
                  {!mine && <button onClick={async () => { const n = window.prompt('Why can’t you quote it? (optional, they see this)', ''); if (n === null) return; try { await act('pass_quote_request', { p_request: r.id, p_note: n || null }); load(); } catch (x) { setErr(x.message); } }}>Can&apos;t quote it</button>}
                </span>
              </div>
            );
          })}
        </div>
      )}
      <div className="panel tablewrap">
        <table>
          <thead><tr><th>Quote</th><th className="hide-sm">Customer</th><th className="num">Total</th><th>Status</th></tr></thead>
          <tbody>
            {(d.quotes || []).length === 0 && <tr><td colSpan={4} className="muted">No quotes yet.</td></tr>}
            {(d.quotes || []).map((q) => (
              <tr key={q.id} className="click" onClick={() => (['draft', 'sent'].includes(q.status) ? setEdit({ quote: q, request: q.request_id ? (d.requests || []).find((r) => r.id === q.request_id) : null }) : q.work_order_id && onOpenCall(q.work_order_id))}>
                <td><strong>{q.number || 'Draft'}</strong> {q.title}<div className="small muted phone-show">{q.customer} · {q.site}</div></td>
                <td className="hide-sm">{q.customer}<div className="small muted">{q.site}</div></td>
                <td className="num">{money(q.total)}</td>
                <td><span className={`chip ${STATUS[q.status]?.[1]}`}>{STATUS[q.status]?.[0]}</span>
                  {q.status === 'approved' && q.call_number && <div className="small">Call #{q.call_number}{q.decided_name ? ` · ${q.decided_name}` : ''}</div>}
                  {q.status === 'declined' && q.decline_note && <div className="small muted">“{q.decline_note}”</div>}
                  {q.status === 'sent' && <div className="small"><button className="linkbtn small" onClick={async (e) => { e.stopPropagation(); if (!window.confirm('Withdraw this quote?')) return; try { await act('withdraw_quote', { p_id: q.id }); load(); } catch (x) { setErr(x.message); } }}>Withdraw</button></div>}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}
