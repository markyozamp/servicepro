'use client';

// Base: bills to QuickBooks without retyping. Download the bills the app wrote as a QuickBooks Online invoice import
// file (CSV), or a QuickBooks Desktop file (.iif), plus a customer list. Downloaded bills are marked so nothing goes in twice.
import { useState } from 'react';
import { act } from '@/lib/supabase';
import { money } from '@/lib/format';

const pad = (n) => String(n).padStart(2, '0');
const mdy = (d) => { const x = new Date(`${d}T12:00`); return `${pad(x.getMonth() + 1)}/${pad(x.getDate())}/${x.getFullYear()}`; };
const addDays = (d, n) => { const x = new Date(`${d}T12:00`); x.setDate(x.getDate() + n); return `${x.getFullYear()}-${pad(x.getMonth() + 1)}-${pad(x.getDate())}`; };
const csvCell = (v) => `"${String(v ?? '').replace(/"/g, '""')}"`;
const iifCell = (v) => String(v ?? '').replace(/[\t\r\n]+/g, ' ');
const n2 = (v) => Number(v || 0).toFixed(2);
const ITEM = { labor: 'Labor', after_hours: 'Labor - after hours', helper: 'Helper labor', trip: 'Trip charge', part: 'Parts', flat: 'Maintenance visit', task: 'Flat rate', equipment: 'Equipment', other: 'Service' };

function save(name, text, type) {
  const a = document.createElement('a');
  a.href = URL.createObjectURL(new Blob([text], { type }));
  a.download = name; a.click();
  setTimeout(() => URL.revokeObjectURL(a.href), 2000);
}

export function qboInvoicesCsv(bills, terms) {
  const head = ['InvoiceNo', 'Customer', 'InvoiceDate', 'DueDate', 'Terms', 'Memo', 'Item(Product/Service)', 'ItemDescription', 'ItemQuantity', 'ItemRate', 'ItemAmount'];
  const rows = [];
  for (const b of bills) {
    const memo = `Call #${b.call_number} · ${b.site}${b.po ? ` · PO ${b.po}` : ''}`;
    for (const l of b.lines || []) {
      rows.push([b.invoice_number, b.customer, mdy(b.date), mdy(addDays(b.date, terms)), `Net ${terms}`, memo,
        ITEM[l.kind] || 'Service', l.description, n2(l.qty), n2(l.rate), n2(l.amount)]);
    }
  }
  return [head, ...rows].map((r) => r.map(csvCell).join(',')).join('\r\n');
}

export function qboCustomersCsv(bills) {
  const seen = new Map();
  for (const b of bills) if (!seen.has(b.customer)) seen.set(b.customer, b);
  const head = ['Name', 'Company', 'Email', 'Phone', 'Billing Address'];
  const rows = [...seen.values()].map((b) => [b.customer, b.customer, b.customer_email || '', b.customer_phone || '', b.address || '']);
  return [head, ...rows].map((r) => r.map(csvCell).join(',')).join('\r\n');
}

export function desktopIif(bills, terms, ar, income) {
  const out = ['!TRNS\tTRNSTYPE\tDATE\tACCNT\tNAME\tAMOUNT\tDOCNUM\tMEMO\tDUEDATE',
    '!SPL\tTRNSTYPE\tDATE\tACCNT\tNAME\tAMOUNT\tDOCNUM\tMEMO\tQNTY\tPRICE',
    '!ENDTRNS'];
  for (const b of bills) {
    const memo = iifCell(`Call #${b.call_number} ${b.site}${b.po ? ` PO ${b.po}` : ''}`);
    out.push(['TRNS', 'INVOICE', mdy(b.date), iifCell(ar), iifCell(b.customer), n2(b.total), iifCell(b.invoice_number), memo, mdy(addDays(b.date, terms))].join('\t'));
    for (const l of b.lines || []) {
      out.push(['SPL', 'INVOICE', mdy(b.date), iifCell(income), iifCell(b.customer), n2(-Number(l.amount || 0)), iifCell(b.invoice_number),
        iifCell(l.description), n2(-Number(l.qty || 0)), n2(l.rate)].join('\t'));
    }
    out.push('ENDTRNS');
  }
  return out.join('\r\n') + '\r\n';
}

export default function AccountingExport() {
  const [f, setF] = useState({ from: '', to: '', onlyNew: true, terms: 30, ar: 'Accounts Receivable', income: 'Service Income' });
  const [bills, setBills] = useState(null);
  const [err, setErr] = useState('');
  const [msg, setMsg] = useState('');
  const set = (k) => (e) => setF({ ...f, [k]: e.target.type === 'checkbox' ? e.target.checked : e.target.value });
  async function find() {
    setErr(''); setMsg('');
    try { setBills(await act('invoice_export', { p_from: f.from || null, p_to: f.to || null, p_only_new: f.onlyNew })); } catch (x) { setErr(x.message); }
  }
  async function done(kind) {
    try { const n = await act('mark_invoices_exported', { p_work_orders: bills.map((b) => b.work_order_id) }); setMsg(`${kind} downloaded. ${n} bill${n === 1 ? '' : 's'} marked as sent to QuickBooks.`); }
    catch (x) { setErr(x.message); }
  }
  const tooMany = bills && (bills.length > 100 || bills.reduce((t, b) => t + (b.lines || []).length, 0) > 1000);
  const stamp = new Date().toISOString().slice(0, 10);
  return (
    <div className="panel panel-pad stack" style={{ gap: 8 }}>
      <h3 style={{ margin: 0 }}>Send bills to QuickBooks</h3>
      <div className="small muted">Download the bills written here and import them into QuickBooks, so nothing is typed twice. Only bills not sent yet, unless you untick it.</div>
      <div className="row" style={{ alignItems: 'flex-end' }}>
        <label style={{ flex: '0 0 160px' }}>From<input type="date" value={f.from} onChange={set('from')} /></label>
        <label style={{ flex: '0 0 160px' }}>To<input type="date" value={f.to} onChange={set('to')} /></label>
        <label style={{ flex: '0 0 120px' }}>Due in (days)<input type="number" min="0" value={f.terms} onChange={set('terms')} /></label>
        <label className="row small" style={{ gap: 6, fontWeight: 400 }}><input type="checkbox" style={{ width: 'auto' }} checked={f.onlyNew} onChange={set('onlyNew')} />Only bills not sent yet</label>
        <button onClick={find}>Find bills</button>
      </div>
      {err && <div className="error">{err}</div>}
      {msg && <div className="notice small">{msg}</div>}
      {bills && (bills.length === 0 ? <div className="small muted">No bills to send.</div> : (
        <div className="stack" style={{ gap: 8 }}>
          <div className="small"><strong>{bills.length} bill{bills.length === 1 ? '' : 's'}</strong>, {money(bills.reduce((t, b) => t + Number(b.total || 0), 0))} total: {bills.slice(0, 6).map((b) => b.invoice_number).join(', ')}{bills.length > 6 ? '…' : ''}</div>
          {tooMany && <div className="notice small">QuickBooks Online takes up to 100 invoices (1,000 lines) per import. Pick a shorter date range.</div>}
          <div className="row" style={{ gap: 6 }}>
            <button className="primary" disabled={tooMany} onClick={() => { save(`invoices-quickbooks-online-${stamp}.csv`, qboInvoicesCsv(bills, Number(f.terms) || 0), 'text/csv'); done('QuickBooks Online file'); }}>QuickBooks Online (CSV)</button>
            <button onClick={() => save(`customers-quickbooks-${stamp}.csv`, qboCustomersCsv(bills), 'text/csv')}>Customer list (CSV)</button>
          </div>
          <details className="small">
            <summary style={{ cursor: 'pointer' }}>QuickBooks Desktop instead</summary>
            <div className="row" style={{ alignItems: 'flex-end', marginTop: 6 }}>
              <label className="grow">Receivables account<input value={f.ar} onChange={set('ar')} /></label>
              <label className="grow">Income account<input value={f.income} onChange={set('income')} /></label>
              <button onClick={() => { save(`invoices-quickbooks-desktop-${stamp}.iif`, desktopIif(bills, Number(f.terms) || 0, f.ar, f.income), 'text/plain'); done('QuickBooks Desktop file'); }}>QuickBooks Desktop (.iif)</button>
            </div>
            <div className="muted" style={{ marginTop: 4 }}>Use your account names exactly as they are in QuickBooks, and add any new customers there first. Then: File → Utilities → Import → IIF Files.</div>
          </details>
          <div className="small muted">QuickBooks Online: Settings ⚙ → Import data → Invoices → upload the file, check the columns match, tick &ldquo;add new customers&rdquo; if asked. Note: QuickBooks Online&apos;s invoice import doesn&apos;t work when sales tax is turned on in your QuickBooks; then use the Desktop file or wait for live sync (Pro).</div>
        </div>
      ))}
    </div>
  );
}
