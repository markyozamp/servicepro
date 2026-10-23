'use client';

// The store's PO log: every call as a PO, with time on site, the invoice and any flags. Exports to a spreadsheet (CSV).
import { useEffect, useMemo, useState } from 'react';
import { supabase, q } from '@/lib/supabase';
import { money, dateTime, FLAG_LABEL, STATUS } from '@/lib/format';
import { ErrorBox } from './bits';
import { usePlace } from '@/lib/terms';

const COLS = [
  ['PO', (r) => r.po_number], ['Call #', (r) => r.number], ['Location', (r) => r.site_name], ['Contractor', (r) => r.contractor_name],
  ['Problem', (r) => [r.problem_type, r.problem].filter((x, i, a) => x && a.indexOf(x) === i).join(': ')], ['Unit', (r) => r.equipment || r.unit || ''],
  ['Trade', (r) => r.trade_name || ''], ['Status', (r) => STATUS[r.status]?.label || r.status], ['Opened', (r) => r.opened_at], ['Accepted', (r) => r.accepted_at || ''],
  ['First arrived', (r) => r.first_arrived_at || ''], ['Completed', (r) => r.completed_at || ''], ['Trips', (r) => r.trips],
  ['Hours on site', (r) => r.hours_on_site_raw], ['Not to exceed', (r) => r.nte ?? ''], ['Invoice #', (r) => r.invoice_number || ''],
  ['Invoice total', (r) => r.invoice_total ?? (r.mode === 'full' && Number(r.total_cost) > 0 ? r.total_cost : '')],
  ['Hours billed', (r) => r.hours_billed ?? ''], ['Hours verified', (r) => r.hours_verified ?? ''], ['Hours not explained', (r) => r.hours_unexplained ?? ''],
  ['Invoice status', (r) => r.invoice_status || ''], ['Flags', (r) => (r.flags || []).map((f) => FLAG_LABEL[f] || f).join('; ')],
];

export default function PoLog({ customerId = null, siteId = null, onOpen = null } = {}) {
  const place = usePlace();
  const [rows, setRows] = useState([]);
  const [err, setErr] = useState('');
  const [find, setFind] = useState('');
  const [site, setSite] = useState('');
  const [onlyFlags, setOnlyFlags] = useState(false);
  const [who, setWho] = useState('');
  const [trade, setTrade] = useState('');
  const [from, setFrom] = useState('');
  const [to, setTo] = useState('');

  useEffect(() => {
    q(supabase.from('po_log').select('*').order('opened_at', { ascending: false }).limit(2000)).then(setRows).catch((e) => setErr(e.message));
  }, []);

  const base = useMemo(() => rows.filter((r) => (!customerId || r.customer_id === customerId) && (!siteId || r.site_id === siteId)), [rows, customerId, siteId]);
  const sites = useMemo(() => [...new Set(base.map((r) => r.site_name))].sort(), [base]);
  const contractors = useMemo(() => [...new Set(base.map((r) => r.contractor_name))].sort(), [base]);
  const trades = useMemo(() => [...new Set(base.map((r) => r.trade_name).filter(Boolean))].sort(), [base]);
  const day = (t) => { const d = new Date(t); return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`; };
  const filtered = !!(find || site || who || trade || from || to || onlyFlags);
  const shown = base.filter((r) => (!site || r.site_name === site) && (!onlyFlags || (r.flags || []).length)
    && (!who || r.contractor_name === who) && (!trade || r.trade_name === trade)
    && (!from || day(r.opened_at) >= from) && (!to || day(r.opened_at) <= to)
    && (!find || COLS.some(([, f]) => String(f(r)).toLowerCase().includes(find.toLowerCase()))));

  function exportCsv() {
    const esc = (v) => { const s = String(v ?? ''); return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s; };
    const csv = [COLS.map(([h]) => h).join(','), ...shown.map((r) => COLS.map(([, f]) => esc(f(r))).join(','))].join('\n');
    const a = document.createElement('a');
    a.href = URL.createObjectURL(new Blob([csv], { type: 'text/csv' }));
    a.download = `po-log-${new Date().toISOString().slice(0, 10)}.csv`;
    a.click();
  }

  return (
    <div className="panel">
      <div className="stack" style={{ padding: 12, gap: 8 }}>
        <input value={find} onChange={(e) => setFind(e.target.value)} placeholder="Search past calls: PO, problem, unit, invoice #…" aria-label="Search past calls" />
        <div className="row" style={{ gap: 8 }}>
          {contractors.length > 1 && (
            <select value={who} onChange={(e) => setWho(e.target.value)} aria-label="Contractor">
              <option value="">All contractors</option>
              {contractors.map((s) => <option key={s}>{s}</option>)}
            </select>
          )}
          <select value={trade} onChange={(e) => setTrade(e.target.value)} aria-label="Trade">
            <option value="">All trades</option>
            {trades.map((s) => <option key={s}>{s}</option>)}
          </select>
          {sites.length > 1 && !siteId && (
            <select value={site} onChange={(e) => setSite(e.target.value)} aria-label="Location">
              <option value="">All {place.many}</option>
              {sites.map((s) => <option key={s}>{s}</option>)}
            </select>
          )}
          <label className="row small" style={{ gap: 4, fontWeight: 400 }}>From<input type="date" value={from} onChange={(e) => setFrom(e.target.value)} style={{ width: 'auto' }} /></label>
          <label className="row small" style={{ gap: 4, fontWeight: 400 }}>To<input type="date" value={to} onChange={(e) => setTo(e.target.value)} style={{ width: 'auto' }} /></label>
          <label className="row small" style={{ gap: 4, fontWeight: 400 }}><input type="checkbox" checked={onlyFlags} onChange={(e) => setOnlyFlags(e.target.checked)} style={{ width: 'auto' }} /> Flagged only</label>
        </div>
        <div className="row spread small muted">
          <span>{shown.length} of {base.length} call{base.length === 1 ? '' : 's'}{filtered && <> · <button className="linkbtn" onClick={() => { setFind(''); setSite(''); setWho(''); setTrade(''); setFrom(''); setTo(''); setOnlyFlags(false); }}>Clear</button></>}</span>
          <button onClick={exportCsv} disabled={!shown.length}>Export to spreadsheet ({shown.length})</button>
        </div>
      </div>
      <ErrorBox error={err} />
      <div className="po-cards">
        {shown.length === 0 && <div className="po-card muted">{base.length ? 'No calls match. Try fewer filters.' : 'No calls yet.'}</div>}
        {shown.slice(0, 300).map((r) => (
          <div key={r.id} className={`po-card${onOpen ? ' click' : ''}`} onClick={onOpen ? () => onOpen(r.id) : undefined}>
            <div className="spread"><strong>{r.po_number}</strong><span className={`chip tone-${STATUS[r.status]?.tone || 'slate'}`}>{STATUS[r.status]?.label || r.status}</span></div>
            <div className="small muted">#{r.number} · {r.site_name} · {r.contractor_name}{r.trade_name ? ` · ${r.trade_name}` : ''}</div>
            <div>{r.problem_type && r.problem_type !== r.problem ? <strong>{r.problem_type}. </strong> : null}{r.problem}</div>
            <div className="row small" style={{ gap: 8 }}>
              <span className="muted">{dateTime(r.opened_at)}</span>
              <span>{Number(r.hours_on_site_raw).toFixed(2)} h on site</span>
              {r.invoice_number ? <span>{money(r.invoice_total)} invoiced</span> : r.mode === 'full' && Number(r.total_cost) > 0 ? <span>{money(r.total_cost)}</span> : null}
            </div>
            {(r.flags || []).length > 0 && <div className="row" style={{ gap: 4 }}>{r.flags.map((f) => <span key={f} className="chip tone-red">{FLAG_LABEL[f] || f}</span>)}</div>}
          </div>
        ))}
      </div>
      <table className="po-table">
        <thead><tr><th>PO</th><th>Problem</th><th className="hide-sm">Opened / accepted</th><th className="num">On site</th><th className="num">Invoice</th></tr></thead>
        <tbody>
          {shown.length === 0 && <tr><td colSpan={5} className="muted">{base.length ? 'No calls match. Try fewer filters.' : 'No calls yet.'}</td></tr>}
          {shown.map((r) => (
            <tr key={r.id} className={onOpen ? 'click' : undefined} onClick={onOpen ? () => onOpen(r.id) : undefined}>
              <td><strong>{r.po_number}</strong><div className="small muted">#{r.number} · {r.site_name}</div><div className="small muted">{r.contractor_name}</div></td>
              <td>{r.trade_name && <div className="small muted">{r.trade_name}</div>}{r.problem_type && r.problem_type !== r.problem ? <strong>{r.problem_type}. </strong> : null}{r.problem}
                <div className="row" style={{ gap: 4, marginTop: 4 }}>
                  <span className={`chip tone-${STATUS[r.status]?.tone || 'slate'}`}>{STATUS[r.status]?.label || r.status}</span>
                  {(r.flags || []).map((f) => <span key={f} className="chip tone-red">{FLAG_LABEL[f] || f}</span>)}
                </div></td>
              <td className="hide-sm small">{dateTime(r.opened_at)}<div className="muted">{r.accepted_at ? `accepted ${dateTime(r.accepted_at)}` : r.declined_at ? 'declined' : 'not accepted'}</div></td>
              <td className="num">{Number(r.hours_on_site_raw).toFixed(2)} h<div className="small muted">{r.trips} trip{r.trips === 1 ? '' : 's'}</div></td>
              <td className="num">{r.invoice_number ? <>{money(r.invoice_total)}<div className="small muted">{r.invoice_number} · {Number(r.hours_billed).toFixed(2)} h billed</div>
                {Number(r.hours_unexplained) > 0 && <div className="small" style={{ color: 'var(--red-fg)' }}>{Number(r.hours_unexplained).toFixed(2)} h not explained</div>}</>
                : r.mode === 'full' && Number(r.total_cost) > 0 ? money(r.total_cost) : <span className="muted">—</span>}
                {r.nte != null && <div className="small muted">limit {money(r.nte)}</div>}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
