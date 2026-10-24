'use client';

// Base: Invoices & Payments. To bill (finished calls with no invoice yet), Owed to you (by age, per customer, record a
// payment, statements), Paid (what came in, void a mistake), and Settings & reports (terms, reminders, summary,
// year-end download, QuickBooks file, tax report). "We bill and collect. Your accountant (or QuickBooks) keeps the books."
import { useCallback, useEffect, useState } from 'react';
import { act } from '@/lib/supabase';
import { money, date } from '@/lib/format';

const METHODS = [['check', 'Check'], ['cash', 'Cash'], ['card', 'Card'], ['transfer', 'Bank transfer'], ['other', 'Other']];
const MNAME = Object.fromEntries(METHODS);
const pad = (n) => String(n).padStart(2, '0');
const ymd = (x) => `${x.getFullYear()}-${pad(x.getMonth() + 1)}-${pad(x.getDate())}`;
const csvCell = (v) => `"${String(v ?? '').replace(/"/g, '""')}"`;
function download(name, rows) {
  const a = document.createElement('a');
  a.href = URL.createObjectURL(new Blob([rows.map((r) => r.map(csvCell).join(',')).join('\r\n')], { type: 'text/csv' }));
  a.download = name; a.click();
}

function PayForm({ inv, onDone, onCancel }) {
  const [f, setF] = useState({ amount: Number(inv.balance).toFixed(2), on: ymd(new Date()), method: 'check', ref: '' });
  const [err, setErr] = useState('');
  return (
    <form className="row small" style={{ alignItems: 'flex-end', gap: 6, marginTop: 6 }} onSubmit={async (e) => {
      e.preventDefault(); setErr('');
      try { const r = await act('record_payment', { p_wo: inv.work_order_id, p_amount: Number(f.amount), p_paid_on: f.on, p_method: f.method, p_reference: f.ref || null }); onDone(r.paid_in_full ? `Invoice ${inv.invoice_number} is paid in full.` : `Payment recorded. ${money(r.balance)} still owed on ${inv.invoice_number}.`); }
      catch (x) { setErr(x.message); }
    }}>
      <label style={{ flex: '0 0 110px' }}>Amount<input type="number" step="0.01" min="0.01" value={f.amount} onChange={(e) => setF({ ...f, amount: e.target.value })} /></label>
      <label style={{ flex: '0 0 150px' }}>Paid on<input type="date" value={f.on} onChange={(e) => setF({ ...f, on: e.target.value })} /></label>
      <label style={{ flex: '0 0 140px' }}>How<select value={f.method} onChange={(e) => setF({ ...f, method: e.target.value })}>{METHODS.map(([k, n]) => <option key={k} value={k}>{n}</option>)}</select></label>
      <label className="grow">{f.method === 'check' ? 'Check #' : 'Reference'} <span className="muted" style={{ fontWeight: 400 }}>(optional)</span><input value={f.ref} onChange={(e) => setF({ ...f, ref: e.target.value })} /></label>
      <button className="primary">Record payment</button><button type="button" onClick={onCancel}>Cancel</button>
      {err && <div className="error small" style={{ width: '100%' }}>{err}</div>}
    </form>
  );
}

function Owed({ d, onOpenCall, reload, setMsg }) {
  const [view, setView] = useState('invoices');
  const [paying, setPaying] = useState(null);
  const [err, setErr] = useState('');
  const a = d.aging;
  const buckets = [['current', 'Not due yet'], ['d30', '1–30 days late'], ['d60', '31–60'], ['d90', '61–90'], ['over90', '90+']];
  return (
    <div className="stack" style={{ gap: 10 }}>
      <div className="panel panel-pad row" style={{ gap: 18, flexWrap: 'wrap' }}>
        {buckets.map(([k, n]) => <div key={k} className="stack" style={{ gap: 0 }}><span className="small muted">{n}</span><strong style={{ fontSize: 18, color: k !== 'current' && Number(a[k]) > 0 ? (k === 'd30' ? '#b26b00' : 'var(--red-fg)') : undefined }}>{money(a[k])}</strong></div>)}
        <div className="stack" style={{ gap: 0, marginLeft: 'auto' }}><span className="small muted">Owed to you</span><strong style={{ fontSize: 22 }}>{money(a.total)}</strong></div>
      </div>
      <div className="row small" style={{ gap: 6 }}>
        <button className={view === 'invoices' ? 'primary' : ''} onClick={() => setView('invoices')}>By invoice ({d.open.length})</button>
        <button className={view === 'customers' ? 'primary' : ''} onClick={() => setView('customers')}>By customer ({d.by_customer.length})</button>
      </div>
      {err && <div className="error">{err}</div>}
      {view === 'invoices' ? (
        <div className="panel tablewrap">
          <table>
            <thead><tr><th>Invoice</th><th className="hide-sm">Customer</th><th>Due</th><th className="num hide-sm">Total</th><th className="num hide-sm">Paid</th><th className="num">Owed</th><th /></tr></thead>
            <tbody>
              {d.open.length === 0 && <tr><td colSpan={7} className="muted">Nothing owed to you right now.</td></tr>}
              {d.open.map((x) => (
                <tr key={x.work_order_id}>
                  <td colSpan={paying === x.work_order_id ? 7 : 1}>
                    <strong>{x.invoice_number}</strong> <span className="small muted">{date(x.inv_date)}</span>
                    <div className="small muted phone-show">{x.customer} · {x.site}</div>
                    {x.status !== 'approved' && <span className={`chip ${x.status === 'disputed' ? 'tone-red' : 'tone-amber'}`} style={{ marginLeft: 4 }}>{x.status === 'disputed' ? 'Disputed' : 'Waiting for their approval'}</span>}
                    {paying === x.work_order_id && <PayForm inv={x} onCancel={() => setPaying(null)} onDone={(m) => { setPaying(null); setMsg(m); reload(); }} />}
                  </td>
                  {paying !== x.work_order_id && <>
                    <td className="hide-sm">{x.customer}<div className="small muted">{x.site}</div></td>
                    <td>{x.days_late > 0 ? <span className={`chip ${x.days_late > 30 ? 'tone-red' : 'tone-amber'}`}>{x.days_late} days late</span> : <span className="small">{date(x.due_on)}</span>}
                      {x.reminders_sent > 0 && <div className="small muted">{x.reminders_sent === 3 ? 'reminders sent, call them' : `${x.reminders_sent} reminder${x.reminders_sent > 1 ? 's' : ''} sent`}</div>}</td>
                    <td className="num hide-sm">{money(x.total)}</td>
                    <td className="num hide-sm">{Number(x.amount_paid) > 0 ? money(x.amount_paid) : ''}</td>
                    <td className="num"><strong>{money(x.balance)}</strong></td>
                    <td className="row small" style={{ gap: 4, justifyContent: 'flex-end' }}>
                      <button className="primary" onClick={() => setPaying(x.work_order_id)}>Payment</button>
                      <a href={`/bill/${x.work_order_id}`} target="_blank" rel="noreferrer"><button type="button">Invoice</button></a>
                      <button type="button" className="linkbtn small" onClick={() => onOpenCall(x.work_order_id)}>Call #{x.call_number}</button>
                    </td>
                  </>}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      ) : (
        <div className="panel tablewrap">
          <table>
            <thead><tr><th>Customer</th><th className="num">Owed</th><th className="hide-sm">Invoices</th><th>Oldest</th><th /></tr></thead>
            <tbody>
              {d.by_customer.length === 0 && <tr><td colSpan={5} className="muted">Nothing owed to you right now.</td></tr>}
              {d.by_customer.map((c) => (
                <tr key={c.customer_id}>
                  <td><strong>{c.customer}</strong>{c.terms_days != null && <div className="small muted">terms: {c.terms_days} days</div>}</td>
                  <td className="num"><strong>{money(c.owed)}</strong></td>
                  <td className="hide-sm">{c.invoices}</td>
                  <td>{c.oldest_days_late > 0 ? <span className={`chip ${c.oldest_days_late > 30 ? 'tone-red' : 'tone-amber'}`}>{c.oldest_days_late} days late</span> : <span className="small muted">not due yet</span>}</td>
                  <td className="row small" style={{ gap: 4, justifyContent: 'flex-end' }}>
                    <a href={`/statement/${c.customer_id}`} target="_blank" rel="noreferrer"><button type="button">Statement</button></a>
                    <button type="button" onClick={async () => {
                      const to = window.prompt('Email the statement to:', c.email || ''); if (!to) return;
                      setErr(''); try { const r = await act('email_statement', { p_customer: c.customer_id, p_to: to }); setMsg(`Statement emailed to ${r.emailed_to} (${money(r.total)} open).`); } catch (x) { setErr(x.message); }
                    }}>Email it</button>
                    {d.can_settings && <button type="button" className="linkbtn small" onClick={async () => {
                      const v = window.prompt(`Payment terms for ${c.customer} in days (blank = your usual ${d.terms_days}):`, c.terms_days ?? ''); if (v === null) return;
                      setErr(''); try { await act('set_customer_terms', { p_customer: c.customer_id, p_days: v.trim() === '' ? null : Number(v) }); reload(); } catch (x) { setErr(x.message); }
                    }}>Terms</button>}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}

function Paid({ d, reload, setMsg }) {
  const [err, setErr] = useState('');
  return (
    <div className="panel tablewrap">
      {err && <div className="error">{err}</div>}
      <table>
        <thead><tr><th>Date</th><th>Invoice</th><th className="hide-sm">Customer</th><th className="num">Amount</th><th className="hide-sm">How</th><th /></tr></thead>
        <tbody>
          {d.payments.length === 0 && <tr><td colSpan={6} className="muted">No payments in the last 90 days.</td></tr>}
          {d.payments.map((p) => (
            <tr key={p.id} style={p.voided_at ? { opacity: 0.55 } : {}}>
              <td>{date(p.paid_on)}</td>
              <td><strong>{p.invoice_number}</strong><div className="small muted phone-show">{p.customer}</div></td>
              <td className="hide-sm">{p.customer}</td>
              <td className="num">{p.voided_at ? <s>{money(p.amount)}</s> : money(p.amount)}</td>
              <td className="hide-sm">{MNAME[p.method]}{p.reference ? ` ${p.reference}` : ''}{p.by ? <div className="small muted">by {p.by}</div> : null}</td>
              <td className="small">{p.voided_at ? <span className="muted">voided: {p.void_reason}</span> : d.can_settings && (
                <button type="button" className="linkbtn small" onClick={async () => {
                  const why = window.prompt('Void this payment? Say why (e.g. check bounced, entered twice):', ''); if (!why) return;
                  setErr(''); try { await act('void_payment', { p_payment: p.id, p_reason: why }); setMsg('Payment voided. The invoice is owed again.'); reload(); } catch (x) { setErr(x.message); }
                }}>Void</button>)}</td>
            </tr>
          ))}
        </tbody>
      </table>
      <div className="small muted" style={{ padding: 8 }}>The last 90 days. A voided payment stays on the record, with why.</div>
    </div>
  );
}

function Settings({ d, reload, setMsg, extras }) {
  const [f, setF] = useState({ terms: d.terms_days, remind: d.remind, days: (d.remind_days || [1, 15, 30]).join(', ') });
  const now = new Date();
  const [range, setRange] = useState({ from: `${now.getFullYear()}-01-01`, to: ymd(now) });
  const [sum, setSum] = useState(null);
  const [err, setErr] = useState('');
  const run = async () => { setErr(''); try { setSum(await act('billing_summary', { p_from: range.from, p_to: range.to })); } catch (x) { setErr(x.message); } };
  const yearEnd = () => {
    const rows = [['Invoices'], ['Invoice', 'Date', 'Customer', 'Location', 'Call', 'Before tax', 'Sales tax', 'Total', 'Paid', 'Still owed', 'Due']];
    for (const i of sum.invoices) rows.push([i.invoice_number, i.date, i.customer, i.site, i.call_number, i.before_tax, i.sales_tax, i.total, i.paid, i.balance, i.due_on]);
    rows.push([]); rows.push(['Payments']); rows.push(['Date', 'Invoice', 'Customer', 'Amount', 'How', 'Reference', 'Voided']);
    for (const p of sum.payment_rows) rows.push([p.paid_on, p.invoice_number, p.customer, p.amount, MNAME[p.method], p.reference, p.voided ? `voided: ${p.void_reason}` : '']);
    download(`invoices-and-payments-${range.from}-to-${range.to}.csv`, rows);
  };
  return (
    <div className="stack" style={{ gap: 12 }}>
      {d.can_settings && (
        <form className="panel panel-pad stack" style={{ gap: 8 }} onSubmit={async (e) => {
          e.preventDefault(); setErr('');
          try { await act('set_payment_terms', { p_days: Number(f.terms), p_remind: f.remind, p_remind_days: f.days.split(/[^\d]+/).filter(Boolean).map(Number) }); setMsg('Saved.'); reload(); } catch (x) { setErr(x.message); }
        }}>
          <h3 style={{ margin: 0 }}>Terms and reminders</h3>
          <div className="row" style={{ alignItems: 'flex-end' }}>
            <label style={{ flex: '0 0 180px' }}>Invoices are due in (days)<input type="number" min="0" max="180" value={f.terms} onChange={(e) => setF({ ...f, terms: e.target.value })} /></label>
            <label className="row small" style={{ gap: 6, fontWeight: 400 }}><input type="checkbox" style={{ width: 'auto' }} checked={f.remind} onChange={(e) => setF({ ...f, remind: e.target.checked })} />Send payment reminders for me</label>
            <label className="grow">Days past due: friendly, firmer, call them<input value={f.days} onChange={(e) => setF({ ...f, days: e.target.value })} placeholder="1, 15, 30" /></label>
            <button>Save</button>
          </div>
          <div className="small muted">Reminders go by email (or to their portal if they have a login), with the invoice attached as a link. At the last one, your office is told to call them. Per-customer terms: Owed to you → By customer → Terms.</div>
        </form>
      )}
      {d.can_settings && (
        <div className="panel panel-pad stack" style={{ gap: 8 }}>
          <h3 style={{ margin: 0 }}>Summary and year-end download</h3>
          <div className="row" style={{ alignItems: 'flex-end' }}>
            <label style={{ flex: '0 0 160px' }}>From<input type="date" value={range.from} onChange={(e) => setRange({ ...range, from: e.target.value })} /></label>
            <label style={{ flex: '0 0 160px' }}>To<input type="date" value={range.to} onChange={(e) => setRange({ ...range, to: e.target.value })} /></label>
            <button onClick={run}>Show</button>{sum && <button onClick={yearEnd}>Download for your accountant (CSV)</button>}
          </div>
          {sum && (
            <div className="row small" style={{ gap: 24, flexWrap: 'wrap' }}>
              <div><div className="muted">Billed</div><strong style={{ fontSize: 18 }}>{money(sum.billed.total)}</strong><div>{sum.billed.count} invoices · sales tax {money(sum.billed.sales_tax)}</div></div>
              <div><div className="muted">Collected</div><strong style={{ fontSize: 18 }}>{money(sum.collected.total)}</strong>
                <div>{Object.entries(sum.collected.by_method || {}).map(([k, v]) => `${MNAME[k]} ${money(v)}`).join(' · ') || 'none'}</div></div>
              <div><div className="muted">Owed to you now</div><strong style={{ fontSize: 18 }}>{money(sum.owed_now)}</strong></div>
            </div>
          )}
          <div className="small muted">We bill and collect. Your accountant (or QuickBooks) keeps the books: give them this download with your bank statements.</div>
        </div>
      )}
      {err && <div className="error">{err}</div>}
      {extras}
    </div>
  );
}

export default function InvoicesPayments({ toBill, toBillCount, extras, onOpenCall }) {
  const [view, setView] = useState('owed');
  const [d, setD] = useState(null);
  const [err, setErr] = useState('');
  const [msg, setMsg] = useState('');
  const load = useCallback(async () => { try { setD(await act('receivables', {})); } catch (x) { setErr(x.message); } }, []);
  useEffect(() => { load(); }, [load]);
  const tabs = [['tobill', `To bill (${toBillCount})`], ['owed', `Owed to you${d ? ` (${money(d.aging.total)})` : ''}`], ['paid', 'Paid'], ['settings', 'Settings & reports']];
  return (
    <div className="stack" style={{ gap: 10 }}>
      <div className="row" style={{ gap: 6, flexWrap: 'wrap' }}>
        {tabs.map(([k, n]) => <button key={k} className={view === k ? 'primary' : ''} onClick={() => { setView(k); setMsg(''); }}>{n}</button>)}
      </div>
      {msg && <div className="notice small">{msg}</div>}
      {err && <div className="error">{err}</div>}
      {view === 'tobill' && toBill}
      {view !== 'tobill' && !d && !err && <div className="muted">Loading…</div>}
      {view === 'owed' && d && <Owed d={d} onOpenCall={onOpenCall} reload={load} setMsg={setMsg} />}
      {view === 'paid' && d && <Paid d={d} reload={load} setMsg={setMsg} />}
      {view === 'settings' && d && <Settings d={d} reload={load} setMsg={setMsg} extras={extras} />}
    </div>
  );
}
