'use client';

import { useCallback, useEffect, useState } from 'react';
import { supabase, act, q } from '@/lib/supabase';
import { useProfile } from '@/lib/useProfile';
import { money, ago, dateTime, date, poLabel, PO_KIND } from '@/lib/format';
import TopBar from '@/components/TopBar';
import CallDetail from '@/components/CallDetail';
import NewCallForm from '@/components/NewCallForm';
import StoreSettings, { SETTINGS_TABS, storePerms } from '@/components/StoreSettings';
import Info from '@/components/Info';
import PoLog from '@/components/PoLog';
import Presence from '@/components/Presence';
import { StatusChip, PriorityChip, KindChip, LiveLine, BillLine, ErrorBox, Notice } from '@/components/bits';

const LIST = `id, number, kind, status, priority, issue_description, created_at, completed_at, invoice_due_at, total_cost, store_po_number,
  mode, source, store_confirmed_at, store_disputed, accepted_at, accept_due_at, declined_at, nte, contact_name, contractors(name),
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
  const [door, setDoor] = useState([]);       // technicians on site waiting for the check-in code
  const [sound, setSound] = useState(false);
  const [settings, setSettings] = useState(null);   // which Settings tab is open, or null
  const [project, setProject] = useState(false);

  const load = useCallback(async () => {
    try {
      const [c, p, pm, st, dv, codes] = await Promise.all([
        q(supabase.from('work_orders').select(LIST).order('created_at', { ascending: false }).limit(300)),
        q(supabase.from('po_lines').select('id, seq, kind, amount, description, requested_at, owner_status, owner:property_owners(name), work_orders(id, number, store_po_number, unit, sites(name))').eq('status', 'pending')),
        q(supabase.from('pm_status').select('*').order('due_on')),
        q(supabase.from('sites').select('id, name')),
        q(supabase.from('visits').select('id, arrived_at, profiles(full_name), work_orders(id, number, unit, sites(name))')
          .eq('status', 'on_site').eq('checkin_required', true).is('checkin_at', null)),
        q(supabase.from('visit_codes').select('visit_id, code')),
      ]);
      setDoor(dv.map((v) => ({ ...v, code: codes.find((x) => x.visit_id === v.id)?.code })));
      const siteName = Object.fromEntries(st.map((x) => [x.id, x.name]));
      setCalls(c); setPending(p); setPms(pm.map((x) => ({ ...x, site_name: siteName[x.site_id] })));
    } catch (e) {
      setErr(e.message);
    }
  }, []);

  // Opened from an alert: show that call
  useEffect(() => {
    if (!profile) return;
    const sp = new URLSearchParams(window.location.search);
    const c = sp.get('call');
    if (c) setOpen(c);
    if (sp.get('settings')) setSettings(sp.get('settings'));
    if (sp.get('welcome') && profile.is_org_admin) setSettings('locations');
  }, [profile]);

  useEffect(() => {
    if (!profile) return;
    load();
    const t = setInterval(load, 15000);
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

  // Alarm while a technician waits at the door: beep every refresh, and a phone/computer notification.
  useEffect(() => {
    if (!door.length) return;
    if (sound) beep();
    if (typeof Notification !== 'undefined' && Notification.permission === 'granted') {
      for (const v of door) {
        const mins = Math.floor((Date.now() - new Date(v.arrived_at).getTime()) / 60000);
        const key = `sp_door_${v.id}_${mins >= 5 ? 5 : 0}`;
        if (sessionStorage.getItem(key)) continue;
        sessionStorage.setItem(key, '1');
        new Notification(mins >= 5 ? `STILL WAITING ${mins} min — check-in code ${v.code}` : `Technician at the door — code ${v.code}`,
          { body: `${v.profiles?.full_name} is at ${v.work_orders?.sites?.name} for call #${v.work_orders?.number}. Labor time is running.`, requireInteraction: true });
      }
    }
  }, [door, sound]);

  function enableAlerts() {
    setSound(true); beep();
    if (typeof Notification !== 'undefined' && Notification.permission === 'default') Notification.requestPermission();
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
          <div className="row">
            {[...SETTINGS_TABS.slice(1), SETTINGS_TABS[0]].filter(([k]) => storePerms(profile)[k]).map(([k, label]) => (
              <button key={k} className={settings === k ? 'on' : ''} onClick={() => setSettings(settings === k ? null : k)}>{label}</button>
            ))}
            {(profile.can_open_calls || profile.is_org_admin) && !project && <button onClick={() => setProject(true)}>Install / project quote</button>}
            {!creating && (profile.can_open_calls || profile.is_org_admin) && <button className="primary big" onClick={() => setCreating(true)}>+ New service call</button>}
          </div>
        </div>

        <ErrorBox error={err} />
        <Notice>{msg}</Notice>

        {/* Technician waiting at the door for the check-in code */}
        {door.map((v) => {
          const mins = Math.floor((Date.now() - new Date(v.arrived_at).getTime()) / 60000);
          return (
            <div key={v.id} className="doorbell">
              <div className="stack" style={{ gap: 4 }}>
                <strong style={{ fontSize: 18 }}>Technician at the door — waiting {mins < 1 ? 'less than a minute' : `${mins} min`}</strong>
                <span>{v.profiles?.full_name} is at {v.work_orders?.sites?.name}{v.work_orders?.unit ? `, unit ${v.work_orders.unit}` : ''} for call #{v.work_orders?.number}. <strong>Labor time is running</strong> — please meet them and give this code.</span>
              </div>
              <div className="doorcode">{v.code || '—'}</div>
            </div>
          );
        })}
        <Presence onOpen={setOpen} refreshKey={calls} />
        {door.length > 0 && !sound && <button className="danger" onClick={enableAlerts}>🔔 Turn on sound and pop-up alerts for this screen</button>}

        {settings && <StoreSettings key={org?.id || 'org'} tab={settings} setTab={setSettings} onClose={() => setSettings(null)} me={profile} org={org} />}
        {project && (
          <div className="panel panel-pad stack">
            <div className="spread"><h2>Install or project quote <span className="soon">Coming soon</span> <Info title="Installs and projects">For bigger work: a new condensing unit, a walk-in freezer, a remodel. You describe the job, pick one or more contractors to quote it, and they send their quotes back on their own letterhead with photos. You compare, approve one, and it runs like any other call: scheduled, verified on arrival, the new equipment added to your list with its warranty.</Info></h2><button onClick={() => setProject(false)}>Close</button></div>
            <div className="muted">Coming soon. Here's how it will work:</div>
            <ol className="stack" style={{ gap: 4, margin: 0, paddingLeft: 20 }}>
              <li>Describe the job and the location, add photos.</li>
              <li>Pick the contractors you want quotes from (one, or several to compare).</li>
              <li>They send quotes back here, on their letterhead.</li>
              <li>Compare side by side and approve one; it becomes a PO.</li>
              <li>The install runs like any call: scheduled, checked in, verified. The new equipment and its warranty are added to your list.</li>
            </ol>
            <div className="small muted">Until then: open a regular service call and write "Quote for new …" in the description.</div>
          </div>
        )}

        {/* Calls a contractor entered from a phone call — confirm your store asked for them */}
        {calls.filter((c) => c.source === 'contractor' && c.mode === 'verify' && !c.store_confirmed_at && !['cancelled'].includes(c.status)).map((c) => (
          <div key={c.id} className="panel panel-pad spread" style={{ borderColor: '#e6c98a', background: '#fffcf3' }}>
            <div className="stack" style={{ gap: 4 }}>
              <div className="row" style={{ gap: 8 }}><span className="chip tone-amber">{c.store_disputed ? 'You questioned this' : 'Please confirm'}</span>
                <strong>Call #{c.number} · {c.sites?.name}</strong></div>
              <div>{c.contractors?.name} entered this from a phone call{c.contact_name ? ` — requested by ${c.contact_name}` : ''}: {c.issue_description}</div>
            </div>
            <button onClick={() => setOpen(c.id)}>Review</button>
          </div>
        ))}

        {/* Time Verify calls not accepted in time */}
        {calls.filter((c) => c.mode === 'verify' && c.status === 'created' && ((!c.accepted_at && c.accept_due_at && new Date(c.accept_due_at) < new Date()) || c.declined_at)).map((c) => (
          <div key={c.id} className="panel panel-pad spread" style={{ borderColor: '#e6b3ab', background: '#fffaf9' }}>
            <div><span className="chip tone-red">{c.declined_at ? 'Declined' : 'Not accepted'}</span> <strong>Call #{c.number} · {c.sites?.name}</strong> — {c.contractors?.name} {c.declined_at ? "can't take it" : 'has not accepted it yet'}.</div>
            <button onClick={() => setOpen(c.id)}>What to do</button>
          </div>
        ))}

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
              <div className="small muted">Not to exceed {money(a.amount)} · requested {ago(a.requested_at)}{a.owner_status === 'pending' ? ` · you approved; ${a.owner?.name || 'the owner'} must OK it` : ''}</div>
            </div>
            <div className="row">
              <button onClick={() => setOpen(a.work_orders?.id)}>Details</button>
              {profile.can_approve && a.owner_status !== 'pending' && <>
                <button className="danger" disabled={busy} onClick={() => decide(a.id, false)}>Decline</button>
                <button className="primary" disabled={busy} onClick={() => decide(a.id, true)}>Approve up to {money(a.amount)}</button>
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
                <strong>{c.mode === 'verify' ? 'invoice not entered' : `about ${money(c.total_cost)}`}</strong>
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
            <button className={tab === 'po' ? 'on' : ''} onClick={() => setTab('po')}>PO log</button>
          </div>
          {tab === 'po' ? <PoLog /> : (
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
                    <td><strong>#{c.number}</strong><div className="small">{c.store_po_number || `PO${c.number}`}</div><div className="small muted">{c.sites?.name}</div><div className="small muted">{dateTime(c.created_at)}</div></td>
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
                    <td className="num">{c.mode === 'verify' ? (c.nte != null ? <span className="small muted">limit {money(c.nte)}</span> : <span className="muted">—</span>)
                      : Number(c.total_cost) > 0 ? money(c.total_cost) : <span className="muted">—</span>}</td>
                  </tr>
                );
              })}
            </tbody>
          </table>
          )}
        </div>
      </main>

      {open && <CallDetail id={open} side="store" profile={profile} onClose={() => setOpen(null)} onChanged={load} />}
    </>
  );
}

function beep() {
  try {
    const C = window.AudioContext || window.webkitAudioContext; if (!C) return;
    const a = new C(); const o = a.createOscillator(); const g = a.createGain();
    o.type = 'square'; o.frequency.value = 880; g.gain.value = 0.15; o.connect(g); g.connect(a.destination);
    o.start(); setTimeout(() => { o.frequency.value = 660; }, 250); setTimeout(() => { o.stop(); a.close(); }, 600);
  } catch { /* no sound available */ }
}
