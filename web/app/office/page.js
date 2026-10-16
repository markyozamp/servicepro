'use client';

import { useCallback, useEffect, useState } from 'react';
import { supabase, act, q } from '@/lib/supabase';
import { useProfile } from '@/lib/useProfile';
import { money, ago, dateTime, date, daysUntil, FLAG_LABEL } from '@/lib/format';
import TopBar from '@/components/TopBar';
import CallDetail from '@/components/CallDetail';
import NewCallForm from '@/components/NewCallForm';
import { StatusChip, PriorityChip, KindChip, LiveLine, BillLine, ErrorBox } from '@/components/bits';

const LIST = `id, number, kind, status, priority, issue_description, created_at, completed_at, invoice_due_at, invoiced_at, due_on,
  total_cost, invoice_ready, qbo_invoice_id, store_po_number, sites(name), customers(name),
  visits(id, visit_no, status, eta_at, arrived_at, received_at, checkin_required, checkin_at, profiles(full_name)),
  parts_orders(status, expected_on, description), po_lines(status)`;

const latest = (w) => (w.visits || []).filter((v) => v.status !== 'cancelled').sort((a, b) => b.visit_no - a.visit_no)[0];

const COLUMNS = [
  { key: 'new', title: 'New', match: (w) => w.status === 'created' },
  { key: 'out', title: 'Assigned / on the way', match: (w) => ['assigned', 'en_route'].includes(w.status) },
  { key: 'site', title: 'On site', match: (w) => ['on_site', 'awaiting_approval'].includes(w.status) },
  { key: 'parts', title: 'Waiting parts / return', match: (w) => ['waiting_parts', 'return_needed'].includes(w.status) },
  { key: 'done', title: 'Done — to invoice', match: (w) => w.status === 'completed' },
];

export default function OfficePortal() {
  const { profile, org } = useProfile('/office');
  const [calls, setCalls] = useState([]);
  const [flags, setFlags] = useState([]);
  const [techs, setTechs] = useState([]);
  const [tab, setTab] = useState('board');
  const [open, setOpen] = useState(null);
  const [creating, setCreating] = useState(false);
  const [pick, setPick] = useState({});
  const [err, setErr] = useState('');
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    try {
      const [c, f, t] = await Promise.all([
        q(supabase.from('work_orders').select(LIST).order('priority').order('created_at', { ascending: false }).limit(400)),
        q(supabase.from('guardrail_flags').select('id, work_order_id, flag, description, blocking, triggered_at, work_orders(number, total_cost, sites(name))')
          .is('resolved_at', null).order('triggered_at', { ascending: false })),
        q(supabase.from('profiles').select('id, full_name, phone').eq('is_technician', true).eq('active', true).order('full_name')),
      ]);
      setCalls(c); setFlags(f); setTechs(t);
    } catch (e) {
      setErr(e.message);
    }
  }, []);

  useEffect(() => {
    if (!profile) return;
    load();
    const t = setInterval(load, 20000);
    return () => clearInterval(t);
  }, [profile, load]);

  async function assign(e, wo) {
    e.stopPropagation();
    if (!pick[wo.id]) return;
    setBusy(true); setErr('');
    try {
      await act('assign_work_order', { p_wo: wo.id, p_tech: pick[wo.id] });
      await load();
    } catch (e2) {
      setErr(e2.message);
    } finally {
      setBusy(false);
    }
  }

  if (!profile) return <div className="page muted">Loading…</div>;

  const blockingByWo = flags.reduce((m, f) => (f.blocking ? { ...m, [f.work_order_id]: (m[f.work_order_id] || 0) + 1 } : m), {});
  const reviewFlags = flags.filter((f) => f.blocking);
  const pms = calls.filter((c) => c.kind === 'pm' && !['completed', 'invoiced', 'cancelled'].includes(c.status));
  const overduePm = pms.filter((p) => p.due_on && daysUntil(p.due_on) < 0).length;
  const toBill = calls.filter((c) => c.status === 'completed').sort((a, b) => new Date(a.invoice_due_at) - new Date(b.invoice_due_at));
  const lateBills = toBill.filter((c) => daysUntil(c.invoice_due_at) < 0).length;
  const history = calls.filter((c) => ['invoiced', 'cancelled'].includes(c.status));

  const assignBox = (w) => (
    <div className="row" style={{ gap: 6 }} onClick={(e) => e.stopPropagation()}>
      <select className="grow" value={pick[w.id] || ''} onChange={(e) => setPick({ ...pick, [w.id]: e.target.value })}>
        <option value="">{techs.length ? 'Technician…' : 'No technicians'}</option>
        {techs.map((t) => <option key={t.id} value={t.id}>{t.full_name}</option>)}
      </select>
      <button className="primary" disabled={busy || !pick[w.id]} onClick={(e) => assign(e, w)}>Assign</button>
    </div>
  );

  return (
    <>
      <TopBar profile={profile} org={org} portal="Office" />
      <main className="page">
        <div className="spread" style={{ marginBottom: 12 }}>
          <div>
            <h1>{org?.name || 'Dispatch'}</h1>
            <div className="muted small">Updates every 20 seconds</div>
          </div>
          {!creating && (profile.is_org_admin || profile.can_dispatch) && <button className="primary big" onClick={() => setCreating(true)}>+ New call</button>}
        </div>

        <ErrorBox error={err} />

        {creating && (
          <div style={{ marginBottom: 16 }}>
            <NewCallForm side="office" profile={profile} onCancel={() => setCreating(false)} onCreated={async (wo) => {
              setCreating(false); await load(); setOpen(wo.id);
            }} />
          </div>
        )}

        <div className="tabs">
          <button className={tab === 'board' ? 'on' : ''} onClick={() => setTab('board')}>Dispatch board</button>
          <button className={tab === 'pm' ? 'on' : ''} onClick={() => setTab('pm')}>
            PM{pms.length > 0 && <span className="count" style={{ background: overduePm ? 'var(--red-fg)' : 'var(--ink-3)' }}>{pms.length}</span>}
          </button>
          <button className={tab === 'billing' ? 'on' : ''} onClick={() => setTab('billing')}>
            Billing{toBill.length > 0 && <span className="count" style={{ background: lateBills ? 'var(--red-fg)' : 'var(--ink-3)' }}>{toBill.length}</span>}
          </button>
          <button className={tab === 'review' ? 'on' : ''} onClick={() => setTab('review')}>
            Review queue{reviewFlags.length > 0 && <span className="count">{reviewFlags.length}</span>}
          </button>
          <button className={tab === 'history' ? 'on' : ''} onClick={() => setTab('history')}>Invoiced & cancelled</button>
        </div>

        {tab === 'board' && (
          <div className="board">
            {COLUMNS.map((col) => {
              const items = calls.filter(col.match);
              return (
                <section key={col.key} className="column">
                  <div className="column-head"><span>{col.title}</span><span>{items.length}</span></div>
                  {items.length === 0 && <div className="small muted">Nothing here</div>}
                  {items.map((w) => {
                    const v = latest(w);
                    const parts = (w.parts_orders || []).filter((o) => ['needed', 'ordered'].includes(o.status));
                    const waitingApproval = (w.po_lines || []).some((l) => l.status === 'pending');
                    return (
                      <article key={w.id} className="card" onClick={() => setOpen(w.id)}>
                        <div className="spread">
                          <span className="num">#{w.number}</span>
                          <div className="row" style={{ gap: 4 }}>
                            <PriorityChip priority={w.priority} /><KindChip kind={w.kind} />
                            {col.key !== 'new' && col.key !== 'done' && <StatusChip status={w.status} />}
                          </div>
                        </div>
                        <div className="small muted">{w.customers?.name} · {w.sites?.name}</div>
                        <div className="issue">{w.issue_description}</div>
                        {v && <div className="small">🔧 {v.profiles?.full_name}{v.visit_no > 1 ? ` · visit ${v.visit_no}` : ''}</div>}
                        <LiveLine wo={w} visit={v} />
                        {waitingApproval && <span className="chip tone-red" style={{ alignSelf: 'flex-start' }}>Waiting on customer approval</span>}
                        {col.key === 'parts' && parts.length > 0 && (
                          <div className="small muted">{parts.map((o) => `${o.description}${o.expected_on ? ` (exp. ${date(o.expected_on)})` : ''}`).join(', ')}</div>
                        )}
                        {['site', 'done'].includes(col.key) && <div className="small">{money(w.total_cost)}</div>}
                        {col.key === 'done' && <BillLine wo={w} />}
                        {blockingByWo[w.id] > 0 && <span className="chip tone-red" style={{ alignSelf: 'flex-start' }}>{blockingByWo[w.id]} to review</span>}
                        {(col.key === 'new' || (col.key === 'parts' && w.status === 'return_needed')) && assignBox(w)}
                        {col.key === 'new' && <div className="small muted">opened {ago(w.created_at)}</div>}
                      </article>
                    );
                  })}
                </section>
              );
            })}
          </div>
        )}

        {tab === 'pm' && (
          <div className="panel">
            <table>
              <thead><tr><th>PM</th><th>Location</th><th>Due</th><th>Technician</th><th></th></tr></thead>
              <tbody>
                {pms.length === 0 && <tr><td colSpan={5} className="muted">No open PM visits. They're created automatically 14 days before they're due.</td></tr>}
                {pms.sort((a, b) => (a.due_on > b.due_on ? 1 : -1)).map((p) => {
                  const v = latest(p); const d = daysUntil(p.due_on);
                  return (
                    <tr key={p.id} className="click" onClick={() => setOpen(p.id)}>
                      <td><strong>#{p.number}</strong><div className="small">{p.issue_description}</div></td>
                      <td>{p.customers?.name}<div className="small muted">{p.sites?.name}</div></td>
                      <td>{d < 0 ? <span className="chip tone-red">OVERDUE {-d} days</span> : <span className={`chip ${d <= 7 ? 'tone-amber' : 'tone-slate'}`}>{date(p.due_on)}</span>}</td>
                      <td>{v ? v.profiles?.full_name : assignBox(p)}</td>
                      <td><StatusChip status={p.status} /></td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}

        {tab === 'billing' && (
          <div className="panel">
            <table>
              <thead><tr><th>Call</th><th>Customer</th><th>Invoice due</th><th>Ready?</th><th className="num">Total</th></tr></thead>
              <tbody>
                {toBill.length === 0 && <tr><td colSpan={5} className="muted">Nothing waiting to be invoiced.</td></tr>}
                {toBill.map((w) => {
                  const d = daysUntil(w.invoice_due_at);
                  return (
                    <tr key={w.id} className="click" onClick={() => setOpen(w.id)}>
                      <td><strong>#{w.number}</strong><div className="small muted">completed {date(w.completed_at)}</div></td>
                      <td>{w.customers?.name}<div className="small muted">{w.sites?.name}</div></td>
                      <td>{d < 0 ? <span className="chip tone-red">LATE {-d} days — store notified</span>
                        : <span className={`chip ${d <= 2 ? 'tone-amber' : 'tone-slate'}`}>{date(w.invoice_due_at)} ({d} days)</span>}</td>
                      <td>{w.invoice_ready ? <span className="chip tone-green">Ready</span> : <span className="chip tone-red">{blockingByWo[w.id] || 0} to review</span>}</td>
                      <td className="num">{money(w.total_cost)}</td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}

        {tab === 'review' && (
          <div className="panel">
            <table>
              <thead><tr><th>Call</th><th>Issue found</th><th className="num">Total</th><th></th></tr></thead>
              <tbody>
                {reviewFlags.length === 0 && <tr><td colSpan={4} className="muted">Nothing to review.</td></tr>}
                {reviewFlags.map((f) => (
                  <tr key={f.id} className="click" onClick={() => setOpen(f.work_order_id)}>
                    <td><strong>#{f.work_orders?.number}</strong><div className="small muted">{f.work_orders?.sites?.name}</div></td>
                    <td><span className="chip tone-red">{FLAG_LABEL[f.flag] || f.flag}</span><div className="small" style={{ marginTop: 4 }}>{f.description}</div><div className="small muted">{ago(f.triggered_at)}</div></td>
                    <td className="num">{money(f.work_orders?.total_cost)}</td>
                    <td className="num"><button>Review</button></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}

        {tab === 'history' && (
          <div className="panel">
            <table>
              <thead><tr><th>Call</th><th>Customer</th><th>Status</th><th>Invoice</th><th className="num">Total</th></tr></thead>
              <tbody>
                {history.length === 0 && <tr><td colSpan={5} className="muted">No invoiced or cancelled calls yet.</td></tr>}
                {history.map((w) => (
                  <tr key={w.id} className="click" onClick={() => setOpen(w.id)}>
                    <td><strong>#{w.number}</strong><div className="small muted">{dateTime(w.created_at)}</div></td>
                    <td>{w.customers?.name}<div className="small muted">{w.sites?.name}</div></td>
                    <td><StatusChip status={w.status} /></td>
                    <td>{w.qbo_invoice_id || '—'}{w.invoiced_at && w.invoice_due_at && new Date(w.invoiced_at) > new Date(w.invoice_due_at) ? <span className="chip tone-red" style={{ marginLeft: 6 }}>late</span> : null}</td>
                    <td className="num">{money(w.total_cost)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </main>

      {open && <CallDetail id={open} side="office" profile={profile} techs={techs} onClose={() => setOpen(null)} onChanged={load} />}
    </>
  );
}
