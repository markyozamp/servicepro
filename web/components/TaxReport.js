'use client';

// Base: the tax report for a month (or any dates): sales by rate (taxed, not taxed, exempt), the sales tax you charged,
// and the use tax you owe on built-in parts at your cost. For your filing, or your accountant.
import { useState } from 'react';
import { act } from '@/lib/supabase';
import { money, date } from '@/lib/format';
import { pct } from '@/lib/tax';

const pad = (n) => String(n).padStart(2, '0');
const ymd = (d) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
const lastMonth = () => { const n = new Date(); return { from: ymd(new Date(n.getFullYear(), n.getMonth() - 1, 1)), to: ymd(new Date(n.getFullYear(), n.getMonth(), 0)) }; };
const csvCell = (v) => `"${String(v ?? '').replace(/"/g, '""')}"`;

export default function TaxReport() {
  const [f, setF] = useState(lastMonth);
  const [r, setR] = useState(null);
  const [err, setErr] = useState('');
  async function run() { setErr(''); try { setR(await act('tax_report', { p_from: f.from, p_to: f.to })); } catch (x) { setErr(x.message); } }
  function download() {
    const rows = [['Rate', 'State', 'Rate %', 'Bills', 'Sales', 'Taxed sales', 'Exempt sales', 'Not taxed (incl. built-in)', 'Sales tax charged', 'Built-in cost', 'Use tax']];
    for (const a of r.areas) rows.push([a.area, a.state, a.rate, a.bills, a.sales, a.taxable || 0, a.exempt_sales, a.nontaxable, a.sales_tax, a.use_basis, a.use_tax]);
    rows.push([]); rows.push(['Built-in parts (use tax)']); rows.push(['Invoice', 'Date', 'Customer', 'Location', 'Rate', 'Item', 'Qty', 'Your cost', 'Cost total', 'Use tax']);
    for (const l of r.use_lines) rows.push([l.invoice_number, l.date, l.customer, l.site, l.area, l.description, l.qty, l.cost ?? '', l.basis, l.use_tax]);
    const a = document.createElement('a');
    a.href = URL.createObjectURL(new Blob([rows.map((x) => x.map(csvCell).join(',')).join('\r\n')], { type: 'text/csv' }));
    a.download = `tax-report-${f.from}-to-${f.to}.csv`; a.click();
  }
  const sum = (k) => (r?.areas || []).reduce((t, a) => t + Number(a[k] || 0), 0);
  return (
    <div className="panel panel-pad stack" style={{ gap: 8 }}>
      <h3 style={{ margin: 0 }}>Sales and use tax report</h3>
      <div className="small muted">What you charged and what you owe, by rate, for the bills sent in these dates. Use tax is figured on your cost of built-in parts and equipment.</div>
      <div className="row" style={{ alignItems: 'flex-end' }}>
        <label style={{ flex: '0 0 160px' }}>From<input type="date" value={f.from} onChange={(e) => setF({ ...f, from: e.target.value })} /></label>
        <label style={{ flex: '0 0 160px' }}>To<input type="date" value={f.to} onChange={(e) => setF({ ...f, to: e.target.value })} /></label>
        <button onClick={run}>Show</button>
        {r && <button onClick={download}>Download (CSV)</button>}
      </div>
      {err && <div className="error">{err}</div>}
      {r && (r.areas.length === 0 ? <div className="small muted">No bills sent in those dates.</div> : (
        <>
          <div className="tablewrap">
            <table className="small">
              <thead><tr><th>Rate</th><th className="num">Bills</th><th className="num">Taxed sales</th><th className="num">Exempt</th><th className="num">Not taxed</th><th className="num">Sales tax</th><th className="num">Built-in cost</th><th className="num">Use tax</th></tr></thead>
              <tbody>
                {r.areas.map((a, i) => (
                  <tr key={i}><td>{a.area}{a.rate != null ? ` ${pct(a.rate)}` : ''}</td><td className="num">{a.bills}</td><td className="num">{money(a.taxable || 0)}</td><td className="num">{money(a.exempt_sales)}</td>
                    <td className="num">{money(a.nontaxable)}</td><td className="num">{money(a.sales_tax)}</td><td className="num">{money(a.use_basis)}</td><td className="num">{money(a.use_tax)}</td></tr>
                ))}
                <tr><td><strong>Total</strong></td><td className="num">{sum('bills')}</td><td className="num">{money(sum('taxable'))}</td><td className="num">{money(sum('exempt_sales'))}</td>
                  <td className="num">{money(sum('nontaxable'))}</td><td className="num"><strong>{money(sum('sales_tax'))}</strong></td><td className="num">{money(sum('use_basis'))}</td><td className="num"><strong>{money(sum('use_tax'))}</strong></td></tr>
              </tbody>
            </table>
          </div>
          {r.paid_at_purchase && sum('use_tax') > 0 && <div className="notice small">You&apos;ve set that you pay sales tax when you buy parts, so the use tax column is usually already paid at the supply house. It&apos;s listed so your accountant can confirm.</div>}
          {r.use_lines.some((l) => l.cost == null) && <div className="small" style={{ color: 'var(--red-fg)' }}>Some built-in lines have no cost entered, so their use tax shows as $0. Check them below.</div>}
          {r.use_lines.length > 0 && (
            <details className="small"><summary style={{ cursor: 'pointer' }}>Built-in parts and equipment ({r.use_lines.length})</summary>
              <table className="small" style={{ marginTop: 6 }}><tbody>
                {r.use_lines.map((l, i) => <tr key={i}><td>{l.invoice_number} · {date(l.date)}</td><td>{l.customer}, {l.site}</td><td>{l.description} × {Number(l.qty)}</td>
                  <td className="num">{l.cost == null ? 'no cost' : money(l.basis)}</td><td className="num">{money(l.use_tax)}</td></tr>)}
              </tbody></table>
            </details>
          )}
          <div className="small muted">Rules differ by state; have your accountant confirm before you file.</div>
        </>
      ))}
    </div>
  );
}
