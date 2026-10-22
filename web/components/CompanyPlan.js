'use client';

// Settings → Company & plan: the company's details and what they pay (billing itself is coming with card payments).
import { useEffect, useState } from 'react';
import { supabase, act, q } from '@/lib/supabase';
import { money } from '@/lib/format';
import { ErrorBox, Notice } from './bits';
import Info from './Info';

export const PRICE_PER_LOCATION = 295;
export const PRICE_PER_LOGIN = 25;
export const RESTORE_FEE = 75;

function downloadCsv(name, cols, rows) {
  const esc = (v) => { const t = String(v ?? ''); return /[",\n]/.test(t) ? `"${t.replace(/"/g, '""')}"` : t; };
  const csv = [cols.map(([h]) => h).join(','), ...rows.map((r) => cols.map(([, f]) => esc(f(r))).join(','))].join('\n');
  const a = document.createElement('a');
  a.href = URL.createObjectURL(new Blob([csv], { type: 'text/csv' }));
  a.download = `${name}-${new Date().toISOString().slice(0, 10)}.csv`;
  a.click();
}

export default function CompanyPlan({ org, onSaved }) {
  const [f, setF] = useState({ name: org?.name || '', phone: org?.phone || '', email: org?.email || '' });
  const [n, setN] = useState({ sites: 0, seats: null });
  const [err, setErr] = useState('');
  const [msg, setMsg] = useState('');
  const [busy, setBusy] = useState(false);
  const [soon, setSoon] = useState('');

  useEffect(() => {
    Promise.all([q(supabase.from('sites').select('id')), act('seat_info', {})])
      .then(([s, seats]) => setN({ sites: s.length, seats })).catch((e) => setErr(e.message));
  }, []);

  async function save(e) {
    e.preventDefault();
    setBusy(true); setErr(''); setMsg('');
    try { await act('update_company', { p_name: f.name, p_phone: f.phone, p_email: f.email }); setMsg('Company profile saved.'); onSaved?.(); }
    catch (x) { setErr(x.message); } finally { setBusy(false); }
  }

  async function exportData(kind) {
    setErr(''); setMsg('');
    try {
      if (kind === 'equipment') {
        const r = await q(supabase.from('equipment').select('manufacturer, model, serial, refrigerant, location_description, install_date, retired_at, retired_reason, sites(name), equipment_types(name)').order('site_id'));
        downloadCsv('equipment', [['Location', (x) => x.sites?.name], ['Type', (x) => x.equipment_types?.name], ['Where', (x) => x.location_description], ['Make', (x) => x.manufacturer],
          ['Model', (x) => x.model], ['Serial', (x) => x.serial], ['Refrigerant', (x) => x.refrigerant], ['Installed', (x) => x.install_date], ['Removed', (x) => x.retired_at ? `${x.retired_at.slice(0, 10)} ${x.retired_reason || ''}` : '']], r);
      } else if (kind === 'team') {
        const r = await q(supabase.from('profiles').select('full_name, title, email, phone, is_org_admin, can_approve, approval_limit, all_sites, active').eq('customer_id', org.id).order('full_name'));
        downloadCsv('team', [['Name', (x) => x.full_name], ['Title', (x) => x.title], ['Email', (x) => x.email], ['Phone', (x) => x.phone], ['Admin', (x) => (x.is_org_admin ? 'yes' : '')],
          ['Approves up to', (x) => (x.can_approve ? (x.approval_limit ?? 'any') : '')], ['All locations', (x) => (x.all_sites ? 'yes' : '')], ['Active', (x) => (x.active ? 'yes' : 'no')]], r);
      } else {
        const r = await q(supabase.from('work_orders').select('number, store_po_number, kind, status, issue_description, created_at, completed_at, total_cost, sites(name), contractors(name)').order('created_at', { ascending: false }).limit(5000));
        downloadCsv('service-calls', [['Call #', (x) => x.number], ['PO', (x) => x.store_po_number], ['Location', (x) => x.sites?.name], ['Contractor', (x) => x.contractors?.name], ['Type', (x) => x.kind],
          ['Status', (x) => x.status], ['Problem', (x) => x.issue_description], ['Opened', (x) => x.created_at], ['Completed', (x) => x.completed_at], ['Cost', (x) => x.total_cost]], r);
      }
      setMsg('Downloaded. Open it in Excel or Google Sheets.');
    } catch (x) { setErr(x.message); }
  }

  const total = n.sites * PRICE_PER_LOCATION + (n.seats?.extra || 0) * PRICE_PER_LOGIN;
  return (
    <div className="stack">
      <ErrorBox error={err} /><Notice>{msg}</Notice>
      <form className="stack" style={{ gap: 8 }} onSubmit={save}>
        <h3>Company profile <Info title="Company profile">Your company's name, main phone and email. They show to your contractors on every call and on invoices sent to you. Each location's own name and address are under Locations.</Info></h3>
        <label>Company name<input id="co-name" value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} required /></label>
        <div className="row">
          <label className="grow">Main phone<input id="co-phone" type="tel" value={f.phone} onChange={(e) => setF({ ...f, phone: e.target.value })} /></label>
          <label className="grow">Main email<input id="co-email" type="email" value={f.email} onChange={(e) => setF({ ...f, email: e.target.value })} /></label>
        </div>
        <div><button className="primary" disabled={busy}>Save company profile</button></div>
      </form>

      <div className="stack" style={{ gap: 8, borderTop: '1px solid var(--line)', paddingTop: 12 }}>
        <h3>Your plan <Info title="Your plan">{`$${PRICE_PER_LOCATION} per location per year, paid once a year. Covers all trades (plumbing, electrical, heating, refrigeration) and unlimited service calls. Each location comes with one login; your whole company shares the logins. Extra logins are $${PRICE_PER_LOGIN} per year each. Your contractors use it free. No refunds; cancel anytime to stop the next renewal.`}</Info></h3>
        <table><tbody>
          <tr><td>Locations</td><td className="num">{n.sites} × {money(PRICE_PER_LOCATION)}</td><td className="num">{money(n.sites * PRICE_PER_LOCATION)}</td></tr>
          <tr><td>Extra logins</td><td className="num">{n.seats?.extra || 0} × {money(PRICE_PER_LOGIN)}</td><td className="num">{money((n.seats?.extra || 0) * PRICE_PER_LOGIN)}</td></tr>
          <tr><td><strong>Per year</strong></td><td /><td className="num"><strong>{money(total)}</strong></td></tr>
        </tbody></table>
        {n.seats && <div className="small muted">Logins: {n.seats.used} of {n.seats.included + n.seats.extra} in use ({n.seats.included} included with your locations{n.seats.extra ? `, ${n.seats.extra} extra` : ''}).</div>}
        <div className="row">
          <button type="button" onClick={() => setSoon('logins')}>Buy more logins <span className="soon">Coming soon</span></button>
          <button type="button" onClick={() => setSoon('billing')}>Payment method &amp; invoices <span className="soon">Coming soon</span></button>
        </div>
        {soon === 'restore' && <div className="notice small">{`Restoring from a backup is done by our team, $${RESTORE_FEE} per request, quoted and confirmed with you first. Tell us what went wrong and the date and time to go back to: support@servicecallproof.com. Usually you won't need it: removed equipment and people can be brought back yourself, and calls are never erased.`}</div>}
        {soon && soon !== 'restore' && <div className="notice small">{soon === 'logins'
          ? `Coming soon: buy extra logins here by card ($${PRICE_PER_LOGIN} per login per year, prorated to your renewal date). For now, contact support@servicecallproof.com.`
          : 'Coming soon: your card or bank account on file, your yearly invoice and renewal date. For now, contact support@servicecallproof.com.'}</div>}
      </div>

      <div className="stack" style={{ gap: 8, borderTop: '1px solid var(--line)', paddingTop: 12 }}>
        <h3>Your data <Info title="Your data and backups">{`Your records are kept on our servers. Download a copy anytime for your own files (it opens in Excel). If something gets changed or removed by mistake, most things can be brought back right here: removed equipment and people have a Restore button, and calls are never erased. For anything else, our team can restore your account to an earlier point in time: $${RESTORE_FEE} per request.`}</Info></h3>
        <div className="row">
          <button type="button" onClick={() => exportData('calls')}>Download service calls</button>
          <button type="button" onClick={() => exportData('equipment')}>Download equipment</button>
          <button type="button" onClick={() => exportData('team')}>Download team</button>
          <button type="button" onClick={() => setSoon('restore')}>Restore from a backup (${RESTORE_FEE})</button>
        </div>
      </div>
    </div>
  );
}
