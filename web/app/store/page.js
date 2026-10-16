'use client';

import { useCallback, useEffect, useState } from 'react';
import { supabase, act, q } from '@/lib/supabase';
import { useProfile } from '@/lib/useProfile';
import { money, ago, dateTime } from '@/lib/format';
import TopBar from '@/components/TopBar';
import CallDetail from '@/components/CallDetail';
import NewCallForm from '@/components/NewCallForm';
import { StatusChip, PriorityChip, EtaText, ErrorBox } from '@/components/bits';

const LIST = `id, number, status, priority, issue_description, eta_at, arrived_at, completed_at, created_at,
  total_cost, po_cap, sites(name), technician:profiles!work_orders_technician_id_fkey(full_name)`;

export default function StorePortal() {
  const { profile, org } = useProfile(['customer_admin', 'customer_user']);
  const [calls, setCalls] = useState([]);
  const [approvals, setApprovals] = useState([]);
  const [tab, setTab] = useState('open');
  const [open, setOpen] = useState(null);
  const [creating, setCreating] = useState(false);
  const [err, setErr] = useState('');
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    try {
      const [c, a] = await Promise.all([
        q(supabase.from('work_orders').select(LIST).order('created_at', { ascending: false }).limit(200)),
        q(supabase.from('approvals').select('id, requested_amount, reason, created_at, work_orders(id, number, po_cap, total_cost, sites(name))').eq('status', 'pending')),
      ]);
      setCalls(c);
      setApprovals(a);
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

  async function decide(id, yes) {
    setBusy(true);
    setErr('');
    try {
      await act('decide_approval', { p_approval: id, p_approve: yes });
      await load();
    } catch (e) {
      setErr(e.message);
    } finally {
      setBusy(false);
    }
  }

  if (!profile) return <div className="page muted">Loading…</div>;

  const isOpen = (s) => !['completed', 'invoiced', 'cancelled'].includes(s);
  const shown = calls.filter((c) => (tab === 'open' ? isOpen(c.status) : !isOpen(c.status)));
  const openCount = calls.filter((c) => isOpen(c.status)).length;

  return (
    <>
      <TopBar profile={profile} org={org} portal="Store" />
      <main className="page stack" style={{ gap: 16 }}>
        <div className="spread">
          <div>
            <h1>{org?.name || 'Your stores'}</h1>
            <div className="muted small">Service calls, approvals and equipment history</div>
          </div>
          {!creating && <button className="primary big" onClick={() => setCreating(true)}>+ New service call</button>}
        </div>

        <ErrorBox error={err} />

        {creating && (
          <NewCallForm side="store" onCancel={() => setCreating(false)} onCreated={async (wo) => {
            setCreating(false);
            await load();
            setOpen(wo.id);
          }} />
        )}

        {approvals.map((a) => (
          <div key={a.id} className="panel panel-pad spread" style={{ borderColor: '#e6b3ab', background: '#fffaf9' }}>
            <div className="stack" style={{ gap: 4 }}>
              <div className="row" style={{ gap: 8 }}>
                <span className="chip tone-red">Approval needed</span>
                <strong>Call #{a.work_orders?.number} · {a.work_orders?.sites?.name}</strong>
              </div>
              <div>{a.reason}</div>
              <div className="small muted">
                Extra {money(a.requested_amount)} on a {money(a.work_orders?.po_cap)} cap · requested {ago(a.created_at)}
              </div>
            </div>
            <div className="row">
              <button className="link" onClick={() => setOpen(a.work_orders?.id)}>Details</button>
              <button className="danger" disabled={busy} onClick={() => decide(a.id, false)}>Decline</button>
              <button className="primary" disabled={busy} onClick={() => decide(a.id, true)}>Approve {money(a.requested_amount)}</button>
            </div>
          </div>
        ))}

        <div className="panel">
          <div className="tabs" style={{ padding: '0 8px', marginBottom: 0 }}>
            <button className={tab === 'open' ? 'on' : ''} onClick={() => setTab('open')}>Open ({openCount})</button>
            <button className={tab === 'done' ? 'on' : ''} onClick={() => setTab('done')}>Completed</button>
          </div>
          <table>
            <thead>
              <tr>
                <th>Call</th>
                <th>Problem</th>
                <th className="hide-sm">Technician</th>
                <th>Status</th>
                <th className="num">Cost</th>
              </tr>
            </thead>
            <tbody>
              {shown.length === 0 && (
                <tr><td colSpan={5} className="muted">{tab === 'open' ? 'No open calls.' : 'No completed calls yet.'}</td></tr>
              )}
              {shown.map((c) => (
                <tr key={c.id} className="click" onClick={() => setOpen(c.id)}>
                  <td>
                    <strong>#{c.number}</strong>
                    <div className="small muted">{c.sites?.name}</div>
                    <div className="small muted">{dateTime(c.created_at)}</div>
                  </td>
                  <td>
                    <div className="row" style={{ gap: 6 }}><PriorityChip priority={c.priority} /></div>
                    {c.issue_description}
                  </td>
                  <td className="hide-sm">{c.technician?.full_name || <span className="muted">—</span>}</td>
                  <td>
                    <div className="stack" style={{ gap: 4 }}>
                      <StatusChip status={c.status} />
                      <EtaText wo={c} />
                    </div>
                  </td>
                  <td className="num">
                    {Number(c.total_cost) > 0 ? money(c.total_cost) : <span className="muted">—</span>}
                    {c.po_cap != null && <div className="small muted">cap {money(c.po_cap)}</div>}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </main>

      {open && <CallDetail id={open} side="store" onClose={() => setOpen(null)} onChanged={load} />}
    </>
  );
}
