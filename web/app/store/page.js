'use client';

import { useCallback, useEffect, useState } from 'react';
import { supabase, act, q } from '@/lib/supabase';
import { useProfile } from '@/lib/useProfile';
import { money, ago, dateTime, date, poLabel, PO_KIND } from '@/lib/format';
import TopBar from '@/components/TopBar';
import CallDetail from '@/components/CallDetail';
import NewCallForm from '@/components/NewCallForm';
import { StatusChip, PriorityChip, KindChip, LiveLine, BillLine, ErrorBox, Notice } from '@/components/bits';

const LIST = `id, number, kind, status, priority, issue_description, created_at, completed_at, invoice_due_at, total_cost, store_po_number,
  sites(name), visits(id, visit_no, status, eta_at, arrived_at, received_at, checkin_required, checkin_at, profiles(full_name)),
  parts_orders(status, expected_on)`;

const latest = (w) => (w.visits || []).filter((v) => v.status !== 'cancelled').sort((a, b) => b.visit_no - a.visit_no)[0];

export default function StorePortal() {
  const { profile, org } = useProfile('/store');
  const [calls, setCalls] = useState([]);
  const [pending, setPending] = useState([]);
  const [pms, setPms] = useState([]);
  const [tab, setTab] = useState('open');
  const [open, setOpen] = useState(null);
  const [creating, setCreating] = useState(false);
  const [err, setErr] = useState('');
  const [msg, setMsg] = useState('');
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    try {
      const [c, p, pm, st] = await Promise.all([
        q(supabase.from('work_orders').select(LIST).order('created_at', { ascending: false }).limit(300)),
        q(supabase.from('po_lines').select('id, seq, kind, amount, description, requested_at, owner_status, owner:property_owners(name), work_orders(id, number, store_po_number, unit, sites(name))').eq('status', 'pending')),
        q(supabase.from('pm_status').select('*').order('due_on')),
        q(supabase.from('sites').select('id, name')),
      ]);
      const siteName = Object.fromEntries(st.map((x) => [x.id, x.name]));
      setCalls(c); setPending(p); setPms(pm.map((x) => ({ ...x, site_name: siteName[x.site_id] })));
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
    let reason = null;
    if (!yes) { reason = window.prompt('Reason for declining (the contractor will see this):'); if (reason === null) return; }
    setBusy(true); setErr(''); setMsg('');
    try {
      const r = await act('decide_po_line', { p_line: id, p_approve: yes, p_reason: reason });
      if (r?.escalated) setMsg(r.message);
      await load();
    } catch (e) {
      setErr(e.message);
    } finally {
      setBusy(false);
    }
  }

  if (!profile) return <div className="page muted">Loading…</div>;

  const isOpen = (s) => !['completed', 'invoiced', 'cancelled'].includes(s);
  const late = calls.filter((c) => c.status === 'completed' && c.invoice_due_at && new Date(c.invoice_due_at) < new Date());
  const shown = calls.filter((c) => c.kind !== 'pm' || !isOpen(c.status)).filter((c) =>
    tab === 'open' ? isOpen(c.status) : tab === 'billing' ? c.status === 'completed' : ['invoiced', 'cancelled'].includes(c.status));
  const counts = {
    open: calls.filter((c) => c.kind !== 'pm' && isOpen(c.status)).length,
    billing: calls.filter((c) => c.status === 'completed').length,
  };

  return (
    <>
      <TopBar profile={profile} org={org} portal={org?.kind === 'property_manager' ? 'Properties' : 'Store'} />
      <main className="page stack" style={{ gap: 16 }}>
        <div className="spread">
          <div>
            <h1>{org?.name || 'Your locations'}</h1>
            <div className="muted small">{profile.title || ''}{profile.approval_limit != null ? ` · approves up to ${money(profile.approval_limit)}` : profile.can_approve ? ' · approves any amount' : ''}</div>
          </div>
          {!creating && (profile.can_open_calls || profile.is_org_admin) && <button className="primary big" onClick={() => setCreating(true)}>+ New service call</button>}
        </div>

        <ErrorBox error={err} />
        <Notice>{msg}</Notice>

        {creating && (
          <NewCallForm side="store" profile={profile} onCancel={() => setCreating(false)} onCreated={async (wo) => {
            setCreating(false); await load(); setOpen(wo.id);
          }} />
        )}

        {/* Approvals */}
        {pending.map((a) => (
          <div key={a.id} className="panel panel-pad spread" style={{ borderColor: '#e6b3ab', background: '#fffaf9' }}>
            <div className="stack" style={{ gap: 4 }}>
              <div className="row" style={{ gap: 8 }}>
                {a.owner_status === 'pending'
                  ? <span className="chip tone-amber">Waiting on owner</span>
                  : <span className="chip tone-red">Approval needed</span>}
                <strong>{a.work_orders ? poLabel(a.work_orders, a.seq) : ''} · Call #{a.work_orders?.number} · {a.work_orders?.sites?.name}{a.work_orders?.unit ? `, unit ${a.work_orders.unit}` : ''}</strong>
              </div>
              <div><span className="chip tone-slate">{PO_KIND[a.kind]}</span> {a.description}</div>
              <div className="small muted">{money(a.amount)} · requested {ago(a.requested_at)}{a.owner_status === 'pending' ? ` · you approved; ${a.owner?.name || 'the owner'} must OK it` : ''}</div>
            </div>
            <div className="row">
              <button onClick={() => setOpen(a.work_orders?.id)}>Details</button>
              {profile.can_approve && a.owner_status !== 'pending' && <>
                <button className="danger" disabled={busy} onClick={() => decide(a.id, false)}>Decline</button>
                <button className="primary" disabled={busy} onClick={() => decide(a.id, true)}>Approve {money(a.amount)}</button>
              </>}
            </div>
          </div>
        ))}

        {/* Late bills */}
        {late.length > 0 && (
          <div className="panel panel-pad" style={{ borderColor: '#e6b3ab' }}>
            <h3 style={{ color: 'var(--red-fg)' }}>Late bills</h3>
            {late.map((c) => (
              <div key={c.id} className="spread small click" style={{ padding: '6px 0', cursor: 'pointer' }} onClick={() => setOpen(c.id)}>
                <span>Call #{c.number} · {c.sites?.name} — completed {date(c.completed_at)}, invoice was due {date(c.invoice_due_at)}</span>
                <strong>about {money(c.total_cost)}</strong>
              </div>
            ))}
          </div>
        )}

        {/* Preventive maintenance: stays here until done */}
        {pms.length > 0 && (
          <div className="panel">
            <div className="spread" style={{ padding: '12px 16px 0' }}>
              <h3>Preventive maintenance</h3>
              <span className="small muted">Shown until completed</span>
            </div>
            <table>
              <tbody>
                {pms.map((p) => (
                  <tr key={p.work_order_id} className="click" onClick={() => setOpen(p.work_order_id)}>
                    <td><strong>#{p.number}</strong><div className="small muted">{p.site_name}</div></td>
                    <td>{p.issue_description}</td>
                    <td className="num">
                      {p.pm_state === 'overdue' ? <span className="chip tone-red">OVERDUE {p.days_overdue} days</span>
                        : p.pm_state === 'due' ? <span className="chip tone-amber">Due {date(p.due_on)}</span>
                        : <span className="chip tone-slate">Due {date(p.due_on)}</span>}
                      <div className="small muted">{p.status.replace('_', ' ')}</div>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}

        {/* Calls */}
        <div className="panel">
          <div className="tabs" style={{ padding: '0 8px', marginBottom: 0 }}>
            <button className={tab === 'open' ? 'on' : ''} onClick={() => setTab('open')}>Open calls ({counts.open})</button>
            <button className={tab === 'billing' ? 'on' : ''} onClick={() => setTab('billing')}>Completed — bill pending ({counts.billing})</button>
            <button className={tab === 'closed' ? 'on' : ''} onClick={() => setTab('closed')}>Invoiced</button>
          </div>
          <table>
            <thead>
              <tr><th>Call</th><th>Problem</th><th className="hide-sm">Technician</th><th>Status</th><th className="num">Cost</th></tr>
            </thead>
            <tbody>
              {shown.length === 0 && <tr><td colSpan={5} className="muted">Nothing here.</td></tr>}
              {shown.map((c) => {
                const v = latest(c);
                const parts = (c.parts_orders || []).filter((o) => ['needed', 'ordered'].includes(o.status));
                return (
                  <tr key={c.id} className="click" onClick={() => setOpen(c.id)}>
                    <td><strong>#{c.number}</strong><div className="small muted">{c.sites?.name}</div><div className="small muted">{dateTime(c.created_at)}</div></td>
                    <td><div className="row" style={{ gap: 6 }}><PriorityChip priority={c.priority} /><KindChip kind={c.kind} /></div>{c.issue_description}</td>
                    <td className="hide-sm">{v?.profiles?.full_name || <span className="muted">—</span>}</td>
                    <td>
                      <div className="stack" style={{ gap: 4 }}>
                        <StatusChip status={c.status} />
                        <LiveLine wo={c} visit={v} />
                        {c.status === 'waiting_parts' && parts.length > 0 && (
                          <span className="small muted">expected {parts.map((o) => (o.expected_on ? date(o.expected_on) : '—')).join(', ')}</span>
                        )}
                        <BillLine wo={c} />
                      </div>
                    </td>
                    <td className="num">{Number(c.total_cost) > 0 ? money(c.total_cost) : <span className="muted">—</span>}</td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      </main>

      {open && <CallDetail id={open} side="store" profile={profile} onClose={() => setOpen(null)} onChanged={load} />}
    </>
  );
}
