'use client';

import { useCallback, useEffect, useState } from 'react';
import { supabase, act, q } from '@/lib/supabase';
import { useProfile } from '@/lib/useProfile';
import { money, ago, dateTime, FLAG_LABEL } from '@/lib/format';
import TopBar from '@/components/TopBar';
import CallDetail from '@/components/CallDetail';
import NewCallForm from '@/components/NewCallForm';
import { StatusChip, PriorityChip, EtaText, ErrorBox } from '@/components/bits';

const LIST = `id, number, status, priority, issue_description, eta_at, arrived_at, completed_at, created_at, exported_at,
  total_cost, po_cap, invoice_ready, technician_id, qbo_invoice_id,
  sites(name), customers(name), technician:profiles!work_orders_technician_id_fkey(full_name)`;

const COLUMNS = [
  { key: 'new', title: 'New', match: (w) => w.status === 'created' },
  { key: 'out', title: 'Assigned / on the way', match: (w) => ['assigned', 'en_route'].includes(w.status) },
  { key: 'site', title: 'On site', match: (w) => ['on_site', 'awaiting_approval'].includes(w.status) },
  { key: 'review', title: 'Done — needs review', match: (w) => w.status === 'completed' && !w.invoice_ready },
  { key: 'ready', title: 'Ready to invoice', match: (w) => w.status === 'completed' && w.invoice_ready },
];

export default function OfficePortal() {
  const { profile, org } = useProfile(['contractor_admin', 'dispatcher', 'platform_admin']);
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
        q(supabase.from('work_orders').select(LIST).order('priority').order('created_at', { ascending: false }).limit(300)),
        q(supabase.from('guardrail_flags').select('id, work_order_id, flag, description, blocking, triggered_at, work_orders(number, total_cost, sites(name))').is('resolved_at', null).order('triggered_at', { ascending: false })),
        q(supabase.from('profiles').select('id, full_name, phone').eq('role', 'technician').eq('active', true).order('full_name')),
      ]);
      setCalls(c);
      setFlags(f);
      setTechs(t);
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
    const tech = pick[wo.id] || techs[0]?.id;
    if (!tech) return;
    setBusy(true);
    setErr('');
    try {
      await act('assign_work_order', { p_wo: wo.id, p_tech: tech });
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
  const history = calls.filter((c) => ['invoiced', 'cancelled'].includes(c.status));

  return (
    <>
      <TopBar profile={profile} org={org} portal="Office" />
      <main className="page">
        <div className="spread" style={{ marginBottom: 12 }}>
          <div>
            <h1>{org?.name || 'Dispatch'}</h1>
            <div className="muted small">Updates every 20 seconds</div>
          </div>
          {!creating && <button className="primary big" onClick={() => setCreating(true)}>+ New call</button>}
        </div>

        <ErrorBox error={err} />

        {creating && (
          <div style={{ marginBottom: 16 }}>
            <NewCallForm side="office" onCancel={() => setCreating(false)} onCreated={async (wo) => {
              setCreating(false);
              await load();
              setOpen(wo.id);
            }} />
          </div>
        )}

        <div className="tabs">
          <button className={tab === 'board' ? 'on' : ''} onClick={() => setTab('board')}>Dispatch board</button>
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
                  {items.map((w) => (
                    <article key={w.id} className="card" onClick={() => setOpen(w.id)}>
                      <div className="spread">
                        <span className="num">#{w.number}</span>
                        <div className="row" style={{ gap: 4 }}>
                          <PriorityChip priority={w.priority} />
                          {col.key !== 'new' && <StatusChip status={w.status} />}
                        </div>
                      </div>
                      <div className="small muted">{w.customers?.name} · {w.sites?.name}</div>
                      <div className="issue">{w.issue_description}</div>
                      {w.technician && <div className="small">🔧 {w.technician.full_name}</div>}
                      <EtaText wo={w} />
                      {['completed', 'on_site', 'awaiting_approval'].includes(w.status) && (
                        <div className="spread small">
                          <span>{money(w.total_cost)}</span>
                          {w.po_cap != null && <span className="muted">cap {money(w.po_cap)}</span>}
                        </div>
                      )}
                      {blockingByWo[w.id] > 0 && (
                        <span className="chip tone-red" style={{ alignSelf: 'flex-start' }}>{blockingByWo[w.id]} to review</span>
                      )}
                      {col.key === 'new' && (
                        <div className="row" style={{ gap: 6 }} onClick={(e) => e.stopPropagation()}>
                          <select className="grow" value={pick[w.id] || ''} onChange={(e) => setPick({ ...pick, [w.id]: e.target.value })}>
                            <option value="">{techs.length ? 'Technician…' : 'No technicians'}</option>
                            {techs.map((t) => <option key={t.id} value={t.id}>{t.full_name}</option>)}
                          </select>
                          <button className="primary" disabled={busy || !pick[w.id]} onClick={(e) => assign(e, w)}>Assign</button>
                        </div>
                      )}
                      {col.key === 'new' && <div className="small muted">opened {ago(w.created_at)}</div>}
                    </article>
                  ))}
                </section>
              );
            })}
          </div>
        )}

        {tab === 'review' && (
          <div className="panel">
            <table>
              <thead>
                <tr><th>Call</th><th>Issue found</th><th className="num">Total</th><th></th></tr>
              </thead>
              <tbody>
                {reviewFlags.length === 0 && <tr><td colSpan={4} className="muted">Nothing to review. Completed calls with no issues go straight to “Ready to invoice”.</td></tr>}
                {reviewFlags.map((f) => (
                  <tr key={f.id} className="click" onClick={() => setOpen(f.work_order_id)}>
                    <td><strong>#{f.work_orders?.number}</strong><div className="small muted">{f.work_orders?.sites?.name}</div></td>
                    <td>
                      <span className="chip tone-red">{FLAG_LABEL[f.flag] || f.flag}</span>
                      <div className="small" style={{ marginTop: 4 }}>{f.description}</div>
                      <div className="small muted">{ago(f.triggered_at)}</div>
                    </td>
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
                    <td>{w.qbo_invoice_id || '—'}</td>
                    <td className="num">{money(w.total_cost)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </main>

      {open && <CallDetail id={open} side="office" techs={techs} onClose={() => setOpen(null)} onChanged={load} />}
    </>
  );
}
