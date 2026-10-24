'use client';

import TripPick, { OFFER_SELECT } from '@/components/TripPick';
import { usePlace } from '@/lib/terms';
import { FollowThroughReport } from '@/components/FollowThrough';
import { useCallback, useEffect, useRef, useState } from 'react';
import { supabase, act, q } from '@/lib/supabase';
import { useProfile, isDemoEmail } from '@/lib/useProfile';
import PmPlans from '@/components/PmPlans';
import { money, ago, dateTime, date, poLabel, PO_KIND, FLAG_LABEL } from '@/lib/format';
import TopBar from '@/components/TopBar';
import CallDetail from '@/components/CallDetail';
import NewCallForm from '@/components/NewCallForm';
import StoreSettings, { SETTINGS_TABS, storePerms, tabLabel } from '@/components/StoreSettings';
import AppFooter from '@/components/AppFooter';
import GettingStarted from '@/components/GettingStarted';
import LocationPicker from '@/components/LocationPicker';
import { useTabBadge } from '@/lib/tabBadge';
import PoLog from '@/components/PoLog';
import ScrollRow from '@/components/ScrollRow';
import Presence from '@/components/Presence';
import WaitingOnYou from '@/components/WaitingOnYou';
import StoreQuotes from '@/components/StoreQuotes';
import Monitoring, { AlarmStrip } from '@/components/Monitoring';
import { StatusChip, PriorityChip, KindChip, LiveLine, BillLine, ErrorBox, Notice } from '@/components/bits';

const LIST = `id, site_id, number, kind, status, priority, issue_description, created_at, completed_at, invoice_due_at, total_cost, store_po_number,
  mode, source, store_confirmed_at, store_disputed, accepted_at, accept_due_at, declined_at, nte, contact_name, bill_requested_at, contractors(name),
  sites(name), visits(id, visit_no, status, eta_at, arrived_at, received_at, checkin_required, checkin_at, profiles(full_name)),
  parts_orders(status, expected_on)`;

const ICONS = { locations: '📍', team: '👥', equipment: '🧰', contractors: '🔧', company: '⚙️' };

const latest = (w) => (w.visits || []).filter((v) => v.status !== 'cancelled').sort((a, b) => b.visit_no - a.visit_no)[0];

export default function StorePortal() {
  const place = usePlace();
  const { profile, org } = useProfile('/store');
  const [calls, setCalls] = useState([]);
  const [pending, setPending] = useState([]);
  const [pms, setPms] = useState([]);
  const [showPlans, setShowPlans] = useState(false);
  const [flags, setFlags] = useState([]);
  const [tab, setTab] = useState('open');
  const [open, setOpen] = useState(null);
  const [ft, setFt] = useState(false);
  const [creating, setCreating] = useState(false);
  const [err, setErr] = useState('');
  const [msg, setMsg] = useState('');
  const [busy, setBusy] = useState(false);
  const [door, setDoor] = useState([]);       // technicians on site waiting for the check-in code
  const [crewAsk, setCrewAsk] = useState([]); // crews on site the store hasn't confirmed yet
  const [offers, setOffers] = useState([]);   // return trips waiting for the store to pick a time
  const [sound, setSound] = useState(false);
  const [settings, setSettings] = useState(null);   // which Settings tab is open, or null
  const [project, setProject] = useState(false);
  const [monitor, setMonitor] = useState(false);
  const [locked, setLocked] = useState(false);
  const [logoOverride, setLogoOverride] = useState(undefined);
  const [admins, setAdmins] = useState([]);
  const panelRef = useRef(null);
  const workRef = useRef(null);
  const callRef = useRef(null);
  const [siteF, setSiteF] = useState('');
  const [allSites, setAllSites] = useState([]);
  const [attention, setAttention] = useState([]);
  const [addLoc, setAddLoc] = useState(false);

  const load = useCallback(async () => {
    try {
      const [c, p, pm, st, dv, codes, cw, of] = await Promise.all([
        q(supabase.from('work_orders').select(LIST).order('created_at', { ascending: false }).limit(300)),
        q(supabase.from('po_lines').select('id, seq, kind, amount, description, requested_at, owner_status, owner:property_owners(name), work_orders(id, site_id, number, store_po_number, unit, sites(name))').eq('status', 'pending')),
        q(supabase.from('pm_status').select('*').order('due_on')),
        q(supabase.from('sites').select('id, name')),
        q(supabase.from('visits').select('id, arrived_at, profiles(full_name), work_orders(id, site_id, number, unit, sites(name))')
          .eq('status', 'on_site').eq('checkin_required', true).is('checkin_at', null)),
        q(supabase.from('visit_codes').select('visit_id, code')),
        q(supabase.from('visits').select('id, crew_helpers, crew_names, profiles(full_name), work_orders(id, site_id, number, sites(name))')
          .eq('status', 'on_site').not('crew_set_at', 'is', null).is('crew_confirmed', null).gt('crew_helpers', 0)).catch(() => []),
        q(supabase.from('trip_offers').select(`${OFFER_SELECT}, work_orders(id, number, site_id, sites(name), contractors(name))`).eq('status', 'pending').order('created_at')).catch(() => []),
      ]);
      setCrewAsk(cw || []); setOffers(of || []);
      setDoor(dv.map((v) => ({ ...v, code: codes.find((x) => x.visit_id === v.id)?.code })));
      const siteName = Object.fromEntries(st.map((x) => [x.id, x.name]));
      const [att, ss] = await Promise.all([act('site_attention', {}).catch(() => []), q(supabase.from('sites').select('id, name').order('name')).catch(() => [])]);
      setAttention(att || []); setAllSites(ss || []);
      const fl = await q(supabase.from('guardrail_flags').select('id, flag, description, work_order_id, work_orders(number, site_id, sites(name))')
        .is('resolved_at', null).is('store_ack_at', null).eq('visible_to_customer', true).neq('flag', 'billing_late').order('triggered_at', { ascending: false })).catch(() => []);
      setFlags(fl || []);
      setCalls(c); setPending(p); setPms(pm.map((x) => ({ ...x, site_name: siteName[x.site_id] })));
    } catch (e) {
      setErr(e.message);
    }
  }, []);

  // Opened from an alert: show that call
  useEffect(() => {
    if (!profile) return;
    const sp = new URLSearchParams(window.location.search);
    if (sp.get('report') === 'followthrough') { setFt(true); setTimeout(() => document.getElementById('followthrough')?.scrollIntoView({ behavior: 'smooth', block: 'start' }), 800); }
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

  useEffect(() => {
    if (!profile) return;
    try { setSiteF(localStorage.getItem(`scp_site_${profile.customer_id}`) || ''); } catch { /* fine */ }
  }, [profile]);
  const showCalls = (t) => { setTab(t); setTimeout(() => document.getElementById('calls')?.scrollIntoView({ behavior: 'smooth', block: 'start' }), 60); };
  const pickSite = (id) => { setSiteF(id); try { localStorage.setItem(`scp_site_${profile.customer_id}`, id); } catch { /* fine */ } };
  // From the location menu: go to that location, scroll to the alert and highlight it
  const [walk, setWalk] = useState(null);       // the alert you jumped to from the menu
  const [menuSignal, setMenuSignal] = useState(0);
  const goTo = (siteId, target) => {
    setWalk({ site: siteId, target, at: Date.now() });
    pickSite(siteId);
    if (target.startsWith('call-')) { setOpen(target.slice(5)); return; }   // answered on the call itself
    let tries = 0;
    const find = () => {
      const el = document.getElementById(target);
      if (!el) { if (tries++ < 15) setTimeout(find, 150); return; }
      el.scrollIntoView({ behavior: 'smooth', block: 'center' });
      document.querySelectorAll('.attn-flash').forEach((x) => x.classList.remove('attn-flash'));
      el.classList.add('attn-flash');
      setTimeout(() => el.classList.remove('attn-flash'), 4500);
    };
    setTimeout(find, 120);
  };
  // When the alert you jumped to is taken care of: back to the top, and open the menu on what's left at that location
  useEffect(() => {
    if (!walk || open) return;      // wait until the call window is closed
    if (Date.now() - walk.at > 20 * 60000) { setWalk(null); return; }
    const a = attention.find((x) => x.site_id === walk.site);
    const left = a?.items || [];
    if (left.some((i) => i.target === walk.target)) return;
    setWalk(null);
    window.scrollTo({ top: 0, behavior: 'smooth' });
    if (left.length) setTimeout(() => setMenuSignal((n) => n + 1), 450);
    else setMsg(`All alerts at ${a?.name || 'this location'} are taken care of.`);
  }, [attention, open]); // eslint-disable-line react-hooks/exhaustive-deps

  // Browser tab: number of things waiting on this store, flashing when a technician is at the door.
  const waitingCount = pending.length + calls.filter((c) => c.status === 'completed' && c.invoice_due_at && new Date(c.invoice_due_at) < new Date()).length + door.length;
  useTabBadge(org?.name, waitingCount, door.length ? `Tech at the door: code ${door[0]?.code || ''}` : null);

  // Opening the call or quote form scrolls to it; closing it returns to the top.
  const openWork = (which) => {
    if (which === 'call') setCreating(true); else setProject(true);
    setTimeout(() => (which === 'call' ? callRef : workRef).current?.scrollIntoView({ behavior: 'smooth', block: 'start' }), 60);
  };
  const closeWork = (which) => {
    if (which === 'call') setCreating(false); else setProject(false);
    window.scrollTo({ top: 0, behavior: 'smooth' });
  };

  // Opening a panel scrolls to it; closing one returns to the top.
  const openArea = (k) => {
    if (k === 'company' && !storePerms(profile).company) { setLocked(true); return; }
    setLocked(false);
    const next = settings === k ? null : k;
    setSettings(next);
    if (next) setTimeout(() => panelRef.current?.scrollIntoView({ behavior: 'smooth', block: 'start' }), 60);
    else window.scrollTo({ top: 0, behavior: 'smooth' });
  };
  const closeArea = () => { setSettings(null); window.scrollTo({ top: 0, behavior: 'smooth' }); };

  useEffect(() => {
    if (!locked || !profile) return;
    q(supabase.from('profiles').select('full_name').eq('customer_id', profile.customer_id).eq('is_org_admin', true).eq('active', true)).then(setAdmins).catch(() => {});
  }, [locked, profile]);

  if (!profile) return <div className="page muted">Loading…</div>;
  const orgLogo = logoOverride !== undefined ? logoOverride : org?.logo_data;

  const isOpen = (s) => !['completed', 'invoiced', 'cancelled'].includes(s);
  const validSite = siteF && allSites.some((x) => x.id === siteF) ? siteF : '';
  const fcalls = validSite ? calls.filter((c) => c.site_id === validSite) : calls;
  const fpending = validSite ? pending.filter((a) => a.work_orders?.site_id === validSite) : pending;
  const fdoor = validSite ? door.filter((v) => v.work_orders?.site_id === validSite) : door;
  const overdueBills = fcalls.filter((c) => c.status === 'completed' && c.invoice_due_at && new Date(c.invoice_due_at) < new Date());
  // Followed up in the last 2 days: off the alert list until then (comes back if still no invoice)
  const followed = (c) => c.bill_requested_at && Date.now() - new Date(c.bill_requested_at).getTime() < 2 * 24 * 3600 * 1000;
  const late = overdueBills.filter((c) => !followed(c));
  const waitingBills = overdueBills.filter(followed);
  const shown = fcalls.filter((c) => c.kind !== 'pm' || !isOpen(c.status)).filter((c) =>
    tab === 'open' ? isOpen(c.status) : tab === 'billing' ? c.status === 'completed' : ['invoiced', 'cancelled'].includes(c.status));
  const counts = {
    open: fcalls.filter((c) => c.kind !== 'pm' && isOpen(c.status)).length,
    billing: fcalls.filter((c) => c.status === 'completed').length,
  };

  return (
    <>
      <TopBar profile={profile} org={org} portal={place.Many} />
      <main className="page stack" style={{ gap: 16 }}>
        <div className="spread">
          <div>
            {orgLogo ? <img className="org-logo" src={orgLogo} alt={org?.name || 'Company logo'} /> : <h1>{org?.name || `Your ${place.many}`}</h1>}
            <div style={{ margin: '6px 0 2px' }}><LocationPicker sites={allSites} attention={attention} value={validSite} onChange={pickSite} onGoTo={goTo} openSignal={menuSignal}
              canAdd={storePerms(profile).locations} onAdd={() => { setAddLoc(true); setLocked(false); setSettings('locations'); setTimeout(() => panelRef.current?.scrollIntoView({ behavior: 'smooth', block: 'start' }), 60); }} /></div>
            <div className="muted small">{profile.title || ''}{profile.approval_limit != null ? ` · approves up to ${money(profile.approval_limit)}` : profile.can_approve ? ' · approves any amount' : ''}
              {' '}<button type="button" className="linkbtn small" onClick={() => { setMonitor(true); setTimeout(() => workRef.current?.scrollIntoView({ behavior: 'smooth', block: 'start' }), 60); }}>🌡 Temperatures</button></div>
          </div>
          {(profile.can_open_calls || profile.is_org_admin) && (
            <div className="order-box">
              <div className="order-label">Order work</div>
              <div className="row" style={{ alignItems: 'flex-start' }}>
                <div className="order-btn">
                  <button disabled={project} onClick={() => openWork('project')}>Install / project quote</button>
                  <span>New equipment or a bigger job</span>
                </div>
                <div className="order-btn">
                  <button className="primary big" disabled={creating} onClick={() => openWork('call')}>+ New service call</button>
                  <span>Something's broken or needs a repair</span>
                </div>
              </div>
            </div>
          )}
        </div>

        <nav className="navstrip" aria-label="Manage">
          {[...SETTINGS_TABS.slice(1), SETTINGS_TABS[0]].filter(([k]) => k === 'company' || storePerms(profile)[k]).map(([k, label]) => (
            <button key={k} className={settings === k ? 'on' : ''} aria-pressed={settings === k} onClick={() => openArea(k)}>
              <span aria-hidden="true">{k === 'company' && !storePerms(profile).company ? '🔒' : ICONS[k]}</span>{tabLabel(k, label, place)}
            </button>
          ))}
        </nav>
        {locked && (
          <div className="notice spread">
            <span><strong>Settings &amp; plan is locked.</strong> Only your admin{admins.length ? ` (${admins.map((a) => a.full_name).join(', ')})` : ''} or someone they give access to can open it. Ask them if you need a change to the company profile, logo or plan.</span>
            <button onClick={() => setLocked(false)}>OK</button>
          </div>
        )}

        <div className="tiles">
          <button className="tile" onClick={() => showCalls('open')}><span className="tile-n">{counts.open}</span><span>Open calls</span></button>
          <button className={`tile${fpending.length ? ' warn' : ''}`} onClick={() => document.getElementById('approvals')?.scrollIntoView({ behavior: 'smooth' })}><span className="tile-n">{fpending.length}</span><span>Waiting for approval</span></button>
          <button className="tile" onClick={() => showCalls('billing')}><span className="tile-n">{counts.billing}</span><span>Done, bill pending</span></button>
          <button className={`tile${late.length ? ' bad' : ''}`} onClick={() => showCalls('billing')}><span className="tile-n">{late.length}</span><span>Invoices not received</span></button>
        </div>

        <button className="searchbar" onClick={() => showCalls('po')}>
          <span aria-hidden="true">🔎</span> Search past calls <span className="muted">— by contractor, trade, {place.one} or date</span>
        </button>
        <button className="searchbar" onClick={() => { setFt(!ft); if (!ft) setTimeout(() => document.getElementById('followthrough')?.scrollIntoView({ behavior: 'smooth', block: 'start' }), 80); }}>
          <span aria-hidden="true">📋</span> Follow-through report <span className="muted">— what was missed, where, and what it cost</span>
        </button>
        {ft && <FollowThroughReport onClose={() => setFt(false)} onOpenCall={setOpen} />}

        <GettingStarted me={profile} onGo={(k) => openArea(k)} onNewCall={() => openWork('call')} />

        <ErrorBox error={err} />
        <Notice>{msg}</Notice>

        <WaitingOnYou attention={attention} siteId={validSite} sites={allSites} onGoTo={goTo} />

        {/* The lead says how many helpers came with him: the person on site confirms */}
        {crewAsk.filter((v) => !validSite || v.work_orders?.site_id === validSite).map((v) => (
          <div key={`crew-${v.id}`} id={`crew-${v.id}`} className="panel panel-pad spread" style={{ borderColor: '#e6c98a', background: '#fffcf3' }}>
            <span><strong>{v.profiles?.full_name}</strong> says he has <strong>{v.crew_helpers === 1 ? '1 helper' : `${v.crew_helpers} helpers`}</strong>{v.crew_names ? ` (${v.crew_names})` : ''} with him at {v.work_orders?.sites?.name} (call #{v.work_orders?.number}). Is that right?</span>
            <span className="row" style={{ gap: 6 }}>
              <button className="primary" onClick={async () => { try { await act('store_confirm_crew', { p_visit: v.id, p_ok: true }); load(); } catch (x) { setErr(x.message); } }}>Yes</button>
              <button onClick={async () => { try { await act('store_confirm_crew', { p_visit: v.id, p_ok: false }); setMsg('Noted. The call is flagged and their office is told.'); load(); } catch (x) { setErr(x.message); } }}>No</button>
            </span>
          </div>
        ))}

        {/* A contractor wants to come back: pick the time that works */}
        {offers.filter((o) => !validSite || o.work_orders?.site_id === validSite).map((o) => (
          <div key={o.id} id={`trip-${o.id}`} className="panel panel-pad" style={{ borderColor: '#9cc3ea', background: '#f4f9ff' }}>
            <TripPick offer={o} contractor={o.work_orders?.contractors?.name} callNo={o.work_orders?.number} site={o.work_orders?.sites?.name} onDone={() => { setMsg('Thanks. They\u2019ve been told.'); load(); }} />
          </div>
        ))}

        {/* Technician waiting at the door for the check-in code */}
        {fdoor.map((v) => {
          const mins = Math.floor((Date.now() - new Date(v.arrived_at).getTime()) / 60000);
          return (
            <div key={v.id} id={`door-${v.id}`} className="doorbell">
              <div className="stack" style={{ gap: 4 }}>
                <strong style={{ fontSize: 18 }}>Technician at the door — waiting {mins < 1 ? 'less than a minute' : `${mins} min`}</strong>
                <span>{v.profiles?.full_name} is at {v.work_orders?.sites?.name}{v.work_orders?.unit ? `, unit ${v.work_orders.unit}` : ''} for call #{v.work_orders?.number}. <strong>Labor time is running</strong> — please meet them and give this code.</span>
              </div>
              <div className="stack" style={{ gap: 6, alignItems: 'center' }}>
                <div className="doorcode">{v.code || '—'}</div>
                {isDemoEmail(profile.email) && (
                  <button type="button" className="demo-act" onClick={async () => {
                    try { await act('demo_tech_enters_code', { p_visit: v.id }); setMsg(`Demo: ${v.profiles?.full_name || 'The technician'} typed in ${v.code} on his phone. He's checked in and the alert is cleared.`); load(); }
                    catch (x) { setErr(x.message); }
                  }}>▶ Demo: give the tech the code</button>
                )}
              </div>
            </div>
          );
        })}
        <Presence onOpen={setOpen} refreshKey={calls} siteId={validSite} onChanged={load} />
        {door.length > 0 && !sound && <button className="danger" onClick={enableAlerts}>🔔 Turn on sound and pop-up alerts for this screen</button>}

        <div ref={panelRef} className="anchor" />
        {settings && <StoreSettings key={org?.id || 'org'} tab={settings} setTab={setSettings} onClose={() => { setAddLoc(false); closeArea(); }} startAdding={addLoc} onLocationsChanged={load} me={profile} org={org} hideTabs onOrgChanged={(logoData) => { if (logoData !== undefined) setLogoOverride(logoData); }} />}
        <div ref={workRef} className="anchor" />
        <AlarmStrip onOpen={() => { setMonitor(true); setTimeout(() => workRef.current?.scrollIntoView({ behavior: 'smooth', block: 'start' }), 60); }} />
        {monitor && <div className="panel panel-pad work-panel"><Monitoring sites={allSites} siteFilter={validSite} onOpenCall={setOpen} onClose={() => setMonitor(false)} /></div>}
        {project && <StoreQuotes profile={profile} sites={allSites} onClose={() => closeWork('project')} onOpenCall={setOpen} />}

        {/* Calls a contractor entered from a phone call — confirm your store asked for them */}
        {calls.filter((c) => c.source === 'contractor' && c.mode === 'verify' && !c.store_confirmed_at && !['cancelled'].includes(c.status)).map((c) => (
          <div key={c.id} id={`confirm-${c.id}`} className="panel panel-pad spread" style={{ borderColor: '#e6c98a', background: '#fffcf3' }}>
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
          <div key={c.id} id={`nacc-${c.id}`} className="panel panel-pad spread" style={{ borderColor: '#e6b3ab', background: '#fffaf9' }}>
            <div><span className="chip tone-red">{c.declined_at ? 'Declined' : 'Not accepted'}</span> <strong>Call #{c.number} · {c.sites?.name}</strong> — {c.contractors?.name} {c.declined_at ? "can't take it" : 'has not accepted it yet'}.</div>
            <button onClick={() => setOpen(c.id)}>What to do</button>
          </div>
        ))}

        <div ref={callRef} className="anchor" />
        {creating && (
          <div className="work-panel-wrap"><NewCallForm side="store" profile={profile} defaultSite={validSite} onCancel={() => closeWork('call')} onCreated={async (wo) => {
            closeWork('call'); await load(); setOpen(wo.id);
          }} /></div>
        )}

        {/* Approvals */}
        <span id="approvals" className="anchor" />
        {fpending.map((a) => (
          <div key={a.id} id={`appr-${a.id}`} className="panel panel-pad spread" style={{ borderColor: '#e6b3ab', background: '#fffaf9' }}>
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

        {/* Calls flagged for the store's review */}
        {(() => {
          const shownFlags = flags.filter((f) => !validSite || f.work_orders?.site_id === validSite);
          const byCall = Object.values(shownFlags.reduce((m, f) => { (m[f.work_order_id] ||= { id: f.work_order_id, wo: f.work_orders, items: [] }).items.push(f); return m; }, {}));
          if (!byCall.length) return null;
          return (
            <div className="panel panel-pad" style={{ borderColor: '#e6c37a' }}>
              <h3 style={{ color: 'var(--amber-fg)' }}>Flagged for your review</h3>
              <div className="small muted" style={{ marginBottom: 4 }}>Open a call to see why. Tap "Got it" on each item once you've looked at it.</div>
              {byCall.map((c) => (
                <div key={c.id} id={`flag-${c.id}`} className="spread small click" style={{ padding: '6px 0', cursor: 'pointer', gap: 10 }} onClick={() => setOpen(c.id)}>
                  <span>Call #{c.wo?.number} · {c.wo?.sites?.name}: {[...new Set(c.items.map((f) => FLAG_LABEL[f.flag] || f.flag))].join(', ')}</span>
                  <strong style={{ whiteSpace: 'nowrap' }}>Review →</strong>
                </div>
              ))}
            </div>
          );
        })()}

        {/* Late bills */}
        {waitingBills.length > 0 && (
          <div className="small muted" style={{ padding: '0 4px' }}>
            Waiting on {waitingBills.length} invoice{waitingBills.length === 1 ? '' : 's'} you already followed up on: {waitingBills.map((c, i) => (
              <span key={c.id}>{i ? ', ' : ''}<a href="#" onClick={(e) => { e.preventDefault(); setOpen(c.id); }}>call #{c.number}</a></span>))}. They'll come back here if they don't arrive within 2 days.
          </div>
        )}
        {late.length > 0 && (
          <div className="panel panel-pad" style={{ borderColor: '#e6b3ab' }}>
            <h3 style={{ color: 'var(--red-fg)' }}>Contractor invoices not received</h3>
            <div className="small muted" style={{ marginBottom: 4 }}>The work is done, but the contractor hasn't sent you their invoice yet. Open a call to ask them for it.</div>
            {late.map((c) => (
              <div key={c.id} id={`late-${c.id}`} className="spread small click" style={{ padding: '6px 0', cursor: 'pointer', gap: 10 }} onClick={() => setOpen(c.id)}>
                <span>Call #{c.number} · {c.sites?.name} · completed {date(c.completed_at)}. <strong>{c.contractors?.name || 'The contractor'}'s invoice was due to you {date(c.invoice_due_at)}</strong>; you haven't received it.
                  {c.bill_requested_at ? <span className="muted"> You asked for it {date(c.bill_requested_at)}.</span> : ''}</span>
                <strong style={{ whiteSpace: 'nowrap' }}>{c.mode === 'verify' ? 'Ask for it →' : `about ${money(c.total_cost)} →`}</strong>
              </div>
            ))}
          </div>
        )}

        {/* Preventive maintenance: stays here until done */}
        {showPlans && (
          <div className="panel panel-pad stack" style={{ gap: 8 }}>
            <div className="spread"><h3>Maintenance plans</h3><button onClick={() => setShowPlans(false)}>Close</button></div>
            <PmPlans side="store" canEdit={!!(profile.is_org_admin || profile.can_manage_equipment || profile.can_manage_pm)} onOpenCall={setOpen} />
          </div>
        )}
        {!showPlans && pms.length === 0 && (
          <div><button onClick={() => setShowPlans(true)}>📋 Maintenance plans</button></div>
        )}
        {pms.length > 0 && (
          <div className="panel">
            <div className="spread" style={{ padding: '12px 16px 0' }}>
              <h3>Preventive maintenance</h3>
              <span className="row" style={{ gap: 8 }}><span className="small muted">Shown until completed</span>{!showPlans && <button className="small" onClick={() => setShowPlans(true)}>📋 All maintenance plans</button>}</span>
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
        <span id="calls" className="anchor" />
        <div className="panel">
          <ScrollRow className="tabs" style={{ padding: '0 8px' }}>
            <button className={tab === 'open' ? 'on' : ''} onClick={() => setTab('open')}>Open calls ({counts.open})</button>
            <button className={tab === 'billing' ? 'on' : ''} onClick={() => setTab('billing')}>Completed — bill pending ({counts.billing})</button>
            <button className={tab === 'closed' ? 'on' : ''} onClick={() => setTab('closed')}>Invoiced</button>
            <button className={tab === 'po' ? 'on' : ''} onClick={() => setTab('po')}>Past calls / PO log</button>
          </ScrollRow>
          {tab === 'po' ? <PoLog /> : (
          <table>
            <thead>
              <tr><th>Call</th><th>Problem</th><th className="hide-sm">Technician</th><th>Status</th><th className="num">Cost</th></tr>
            </thead>
            <tbody>
              {shown.length === 0 && <tr><td colSpan={5} className="empty-cell">
                {tab === 'open' ? <>No open calls right now. When something breaks, tap <strong>+ New service call</strong>, or have an employee scan the unit's QR sticker.</>
                  : tab === 'billing' ? 'No finished calls waiting on a bill.' : 'No invoiced calls yet.'}</td></tr>}
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
      <AppFooter kind="store" />

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
