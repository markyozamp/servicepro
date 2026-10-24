'use client';

// Base and up: your flat-rate price book. Tasks with a flat price that covers labor and parts, optional prices
// for one customer, and for each customer whether you bill hourly (time and materials) or flat rate.
import { useCallback, useEffect, useState } from 'react';
import { supabase, act, q } from '@/lib/supabase';
import { money } from '@/lib/format';

// Simple CSV: first row is the header (code, name, price, category, description, in any order)
function parseCsv(text) {
  const rows = [];
  let row = []; let cur = ''; let quoted = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (quoted) {
      if (c === '"' && text[i + 1] === '"') { cur += '"'; i++; } else if (c === '"') quoted = false; else cur += c;
    } else if (c === '"') quoted = true;
    else if (c === ',' || c === '\t') { row.push(cur); cur = ''; }
    else if (c === '\n' || c === '\r') { if (c === '\r' && text[i + 1] === '\n') i++; row.push(cur); rows.push(row); row = []; cur = ''; }
    else cur += c;
  }
  if (cur || row.length) { row.push(cur); rows.push(row); }
  const clean = rows.filter((r) => r.some((x) => x.trim()));
  if (clean.length < 2) return [];
  const head = clean[0].map((x) => x.trim().toLowerCase());
  const col = (names) => head.findIndex((h) => names.some((n) => h === n || h.includes(n)));
  const ix = { code: col(['code', 'sku', 'task #']), name: col(['name', 'task', 'description of work', 'item']), price: col(['price', 'amount', 'rate']),
    category: col(['category', 'group', 'section']), description: col(['description', 'details', 'notes']) };
  if (ix.description === ix.name) ix.description = -1;
  return clean.slice(1).map((r) => Object.fromEntries(Object.entries(ix).filter(([, i]) => i >= 0).map(([k, i]) => [k, (r[i] || '').trim()])));
}

export default function PriceBook({ profile }) {
  const [items, setItems] = useState([]);
  const [customers, setCustomers] = useState([]);
  const [cust, setCust] = useState('');
  const [prices, setPrices] = useState({});
  const [f, setF] = useState(null);           // the task being added or changed
  const [csv, setCsv] = useState(null);
  const [filter, setFilter] = useState('');
  const [err, setErr] = useState('');
  const [msg, setMsg] = useState('');

  const load = useCallback(async () => {
    try {
      const [book, cc] = await Promise.all([
        act('price_book', { p_customer: cust || null, p_all: true }),
        q(supabase.from('customer_contractors').select('customer_id, billing_method, store_removed_at, contractor_removed_at, customers(name)').eq('contractor_id', profile.contractor_id)).catch(() => []),
      ]);
      setItems(book || []);
      setCustomers((cc || []).filter((c) => !c.store_removed_at && !c.contractor_removed_at).sort((a, b) => (a.customers?.name || '').localeCompare(b.customers?.name || '')));
      setPrices(Object.fromEntries((book || []).map((i) => [i.id, i.customer_price ?? ''])));
    } catch (x) { setErr(x.message); }
  }, [cust, profile]);
  useEffect(() => { load(); }, [load]);

  async function run(fn, args, done) {
    setErr(''); setMsg('');
    try { const r = await act(fn, args); done?.(r); await load(); } catch (x) { setErr(x.message); }
  }
  const c = customers.find((x) => x.customer_id === cust);
  const shown = items.filter((i) => !filter || `${i.code || ''} ${i.name} ${i.category || ''}`.toLowerCase().includes(filter.toLowerCase()));

  return (
    <div className="panel panel-pad stack" style={{ gap: 10 }}>
      <div className="spread"><h3 style={{ margin: 0 }}>Price book (flat rate)</h3><span className="small muted">{items.filter((i) => i.active).length} tasks</span></div>
      <div className="small muted">For shops that bill flat rate: each task has one price covering labor and parts. Set each customer to hourly or flat rate below. On a flat-rate call your tech picks the tasks done, and the bill is those tasks. The customer still sees the verified time on site, for reference.</div>

      <div className="row" style={{ gap: 8, alignItems: 'flex-end' }}>
        <label className="grow">Customer <span className="muted" style={{ fontWeight: 400 }}>(for their billing and their prices)</span>
          <select value={cust} onChange={(e) => setCust(e.target.value)}>
            <option value="">— Book prices —</option>
            {customers.map((x) => <option key={x.customer_id} value={x.customer_id}>{x.customers?.name}{x.billing_method === 'flat' ? ' (flat rate)' : ''}</option>)}
          </select></label>
        {c && (
          <label>Bill them
            <select value={c.billing_method} onChange={(e) => run('set_billing_method', { p_customer: cust, p_method: e.target.value }, () => setMsg(`Saved. ${c.customers?.name} has been told.`))}>
              <option value="hourly">Hourly (time and materials)</option>
              <option value="flat">Flat rate (price book)</option>
            </select></label>
        )}
      </div>

      <div className="row" style={{ gap: 6 }}>
        <input value={filter} onChange={(e) => setFilter(e.target.value)} placeholder="Find a task" style={{ maxWidth: 260 }} />
        <button type="button" onClick={() => setF({ id: null, code: '', name: '', price: '', category: '', description: '', active: true })}>+ Task</button>
        <button type="button" onClick={() => setCsv({ text: '', rows: null })}>Import from a spreadsheet</button>
      </div>

      {csv && (
        <div className="stack" style={{ gap: 6, border: '1px solid var(--line)', borderRadius: 10, padding: 10 }}>
          <strong>Import your price book</strong>
          <div className="small muted">Save your price list as CSV (Excel: File → Save As → CSV) and pick it, or paste it here. The first row names the columns: code, name, price, category, description. A task with the same code (or the same name) is updated.</div>
          <input type="file" accept=".csv,text/csv,.txt" onChange={async (e) => { const file = e.target.files?.[0]; if (file) { const text = await file.text(); setCsv({ text, rows: parseCsv(text) }); } }} />
          <textarea rows={4} value={csv.text} onChange={(e) => setCsv({ text: e.target.value, rows: parseCsv(e.target.value) })} placeholder={'code,name,price,category\nD-100,Clear main drain,325,Drains'} />
          {csv.rows && <div className="small">{csv.rows.length} rows found{csv.rows[0] ? `, e.g. "${csv.rows[0].name}" at ${csv.rows[0].price}` : ''}</div>}
          <div className="row">
            <button className="primary" disabled={!csv.rows?.length} onClick={() => run('import_price_book', { p_rows: csv.rows }, (r) => { setMsg(`Imported: ${r.added} added, ${r.updated} updated${r.skipped ? `, ${r.skipped} skipped (no name or price)` : ''}.`); setCsv(null); })}>Import</button>
            <button onClick={() => setCsv(null)}>Cancel</button>
          </div>
        </div>
      )}

      {f && (
        <form className="stack" style={{ gap: 6, border: '1px solid var(--line)', borderRadius: 10, padding: 10 }} onSubmit={(e) => {
          e.preventDefault();
          run('save_price_item', { p_id: f.id, p_name: f.name, p_price: Number(f.price), p_code: f.code, p_category: f.category, p_description: f.description, p_active: f.active }, () => { setF(null); setMsg('Saved.'); });
        }}>
          <div className="row">
            <label style={{ flex: '0 0 110px' }}>Code<input value={f.code} onChange={(e) => setF({ ...f, code: e.target.value })} placeholder="optional" /></label>
            <label className="grow">Task<input value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} required placeholder="e.g. Replace run capacitor" /></label>
            <label style={{ flex: '0 0 120px' }}>Price ($)<input type="number" step="0.01" min="0" value={f.price} onChange={(e) => setF({ ...f, price: e.target.value })} required /></label>
          </div>
          <div className="row">
            <label style={{ flex: '0 0 180px' }}>Category<input value={f.category} onChange={(e) => setF({ ...f, category: e.target.value })} placeholder="e.g. Drains" /></label>
            <label className="grow">What it includes<input value={f.description} onChange={(e) => setF({ ...f, description: e.target.value })} placeholder="optional" /></label>
          </div>
          <label className="row small" style={{ gap: 6, fontWeight: 400 }}><input type="checkbox" style={{ width: 'auto' }} checked={f.active} onChange={(e) => setF({ ...f, active: e.target.checked })} />In use</label>
          <div className="row"><button className="primary">Save task</button><button type="button" onClick={() => setF(null)}>Cancel</button></div>
        </form>
      )}

      {err && <div className="error">{err}</div>}
      {msg && <div className="notice small">{msg}</div>}

      {shown.length > 0 ? (
        <div className="tablewrap">
          <table>
            <thead><tr><th>Task</th><th className="num">Book price</th>{c && <th className="num">{c.customers?.name}&apos;s price</th>}<th /></tr></thead>
            <tbody>
              {shown.map((i) => (
                <tr key={i.id} style={i.active ? {} : { opacity: 0.55 }}>
                  <td>{i.code ? <span className="small muted">{i.code} </span> : null}{i.name}{i.category ? <span className="small muted"> · {i.category}</span> : null}{!i.active && <span className="small muted"> (not in use)</span>}</td>
                  <td className="num">{money(i.book_price)}</td>
                  {c && (
                    <td className="num">
                      <input type="number" step="0.01" min="0" style={{ width: 100 }} value={prices[i.id] ?? ''} placeholder="same"
                        onChange={(e) => setPrices({ ...prices, [i.id]: e.target.value })}
                        onBlur={(e) => { const v = e.target.value; if (String(v) !== String(i.customer_price ?? '')) run('set_customer_price', { p_item: i.id, p_customer: cust, p_price: v === '' ? null : Number(v) }); }} />
                    </td>
                  )}
                  <td><button type="button" className="linkbtn small" onClick={() => setF({ id: i.id, code: i.code || '', name: i.name, price: i.book_price, category: i.category || '', description: i.description || '', active: i.active })}>Change</button></td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      ) : <div className="small muted">{items.length ? 'No task matches.' : 'No tasks yet. Add them one by one, or import your price list from a spreadsheet.'}</div>}
    </div>
  );
}
