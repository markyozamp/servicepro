'use client';

import { useCallback, useEffect, useState } from 'react';
import { supabase, act, q } from '@/lib/supabase';
import { useProfile } from '@/lib/useProfile';
import { money, ago, dateTime, date, daysUntil, FLAG_LABEL } from '@/lib/format';
import TopBar from '@/components/TopBar';
import CallDetail from '@/components/CallDetail';
import NewCallForm from '@/components/NewCallForm';
import TeamPanel from '@/components/TeamPanel';
import { StatusChip, PriorityChip, KindChip, LiveLine, BillLine, ErrorBox } from '@/components/bits';
import AppFooter from '@/components/AppFooter';
import { useTabBadge } from '@/lib/tabBadge';
import CustomerPicker, { pickMatch } from '@/components/CustomerPicker';
import CustomerBook from '@/components/CustomerBook';
import CallRouting from '@/components/CallRouting';
import InvoiceNumbering from '@/components/InvoiceNumbering';
import PriceBook from '@/components/PriceBook';
import TechSchedule from '@/components/TechSchedule';
import Timesheets from '@/components/Timesheets';
import OfficeQuotes from '@/components/OfficeQuotes';
import AccountingExport from '@/components/AccountingExport';
import TaxReport from '@/components/TaxReport';
import TaxSetup from '@/components/TaxSetup';
import InvoicesPayments from '@/components/InvoicesPayments';
import Monitoring, { AlarmStrip } from '@/components/Monitoring';
import OfficeToday from '@/components/OfficeToday';
import ScrollRow from '@/components/ScrollRow';
import ContractorStart from '@/components/ContractorStart';

const LIST = `id, customer_id, site_id, number, kind, status, priority, issue_description, created_at, completed_at, invoice_due_at, invoiced_at, due_on,
  total_cost, invoice_ready, qbo_invoice_id, store_po_number, sites(name), customers(name),
  mode, source, accepted_at, accept_due_at, hold_until, hold_released_at, after_hours, declined_at, scheduled_start, store_confirmed_at, nte,
  visits(id, visit_no, status, eta_at, arrived_at, received_at, checkin_required, checkin_at, scheduled_start, scheduled_end, missed_alert_at, profiles(full_name)),
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
  const [logoOverride, setLogoOverride] = useState(undefined);
  const [book, setBook] = useState([]);
  const [cpick, setCpickRaw] = useState('');
  const setCpick = (v) => { setCpickRaw(v); try { localStorage.setItem('scp_cpick', v); } catch { /* fine */ } };
  useEffect(() => { try { setCpickRaw(localStorage.getItem('scp_cpick') || ''); } catch { /* fine */ } }, []);
  // Phone: open on "Today", show the board one column at a time, bottom tab bar.
  const [isPhone, setIsPhone] = useState(false);
  const [boardCol, setBoardCol] = useState('new');
  const [moreOpen, setMoreOpen] = useState(false);
  useEffect(() => {
    const mq = window.matchMedia('(max-width: 760px)');
    setIsPhone(mq.matches);
    if (mq.matches) setTab('today');
    const on = (e) => setIsPhone(e.matches);
    mq.addEventListener?.('change', on);
    return () => mq.removeEventListener?.('change', on);
  }, []);
  const go = (t, cust) => { setTab(t); if (cust) setCpick(`c:${cust}`); setMoreOpen(false); window.scrollTo({ top: 0 }); };

  const load = useCallback(async () => {
    try {
      const [c, f, t, b] = await Promise.all([
        q(supabase.from('work_orders').select(LIST).order('priority').order('created_at', { ascending: false }).limit(400)),
        q(supabase.from('guardrail_flags').select('id, work_order_id, flag, description, blocking, triggered_at, work_orders(number, total_cost, customer_id, site_id, sites(name))')
          .is('resolved_at', null).order('triggered_at', { ascending: false })),
        q(supabase.from('profiles').select('id, full_name, phone').eq('is_technician', true).eq('active', true).order('full_name')),
        act('contractor_book', {}),
      ]);
      setCalls(c); setFlags(f); setTechs(t); setBook(b || []);
    } catch (e) {
      setErr(e.message);
    }
  }, []);

  // Opened from an alert: show that call
  useEffect(() => {
    if (!profile) return;
    const c = new URLSearchParams(window.location.search).get('call');
    if (c) setOpen(c);
  }, [profile]);

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

  // Browser tab: everything that needs attention across all customers; flashes when a new call must be accepted.
  const toAccept = calls.filter((w) => w.status === 'created' && w.mode === 'verify' && !w.accepted_at && !w.declined_at);
  const issueCount = book.reduce((n, c) => n + c.sites.reduce((m, st) => m + st.reasons.length, 0), 0);
  useTabBadge(org?.name, issueCount, toAccept.length ? 'New call: accept now' : null);
  // A saved customer/store choice that no longer exists falls back to all customers.
  const validPick = cpick && book.some((c) => cpick === `c:${c.customer_id}` || c.sites.some((st) => cpick === `s:${st.site_id}`)) ? cpick : '';
  const hotCustomers = book.filter((c) => c.sites.some((st) => st.reasons.length)).length;

  if (!profile) return <div className="page muted">Loading…</div>;
  const logo = logoOverride !== undefined ? logoOverride : org?.logo_data;

  const callsF = calls.filter((w) => pickMatch(validPick, w.customer_id, w.site_id));
  const flagsF = flags.filter((f) => pickMatch(validPick, f.work_orders?.customer_id, f.work_orders?.site_id));
  const blockingByWo = flags.reduce((m, f) => (f.blocking ? { ...m, [f.work_order_id]: (m[f.work_order_id] || 0) + 1 } : m), {});
  const reviewFlags = flagsF.filter((f) => f.blocking);
  const pms = callsF.filter((c) => c.kind === 'pm' && !['completed', 'invoiced', 'cancelled'].includes(c.status));
  const overduePm = pms.filter((p) => p.due_on && daysUntil(p.due_on) < 0).length;
  const toBill = callsF.filter((c) => c.status === 'completed').sort((a, b) => new Date(a.invoice_due_at) - new Date(b.invoice_due_at));
  const lateBills = toBill.filter((c) => daysUntil(c.invoice_due_at) < 0).length;
  const toAcceptF = callsF.filter((w) => w.status === 'created' && w.mode === 'verify' && !w.accepted_at && !w.declined_at);
  const todayCount = toAcceptF.length + callsF.filter((w) => w.status === 'created' && w.mode === 'verify' && w.accepted_at && !w.declined_at && !latest(w)).length
    + callsF.filter((w) => w.status === 'completed' && daysUntil(w.invoice_due_at) < 0).length + reviewFlags.length
    + callsF.filter((w) => !['completed', 'invoiced', 'cancelled'].includes(w.status) && (w.visits || []).some((v) => v.status === 'assigned' && v.missed_alert_at)).length;
  const history = callsF.filter((c) => ['invoiced', 'cancelled'].includes(c.status));

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
      <main className="page has-bottomnav">
        <div className="spread" style={{ marginBottom: 12 }}>
          <div>
            {logo ? <img className="org-logo" src={logo} alt={org?.name || 'Company logo'} /> : <h1>{org?.name || 'Dispatch'}</h1>}
            <div style={{ margin: '6px 0 2px' }}><CustomerPicker book={book} value={validPick} onChange={setCpick} /></div>
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

        {!creating && <ContractorStart me={profile} org={org} book={book} onGo={go} />}

        <div className="desk-only">
        <ScrollRow className="tabs" style={{ marginBottom: 16 }}>
          <button className={tab === 'today' ? 'on' : ''} onClick={() => setTab('today')}>Today{todayCount > 0 && <span className="count">{todayCount}</span>}</button>
          <button className={tab === 'board' ? 'on' : ''} onClick={() => setTab('board')}>Dispatch board</button>
          {(org?.level || 'verify') !== 'verify' && <button className={tab === 'schedule' ? 'on' : ''} onClick={() => setTab('schedule')}>Schedule</button>}
          {(org?.level || 'verify') !== 'verify' && <button className={tab === 'time' ? 'on' : ''} onClick={() => setTab('time')}>Timesheets</button>}
          <button className={tab === 'customers' ? 'on' : ''} onClick={() => setTab('customers')}>
            Customers{hotCustomers > 0 && <span className="count">{hotCustomers}</span>}
          </button>
          <button className={tab === 'pm' ? 'on' : ''} onClick={() => setTab('pm')}>
            PM{pms.length > 0 && <span className="count" style={{ background: overduePm ? 'var(--red-fg)' : 'var(--ink-3)' }}>{pms.length}</span>}
          </button>
          <button className={tab === 'billing' ? 'on' : ''} onClick={() => setTab('billing')}>
            {(org?.level || 'verify') !== 'verify' ? 'Invoices & Payments' : 'Billing'}{toBill.length > 0 && <span className="count" style={{ background: lateBills ? 'var(--red-fg)' : 'var(--ink-3)' }}>{toBill.length}</span>}
          </button>
          <button className={tab === 'review' ? 'on' : ''} onClick={() => setTab('review')}>
            Review queue{reviewFlags.length > 0 && <span className="count">{reviewFlags.length}</span>}
          </button>
          <button className={tab === 'history' ? 'on' : ''} onClick={() => setTab('history')}>Invoiced & cancelled</button>
          <button className={tab === 'quotes' ? 'on' : ''} onClick={() => setTab('quotes')}>Quotes</button>
          <button className={tab === 'monitor' ? 'on' : ''} onClick={() => setTab('monitor')}>Temperatures</button>
          <button className={tab === 'team' ? 'on' : ''} onClick={() => setTab('team')}>Team</button>
        </ScrollRow>
        </div>

        {tab === 'today' && <OfficeToday calls={callsF} flags={flagsF} onOpen={setOpen} />}
        {tab === 'schedule' && <TechSchedule onOpenCall={setOpen} refreshKey={open} />}
        {tab === 'time' && <Timesheets profile={profile} />}
        {tab !== 'monitor' && <AlarmStrip onOpen={() => setTab('monitor')} />}
        {tab === 'monitor' && <Monitoring sites={(book || []).flatMap((c) => c.sites.map((x) => ({ id: x.site_id, name: `${c.name} · ${x.name}` })))} onOpenCall={setOpen} />}
        {tab === 'quotes' && <OfficeQuotes book={book} base={(org?.level || 'verify') !== 'verify'} onOpenCall={setOpen} />}

        {tab === 'board' && isPhone && (
          <ScrollRow className="colchips">
            {COLUMNS.map((col) => {
              const n = callsF.filter(col.match).length;
              const hot = col.key === 'new' && toAcceptF.length > 0;
              return <button key={col.key} type="button" className={boardCol === col.key ? 'on' : ''} onClick={() => setBoardCol(col.key)}>{col.title}<span className={`n${hot ? ' hot' : ''}`}>{n}</span></button>;
            })}
          </ScrollRow>
        )}
        {tab === 'board' && (
          <div className={`board${isPhone ? ' one' : ''}`}>
            {COLUMNS.filter((col) => !isPhone || col.key === boardCol).map((col) => {
              const items = callsF.filter(col.match);
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
                        {w.mode === 'verify' && (
                          <div className="row" style={{ gap: 4 }}>
                            <span className="chip tone-blue">PO {w.store_po_number || `PO${w.number}`}</span>
                            {w.status === 'created' && !w.accepted_at && !w.declined_at && w.accept_due_at && (
                              <span className={`chip ${new Date(w.accept_due_at) < new Date() ? 'tone-red' : 'tone-amber'}`}>Accept by {dateTime(w.accept_due_at)}</span>)}
                            {w.status === 'created' && w.accepted_at && <span className="chip tone-green">{w.scheduled_start ? `Scheduled ${dateTime(w.scheduled_start)}` : 'Accepted'}</span>}
                            {w.declined_at && <span className="chip tone-slate">Declined</span>}
                            {w.source === 'contractor' && !w.store_confirmed_at && <span className="chip tone-amber">Customer hasn't confirmed</span>}
                            {w.hold_until && !w.hold_released_at && <span className="chip tone-slate">Held until {dateTime(w.hold_until)} (customer chose to wait)</span>}
                            {w.after_hours && <span className="chip tone-slate">After hours</span>}
                          </div>
                        )}
                        {v && <div className="small">🔧 {v.profiles?.full_name}{v.visit_no > 1 ? ` · visit ${v.visit_no}` : ''}</div>}
                        <LiveLine wo={w} visit={v} />
                        {waitingApproval && <span className="chip tone-red" style={{ alignSelf: 'flex-start' }}>Waiting on customer approval</span>}
                        {col.key === 'parts' && parts.length > 0 && (
                          <div className="small muted">{parts.map((o) => `${o.description}${o.expected_on ? ` (exp. ${date(o.expected_on)})` : ''}`).join(', ')}</div>
                        )}
                        {['site', 'done'].includes(col.key) && w.mode !== 'verify' && <div className="small">{money(w.total_cost)}</div>}
                        {col.key === 'done' && w.mode === 'verify' && <span className="chip tone-amber" style={{ alignSelf: 'flex-start' }}>Enter your invoice</span>}
                        {col.key === 'done' && <BillLine wo={w} />}
                        {blockingByWo[w.id] > 0 && <span className="chip tone-red" style={{ alignSelf: 'flex-start' }}>{blockingByWo[w.id]} to review</span>}
                        {w.mode === 'verify' && v && v.status === 'assigned' && v.scheduled_start && (
                          <div className="small">📅 {dateTime(v.scheduled_start)}{v.missed_alert_at ? <span className="chip tone-red" style={{ marginLeft: 4 }}>missed</span> : ''}</div>)}
                        {w.mode === 'verify' && !['on_site', 'completed', 'invoiced', 'cancelled'].includes(w.status) && !(v && ['assigned', 'en_route'].includes(v.status)) && !w.declined_at && (
                          <button className="primary" onClick={(e) => { e.stopPropagation(); setOpen(w.id); }}>Schedule a trip</button>)}
                        {w.mode !== 'verify' && (col.key === 'new' || (col.key === 'parts' && w.status === 'return_needed')) && assignBox(w)}
                        {col.key === 'new' && <div className="small muted">opened {ago(w.created_at)}</div>}
                      </article>
                    );
                  })}
                </section>
              );
            })}
          </div>
        )}

        {tab === 'team' && <><CallRouting profile={profile} logo={logo} onLogo={setLogoOverride} />{(org?.level || 'verify') !== 'verify' && <><InvoiceNumbering profile={profile} /><TaxSetup profile={profile} /><PriceBook profile={profile} /></>}<TeamPanel profile={profile} /></>}

        {tab === 'customers' && <CustomerBook book={book} pick={validPick} onPick={setCpick} onOpenCall={setOpen} admin={!!profile.is_org_admin} onChanged={load} contractorId={profile.contractor_id} canRates={!!(profile.is_org_admin || profile.can_dispatch)} base={(org?.level || 'verify') !== 'verify'} canAdd={!!(profile.is_org_admin || profile.can_dispatch)} />}

        {tab === 'pm' && (
          <div className="panel tablewrap">
            <table>
              <thead><tr><th>PM</th><th className="hide-sm">Location</th><th>Due</th><th>Technician</th><th className="hide-sm"></th></tr></thead>
              <tbody>
                {pms.length === 0 && <tr><td colSpan={5} className="muted">No open PM visits. They're created automatically 14 days before they're due.</td></tr>}
                {pms.sort((a, b) => (a.due_on > b.due_on ? 1 : -1)).map((p) => {
                  const v = latest(p); const d = daysUntil(p.due_on);
                  return (
                    <tr key={p.id} className="click" onClick={() => setOpen(p.id)}>
                      <td><strong>#{p.number}</strong><div className="small">{p.issue_description}</div><div className="small muted phone-show">{p.customers?.name} · {p.sites?.name}</div></td>
                      <td className="hide-sm">{p.customers?.name}<div className="small muted">{p.sites?.name}</div></td>
                      <td>{d < 0 ? <span className="chip tone-red">OVERDUE {-d} days</span> : <span className={`chip ${d <= 7 ? 'tone-amber' : 'tone-slate'}`}>{date(p.due_on)}</span>}</td>
                      <td>{v ? v.profiles?.full_name : assignBox(p)}</td>
                      <td className="hide-sm"><StatusChip status={p.status} /></td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}

        {tab === 'billing' && ((org?.level || 'verify') !== 'verify' ? (
          <InvoicesPayments onOpenCall={setOpen} toBillCount={toBill.length}
            extras={(profile.is_org_admin || profile.can_bill) ? <><AccountingExport /><TaxReport /></> : null}
            toBill={(
          <div className="panel tablewrap">
            <table>
              <thead><tr><th>Call</th><th className="hide-sm">Customer</th><th>Invoice due</th><th className="hide-sm">Ready?</th><th className="num hide-sm">Total</th></tr></thead>
              <tbody>
                {toBill.length === 0 && <tr><td colSpan={5} className="muted">Nothing waiting to be invoiced.</td></tr>}
                {toBill.map((w) => {
                  const d = daysUntil(w.invoice_due_at);
                  return (
                    <tr key={w.id} className="click" onClick={() => setOpen(w.id)}>
                      <td><strong>#{w.number}</strong><div className="small muted">completed {date(w.completed_at)}</div><div className="small muted phone-show">{w.customers?.name} · {w.sites?.name}</div></td>
                      <td className="hide-sm">{w.customers?.name}<div className="small muted">{w.sites?.name}</div></td>
                      <td>{d < 0 ? <span className="chip tone-red">LATE {-d} days — customer notified</span>
                        : <span className={`chip ${d <= 2 ? 'tone-amber' : 'tone-slate'}`}>{date(w.invoice_due_at)} ({d} days)</span>}</td>
                      <td className="hide-sm">{w.mode === 'verify' ? <span className="chip tone-amber">Enter invoice (Time Verify)</span>
                        : w.invoice_ready ? <span className="chip tone-green">Ready</span> : <span className="chip tone-red">{blockingByWo[w.id] || 0} to review</span>}</td>
                      <td className="num hide-sm">{w.mode === 'verify' ? '—' : money(w.total_cost)}</td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
            )} />
        ) : (
          <div className="panel tablewrap">
            <table>
              <thead><tr><th>Call</th><th className="hide-sm">Customer</th><th>Invoice due</th><th className="hide-sm">Ready?</th><th className="num hide-sm">Total</th></tr></thead>
              <tbody>
                {toBill.length === 0 && <tr><td colSpan={5} className="muted">Nothing waiting to be invoiced.</td></tr>}
                {toBill.map((w) => {
                  const d = daysUntil(w.invoice_due_at);
                  return (
                    <tr key={w.id} className="click" onClick={() => setOpen(w.id)}>
                      <td><strong>#{w.number}</strong><div className="small muted">completed {date(w.completed_at)}</div><div className="small muted phone-show">{w.customers?.name} · {w.sites?.name}</div></td>
                      <td className="hide-sm">{w.customers?.name}<div className="small muted">{w.sites?.name}</div></td>
                      <td>{d < 0 ? <span className="chip tone-red">LATE {-d} days — customer notified</span>
                        : <span className={`chip ${d <= 2 ? 'tone-amber' : 'tone-slate'}`}>{date(w.invoice_due_at)} ({d} days)</span>}</td>
                      <td className="hide-sm">{w.mode === 'verify' ? <span className="chip tone-amber">Enter invoice (Time Verify)</span>
                        : w.invoice_ready ? <span className="chip tone-green">Ready</span> : <span className="chip tone-red">{blockingByWo[w.id] || 0} to review</span>}</td>
                      <td className="num hide-sm">{w.mode === 'verify' ? '—' : money(w.total_cost)}</td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        ))}

        {tab === 'review' && (
          <div className="panel tablewrap">
            <table>
              <thead><tr><th>Call</th><th>Issue found</th><th className="num hide-sm">Total</th><th className="hide-sm"></th></tr></thead>
              <tbody>
                {reviewFlags.length === 0 && <tr><td colSpan={4} className="muted">Nothing to review.</td></tr>}
                {reviewFlags.map((f) => (
                  <tr key={f.id} className="click" onClick={() => setOpen(f.work_order_id)}>
                    <td><strong>#{f.work_orders?.number}</strong><div className="small muted">{f.work_orders?.sites?.name}</div></td>
                    <td><span className="chip tone-red">{FLAG_LABEL[f.flag] || f.flag}</span><div className="small" style={{ marginTop: 4 }}>{f.description}</div><div className="small muted">{ago(f.triggered_at)}</div></td>
                    <td className="num hide-sm">{money(f.work_orders?.total_cost)}</td>
                    <td className="num hide-sm"><button>Review</button></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}

        {tab === 'history' && (
          <div className="panel tablewrap">
            <table>
              <thead><tr><th>Call</th><th className="hide-sm">Customer</th><th>Status</th><th className="hide-sm">Invoice</th><th className="num">Total</th></tr></thead>
              <tbody>
                {history.length === 0 && <tr><td colSpan={5} className="muted">No invoiced or cancelled calls yet.</td></tr>}
                {history.map((w) => (
                  <tr key={w.id} className="click" onClick={() => setOpen(w.id)}>
                    <td><strong>#{w.number}</strong><div className="small muted">{dateTime(w.created_at)}</div><div className="small muted phone-show">{w.customers?.name} · {w.sites?.name}</div></td>
                    <td className="hide-sm">{w.customers?.name}<div className="small muted">{w.sites?.name}</div></td>
                    <td><StatusChip status={w.status} /></td>
                    <td className="hide-sm">{w.qbo_invoice_id || '—'}{w.invoiced_at && w.invoice_due_at && new Date(w.invoiced_at) > new Date(w.invoice_due_at) ? <span className="chip tone-red" style={{ marginLeft: 6 }}>late</span> : null}</td>
                    <td className="num">{money(w.total_cost)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </main>
      <AppFooter kind="office" />

      {/* Phone: bottom tab bar */}
      {moreOpen && <div className="scrim phone-only" onClick={() => setMoreOpen(false)} style={{ zIndex: 39 }} />}
      {moreOpen && (
        <div className="moresheet phone-only" role="menu">
          <button role="menuitem" onClick={() => go('pm')}><span>Preventive maintenance</span>{pms.length > 0 && <span className="count" style={{ background: overduePm ? 'var(--red-fg)' : 'var(--ink-3)' }}>{pms.length}</span>}</button>
          <button role="menuitem" onClick={() => go('review')}><span>Review queue</span>{reviewFlags.length > 0 && <span className="count">{reviewFlags.length}</span>}</button>
          <button role="menuitem" onClick={() => go('history')}><span>Invoiced &amp; cancelled</span></button>
          <button role="menuitem" onClick={() => go('team')}><span>Team &amp; who gets the calls</span></button>
        </div>
      )}
      {!open && !creating && <nav className="bottomnav" aria-label="Sections">
        <button className={tab === 'today' ? 'on' : ''} onClick={() => go('today')}><span className="ic">⚡</span>Today{todayCount > 0 && <span className="badge">{todayCount}</span>}</button>
        <button className={tab === 'board' ? 'on' : ''} onClick={() => go('board')}><span className="ic">▦</span>Board</button>
        <button className={tab === 'customers' ? 'on' : ''} onClick={() => go('customers')}><span className="ic">🏪</span>Customers{hotCustomers > 0 && <span className="badge">{hotCustomers}</span>}</button>
        <button className={tab === 'billing' ? 'on' : ''} onClick={() => go('billing')}><span className="ic">$</span>{(org?.level || 'verify') !== 'verify' ? 'Invoices' : 'Billing'}{lateBills > 0 && <span className="badge">{lateBills}</span>}</button>
        <button className={['pm', 'review', 'history', 'team'].includes(tab) || moreOpen ? 'on' : ''} onClick={() => setMoreOpen(!moreOpen)}><span className="ic">☰</span>More{reviewFlags.length + overduePm > 0 && <span className="badge">{reviewFlags.length + overduePm}</span>}</button>
      </nav>}

      {open && <CallDetail id={open} side="office" profile={profile} techs={techs} onClose={() => setOpen(null)} onChanged={load} />}
    </>
  );
}
