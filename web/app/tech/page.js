'use client';

import { useEffect, useState, useSyncExternalStore } from 'react';
import { useRouter } from 'next/navigation';
import { supabase } from '@/lib/supabase';
import { portalFor, signOutLocal, isDemoEmail } from '@/lib/useProfile';
import DemoBanner, { backToDemo } from '@/components/DemoBanner';
import * as T from '@/lib/techStore';
import { time, ago, PRIORITY, KIND, STATUS } from '@/lib/format';
import Job from '@/components/tech/Job';
import AlertsButton from '@/components/AlertsButton';
import HeaderMenu from '@/components/HeaderMenu';
import PasswordButton from '@/components/PasswordButton';
import InstallButton from '@/components/InstallButton';
import UpgradeButton from '@/components/UpgradeButton';
import AppFooter from '@/components/AppFooter';

const useTech = () => useSyncExternalStore(T.subscribe, T.getState, T.getState);

export default function TechApp() {
  const router = useRouter();
  const st = useTech();
  const [me, setMe] = useState(null);
  const [open, setOpen] = useState(null);   // visit id
  const [, tick] = useState(0);

  // Who is signed in — works offline from the last known profile.
  useEffect(() => {
    T.load();
    (async () => {
      const { data: s } = await supabase.auth.getSession();
      if (!s.session) return router.replace('/');
      let p = null;
      try { p = JSON.parse(localStorage.getItem('sp_me') || 'null'); } catch { /* none */ }
      if (navigator.onLine) {
        const { data, error } = await supabase.rpc('me');
        if (!error && data?.id) { p = data; localStorage.setItem('sp_me', JSON.stringify(data)); }
        if (!error && !data?.id) return router.replace('/?e=noprofile');
      }
      if (!p) return router.replace('/');
      if (!p.is_technician) return router.replace(portalFor(p));
      setMe(p);
      T.sync();
    })();
    if ('serviceWorker' in navigator) navigator.serviceWorker.register('/sw.js').catch(() => {});
    const stop = T.startAutoSync();
    const t = setInterval(() => tick((n) => n + 1), 30000);   // keep times and the meter fresh
    return () => { stop(); clearInterval(t); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const v = T.view();

  // Tell dispatch the tech has seen new jobs.
  useEffect(() => {
    if (!v) return;
    for (const j of v.jobs) {
      if (j.visit.status === 'assigned' && !j.visit.received_at) T.act('tech_received', { p_visit: j.visit.id }, { label: 'Job received' });
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [st.server]);

  async function signOut() {
    if (st.queue.length && !window.confirm(`${st.queue.length} change(s) have not been sent yet. Sign out anyway? They will be lost.`)) return;
    T.clearAll(); localStorage.removeItem('sp_me');
    await signOutLocal();
    window.location.replace(isDemoEmail(me?.email) ? '/demo' : '/');
  }

  if (!me) return <div className="page muted">Loading…</div>;
  const job = open && v?.jobs.find((j) => j.visit.id === open);

  return (
    <>
      <header className="topbar" style={{ padding: '0 12px' }}>
        {job ? <button onClick={() => setOpen(null)}>‹ Jobs</button> : <div className="brand">Service Call <span>Proof</span></div>}
        {!job && (
          <HeaderMenu name={me.full_name}>
            <div className="hdr-who">{me.full_name}</div>
            <AlertsButton />
            {(me.is_org_admin || me.can_dispatch || me.can_bill) && <button onClick={() => router.push('/office')}>Office</button>}
            {me.is_org_admin && <UpgradeButton profile={me} />}
            <InstallButton />
            {!isDemoEmail(me.email) && <PasswordButton />}
            {isDemoEmail(me.email) ? <button onClick={signOut}>← Back to demo menu</button> : <button onClick={signOut}>Sign out</button>}
          </HeaderMenu>
        )}
      </header>
      {isDemoEmail(me.email) && <DemoBanner who={me.full_name} compact={!!job} />}
      <SyncBar st={st} />
      {st.clock && !st.clock.ok && (
        <div className="syncbar off" style={{ background: 'var(--red-fg)' }}>
          This phone's clock is {Math.round(Math.abs(st.clock.offset_s) / 60)} min {st.clock.offset_s > 0 ? 'fast' : 'slow'}. Set Date &amp; Time to “Set automatically” — job times depend on it. Your office has been told.
        </div>
      )}
      {st.problems.some((p) => p.fn !== 'tech_checkin') && (
        <div className="tech" style={{ paddingBottom: 0 }}>
          {st.problems.filter((p) => p.fn !== 'tech_checkin').map((p) => (
            <div key={p.id} className="error">
              <strong>Not saved: {p.label}</strong> — {p.message}
              <div><button style={{ marginTop: 6 }} onClick={() => T.dismissProblem(p.id)}>OK</button></div>
            </div>
          ))}
        </div>
      )}
      {!v ? (
        <main className="tech"><div className="sec muted">{st.online ? 'Loading your jobs…' : 'No signal, and no jobs saved on this phone yet. Connect once to download your jobs.'}</div></main>
      ) : job ? (
        <Job job={job} cat={v.catalog} wifi={v.wifi?.[job.site.id]} me={me} onBack={() => setOpen(null)} />
      ) : (
        <JobList v={v} onOpen={setOpen} />
      )}
    </>
  );
}

function SyncBar({ st }) {
  const n = st.queue.length;
  if (!st.online) return <div className="syncbar off">No signal — working offline. {n ? `${n} change${n > 1 ? 's' : ''} saved on this phone, will send automatically.` : 'Everything is saved on this phone.'}</div>;
  if (n || st.syncing) return <div className="syncbar wait">{st.syncing ? 'Sending…' : ''} {n ? `${n} change${n > 1 ? 's' : ''} waiting to send` : ''}{st.lastSync ? ` · last synced ${time(st.lastSync)}` : ''}</div>;
  return <div className="syncbar ok">All synced ✓{st.lastSync ? ` · ${time(st.lastSync)}` : ''}</div>;
}

function JobList({ v, onOpen }) {
  const active = v.jobs.filter((j) => j.visit.status !== 'done');
  const done = v.jobs.filter((j) => j.visit.status === 'done');
  return (
    <main className="tech">
      <Clock v={v} />
      <div className="spread">
        <h1>Your jobs</h1>
        <button onClick={() => T.sync()}>Refresh</button>
      </div>
      {active.length === 0 && !(v.open_calls || []).length && <div className="sec muted">No open jobs right now.</div>}
      {active.map((j) => <JobCard key={j.visit.id} j={j} onOpen={onOpen} />)}
      <OpenCalls calls={v.open_calls || []} />
      {done.length > 0 && <h3 className="muted" style={{ marginTop: 8 }}>Finished today</h3>}
      {done.map((j) => <JobCard key={j.visit.id} j={j} onOpen={onOpen} />)}
    <AppFooter kind="tech" />
    </main>
  );
}

function JobCard({ j, onOpen }) {
  const s = j.visit.status;
  const label = s === 'assigned' ? 'New' : s === 'en_route' ? 'On the way' : s === 'on_site' ? 'On site' : 'Done';
  const tone = s === 'on_site' ? 'green' : s === 'en_route' ? 'amber' : s === 'done' ? 'slate' : 'violet';
  return (
    <div className={`jobcard ${j.wo.priority === 1 ? 'urgent' : ''}`} onClick={() => onOpen(j.visit.id)} style={{ cursor: 'pointer' }}>
      <div className="spread">
        <strong>#{j.wo.number} · {j.customer}</strong>
        <span className={`chip tone-${tone}`}>{label}</span>
      </div>
      <div><strong>{j.site.name}{j.wo.unit ? `, unit ${j.wo.unit}` : ''}</strong> <span className="muted small">{j.site.address}</span></div>
      <div className="row" style={{ gap: 6 }}>
        {j.wo.priority === 1 && <span className="chip tone-red">{PRIORITY[1]}</span>}
        {j.wo.kind !== 'service' && <span className="chip tone-green">{KIND[j.wo.kind]}</span>}
        {j.visit.visit_no > 1 && <span className="chip tone-violet">Return visit</span>}
        <span className="small">{j.wo.issue || j.wo.problem}</span>
      </div>
      {s === 'en_route' && j.visit.eta_at && <div className="small muted">ETA {time(j.visit.eta_at)}</div>}
      {s === 'assigned' && (j.visit.scheduled_start
        ? <div className="small"><strong>Scheduled {new Date(j.visit.scheduled_start).toLocaleDateString('en-US', { weekday: 'short', month: 'short', day: 'numeric' })} {time(j.visit.scheduled_start)}{j.visit.scheduled_end ? `–${time(j.visit.scheduled_end)}` : ''}</strong></div>
        : <div className="small muted">Assigned {ago(j.visit.assigned_at)}</div>)}
      {s === 'done' && <div className="small muted">{STATUS[j.wo.status]?.label || j.visit.outcome}</div>}
    </div>
  );
}

// Time Verify calls anyone on the team can take. First to tap "I'm going" gets it.
function OpenCalls({ calls }) {
  const [busy, setBusy] = useState(null);
  const [err, setErr] = useState('');
  if (!calls.length) return null;
  return (
    <>
      <h3 style={{ marginTop: 8 }}>Calls waiting for a tech ({calls.length})</h3>
      {err && <div className="error">{err}</div>}
      {calls.map((c) => (
        <div key={c.id} className={`jobcard ${c.priority === 1 ? 'urgent' : ''}`}>
          <div className="spread">
            <strong>#{c.number} · {c.customer}</strong>
            <span className="chip tone-blue">{c.return_visit ? 'Return trip' : c.accepted_at ? 'Accepted' : 'New'}</span>
          </div>
          <div><strong>{c.site.name}{c.unit ? `, unit ${c.unit}` : ''}</strong> <span className="muted small">{c.site.address}</span></div>
          <div className="row" style={{ gap: 6 }}>
            {c.priority === 1 && <span className="chip tone-red">{PRIORITY[1]}</span>}
            <span className="small">{c.issue && c.issue !== c.problem ? `${c.issue}: ` : ''}{c.problem}</span>
          </div>
          <div className="small muted">PO {c.po_number}{c.scheduled_start ? ` · scheduled ${time(c.scheduled_start)}${c.scheduled_end ? `–${time(c.scheduled_end)}` : ''}` : ` · opened ${ago(c.created_at)}`}</div>
          <button className="primary big" disabled={!!busy} onClick={async () => {
            setBusy(c.id); setErr('');
            try { await T.claim(c.id); } catch (e) { setErr(e.message); T.sync(); } finally { setBusy(null); }
          }}>{busy === c.id ? 'Taking it…' : "I'm going"}</button>
          <div className="small muted">Tap when you leave. The customer sees the town you're starting from, never the exact spot.</div>
        </div>
      ))}
    </>
  );
}

function Clock({ v }) {
  const c = v.clock || {};
  if (!c.shift) return (
    <div className="sec spread"><span className="muted">Not clocked in</span>
      <button className="primary" onClick={() => T.act('clock', { p_action: 'in', p_id: T.uuid() }, { label: 'Clock in' })}>Clock in</button></div>
  );
  return (
    <div className="sec spread">
      <span>{c.brk ? <strong>On break</strong> : 'On shift'} <span className="muted small">since {time(c.brk ? c.brk.start_at : c.shift.start_at)}</span></span>
      <div className="row" style={{ gap: 6 }}>
        {c.brk
          ? <button onClick={() => T.act('clock', { p_action: 'break_end' }, { label: 'End break' })}>End break</button>
          : <button onClick={() => T.act('clock', { p_action: 'break_start', p_id: T.uuid() }, { label: 'Start break' })}>Break</button>}
        <button onClick={() => window.confirm('Clock out for the day?') && T.act('clock', { p_action: 'out' }, { label: 'Clock out' })}>Clock out</button>
      </div>
    </div>
  );
}
