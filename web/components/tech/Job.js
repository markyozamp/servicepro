'use client';

// One job on the technician's phone. Everything here works with no signal: taps are saved on the
// phone with their real time and sent when there is a connection.
import { useEffect, useMemo, useRef, useState } from 'react';
import * as T from '@/lib/techStore';
import { money, time, date, PRIORITY } from '@/lib/format';

const ETAS = [10, 20, 30, 45, 60, 90];

export default function Job({ job, cat, wifi }) {
  const v = job.visit; const w = job.wo;
  const [, tick] = useState(0);
  useEffect(() => { const t = setInterval(() => tick((n) => n + 1), 20000); return () => clearInterval(t); }, []);
  const m = T.meter(job);

  return (
    <main className="tech">
      <Header job={job} wifi={wifi} />
      {v.status === 'assigned' && <StartDriving job={job} />}
      {v.status === 'en_route' && <Driving job={job} />}
      {v.status === 'on_site' && <OnSite job={job} cat={cat} m={m} />}
      {v.status === 'done' && <Done job={job} />}
      <Background job={job} />
    </main>
  );
}

function Header({ job, wifi }) {
  const [copied, setCopied] = useState(false);
  const w = job.wo; const s = job.site;
  const maps = s.lat ? `https://maps.google.com/?q=${s.lat},${s.lon}` : `https://maps.google.com/?q=${encodeURIComponent(s.address)}`;
  return (
    <div className="sec">
      <div className="spread">
        <h2>#{w.number} · {job.customer}</h2>
        {w.priority === 1 && <span className="chip tone-red">{PRIORITY[1]}</span>}
      </div>
      <div><strong>{s.name}{w.unit ? `, unit ${w.unit}` : ''}</strong><div className="small"><a href={maps} target="_blank" rel="noreferrer">{s.address} ↗</a></div></div>
      <div><strong>{w.issue && w.issue !== w.problem ? `${w.issue}: ` : ''}</strong>{w.problem}</div>
      {(w.contact_name || w.contact_phone) && (
        <div className="small">Meet: <strong>{w.contact_name}</strong>{w.contact_phone && <> · <a href={`tel:${w.contact_phone}`}>{w.contact_phone}</a></>}</div>
      )}
      {(s.access_notes || w.entry_notes) && <div className="notice small">{[w.entry_notes, s.access_notes].filter(Boolean).join(' · ')}</div>}
      {job.warranties.length > 0 && (
        <div className="notice small"><strong>Warranty on this site:</strong> {job.warranties.map((x) => `${x.kind} until ${date(x.ends_on)} (${x.description})`).join('; ')}</div>
      )}
      {wifi?.ssid && (
        <div className="small spread" style={{ background: 'var(--blue-bg)', color: 'var(--blue-fg)', borderRadius: 8, padding: '6px 10px' }}>
          <span>📶 Store Wi-Fi: <strong>{wifi.ssid}</strong>{wifi.password ? <> · password <strong>{wifi.password}</strong></> : ' (no password)'}</span>
          {wifi.password && <button onClick={() => { navigator.clipboard?.writeText(wifi.password).then(() => setCopied(true)).catch(() => {}); }}>{copied ? 'Copied' : 'Copy'}</button>}
        </div>
      )}
      <div className="small muted">{w.po_number}{w.agreement ? ` · ${w.agreement}` : ''}{w.after_hours ? ' · after hours' : ''}{job.visit.visit_no > 1 ? ` · visit ${job.visit.visit_no}` : ''}</div>
    </div>
  );
}

// ---------------- Before arriving ----------------
function StartDriving({ job }) {
  const [busy, setBusy] = useState(false);
  async function go(min) {
    setBusy(true);
    const p = await T.position(5000);
    T.act('tech_start', { p_visit: job.visit.id, p_lat: p?.lat ?? null, p_lon: p?.lon ?? null }, { label: 'Start driving' });
    T.act('tech_update_eta', { p_visit: job.visit.id, p_eta_at: new Date(Date.now() + min * 60000).toISOString() }, { label: 'ETA' });
    setBusy(false);
  }
  return (
    <div className="sec">
      <h3>Start driving — how long until you get there?</h3>
      <div className="row" style={{ gap: 8 }}>
        {ETAS.map((n) => <button key={n} className="primary" disabled={busy} onClick={() => go(n)} style={{ flex: '1 1 30%' }}>{n} min</button>)}
      </div>
      <div className="small muted">The store sees your arrival time — never your location.</div>
    </div>
  );
}

function Driving({ job }) {
  const [dist, setDist] = useState(null);
  const [eta, setEta] = useState(false);
  const arrived = useRef(false);
  const s = job.site;

  // While the app is open, arrival is detected automatically from GPS.
  useEffect(() => {
    if (!navigator.geolocation || s.lat == null) return;
    const id = navigator.geolocation.watchPosition((p) => {
      const here = { lat: p.coords.latitude, lon: p.coords.longitude };
      const d = T.feet(here, { lat: s.lat, lon: s.lon });
      setDist(d);
      if (d <= (s.geofence_ft || 250) && !arrived.current) {
        arrived.current = true;
        T.act('tech_arrive', { p_visit: job.visit.id, p_lat: here.lat, p_lon: here.lon, p_source: 'geofence' }, { label: 'Arrived' });
      }
    }, () => {}, { enableHighAccuracy: true, maximumAge: 15000 });
    return () => navigator.geolocation.clearWatch(id);
  }, [job.visit.id, s.lat, s.lon, s.geofence_ft]);

  async function here() {
    if (arrived.current) return;
    arrived.current = true;
    const p = await T.position(6000);
    T.act('tech_arrive', { p_visit: job.visit.id, p_lat: p?.lat ?? null, p_lon: p?.lon ?? null, p_source: 'manual' }, { label: 'Arrived' });
  }
  return (
    <div className="sec">
      <h3>On the way{job.visit.eta_at ? ` · ETA ${time(job.visit.eta_at)}` : ''}</h3>
      {dist != null && <div className="small muted">{dist > 5280 ? `${(dist / 5280).toFixed(1)} miles away` : `${Math.round(dist)} ft away`} — arrival is recorded automatically when you get there.</div>}
      <button className="primary big" onClick={here}>I'm here</button>
      {!eta ? <button onClick={() => setEta(true)}>Update ETA</button> : (
        <div className="row" style={{ gap: 8 }}>
          {ETAS.map((n) => <button key={n} onClick={() => { T.act('tech_update_eta', { p_visit: job.visit.id, p_eta_at: new Date(Date.now() + n * 60000).toISOString() }, { label: 'ETA' }); setEta(false); }} style={{ flex: '1 1 30%' }}>{n} min</button>)}
        </div>
      )}
    </div>
  );
}

// ---------------- On site ----------------
function OnSite({ job, cat, m }) {
  const w = job.wo; const v = job.visit;
  const [quote, setQuote] = useState(null);     // null | { parts: [...] }
  const needsCheckin = v.checkin_required && !(v.checkin_verified || v.checkin_local);
  const service = w.kind === 'service' || w.kind === 'install';
  const kinds = new Set(job.photos.map((p) => p.kind));
  const eq = job.equipment.find((e) => e.id === w.equipment_id);
  const eqDone = !!(eq && eq.confirmed) && (kinds.has('nameplate') || kinds.has('equipment'));

  return (
    <>
      <Meter job={job} m={m} onMore={() => setQuote({ parts: [] })} />
      {needsCheckin && <CheckIn job={job} />}
      {!needsCheckin && (
        <>
          {(service || w.equipment_id) && <Equipment job={job} cat={cat} done={eqDone} />}
          {service && <Photos job={job} />}
          {w.kind === 'pm' && <Checklist job={job} />}
          {service && <Repair job={job} cat={cat} />}
          {w.kind !== 'pm' && <Parts job={job} cat={cat} m={m} onNeedMore={(p) => setQuote({ parts: [p] })} />}
          {quote ? <Quote job={job} cat={cat} m={m} init={quote} onClose={() => setQuote(null)} />
            : !m.pending && m.state !== 'no_limit' && <button onClick={() => setQuote({ parts: [] })}>Need more? Request approval (PO {String.fromCharCode(65 + Math.max(0, ...job.po_lines.map((l) => l.seq)))})</button>}
          <Finish job={job} cat={cat} m={m} eqDone={eqDone} />
        </>
      )}
    </>
  );
}

function Meter({ job, m, onMore }) {
  const vibrated = useRef(false);
  useEffect(() => {
    if ((m.state === 'stop' || m.state === 'over') && !m.pending && !vibrated.current && navigator.vibrate) { navigator.vibrate([300, 150, 300]); vibrated.current = true; }
  }, [m.state, m.pending]);
  if (m.limit == null) return <div className="meter no_limit"><strong>No spending limit on this job</strong><span className="small">Running cost {money(m.used)}</span></div>;
  const pct = Math.min(100, (m.used / m.limit) * 100);
  const stopPct = Math.min(100, (m.stopAt / m.limit) * 100);
  return (
    <>
      <div className={`meter ${m.pending ? 'stop' : m.state}`}>
        <div className="spread"><strong>Limit {money(m.limit)}</strong><strong>Used {money(m.used)} ({Math.round(pct)}%)</strong></div>
        <div className="bar"><i style={{ width: `${pct}%` }} /><b style={{ left: `${stopPct}%` }} /></div>
        <div className="small">Labor {Math.floor(m.minutes / 60)} h {m.minutes % 60} m = {money(m.labor)} · Parts {money(m.parts)}{m.trips ? ` · Trip ${money(m.trips)}` : ''}</div>
      </div>
      {m.pending ? (
        <div className="notice"><strong>Waiting for approval: {m.pending.po} — up to {money(m.pending.amount)}.</strong>
          {m.pending.owner_status === 'pending' ? ' The manager approved; waiting on the building owner.' : ''} Time keeps counting for {m.wait} minutes. If no answer, make the equipment safe and finish as "Quote sent — leaving".</div>
      ) : (m.state === 'stop' || m.state === 'over') && (
        <div className="stopwall">
          <span>STOP — {m.state === 'over' ? 'over' : 'at'} the approved limit. Request more before doing any more work.</span>
          <span className="small" style={{ fontWeight: 400 }}>The rest of the limit ({money(Math.max(0, m.limit - m.used))}) is kept for waiting on the answer and making the equipment safe.</span>
          <button className="primary big" onClick={onMore}>Request more</button>
        </div>
      )}
      {m.emergencyLimit != null && <div className="small muted">Emergency: the customer pre-approved up to {money(m.emergencyLimit)}. Requests within that go ahead immediately.</div>}
    </>
  );
}

function CheckIn({ job }) {
  const [mode, setMode] = useState('code');
  const [code, setCode] = useState('');
  const [person, setPerson] = useState('');
  const [reason, setReason] = useState('');
  const v = job.visit;
  const wrong = T.getState().problems.filter((p) => p.fn === 'tech_checkin' && p.visit === v.id).slice(-1)[0];
  const send = () => {
    T.getState().problems.filter((p) => p.fn === 'tech_checkin' && p.visit === v.id).forEach((p) => T.dismissProblem(p.id));
    if (mode === 'name') T.act('tech_checkin', { p_visit: v.id, p_method: 'name_only', p_person: person, p_reason: reason }, { label: 'Check-in (name only)' });
    else T.act('tech_checkin', { p_visit: v.id, p_method: mode === 'backup' ? 'backup_code' : 'code', p_code: code }, { label: 'Check-in code' });
  };
  return (
    <div className="sec">
      <h3><span className="tick" />Check in with the store</h3>
      {v.arrived_at && (() => {
        const mins = Math.floor((Date.now() - new Date(v.arrived_at).getTime()) / 60000);
        return <div className={mins >= 5 ? 'notice small' : 'small muted'}>
          Your time started when you arrived ({time(v.arrived_at)}) — waiting {mins} min. {mins < 5 ? 'The store has been alerted.' : mins < 10 ? 'No answer, so the store\'s second contact has been alerted.' : 'Still no answer — the store\'s third contact and your office have been alerted.'}
          {mins >= 10 && ' Still no one? Use the store backup code, or "No code available".'}
        </div>;
      })()}
      {mode !== 'name' ? (
        <>
          <div className="small">{mode === 'code' ? 'Ask the store person for the 4-digit code for this call.' : 'Enter the store\'s standing backup code.'}</div>
          {wrong && <div className="error"><strong>{wrong.message}</strong></div>}
          <input className="codebox" inputMode="numeric" maxLength={8} value={code} onChange={(e) => setCode(e.target.value.replace(/\D/g, ''))} placeholder="••••" />
          <button className="primary big" disabled={code.length < 4} onClick={send}>Check in</button>
          <div className="small muted">No signal? Enter it anyway — it's checked when the phone reconnects.</div>
          <div className="row" style={{ gap: 8 }}>
            {mode === 'code' && job.site.has_backup_code && <button onClick={() => { setMode('backup'); setCode(''); }}>Use store backup code</button>}
            {mode === 'backup' && <button onClick={() => { setMode('code'); setCode(''); }}>Use call code</button>}
            <button onClick={() => setMode('name')}>No code available</button>
          </div>
        </>
      ) : (
        <>
          <label>Name of the person you met<input value={person} onChange={(e) => setPerson(e.target.value)} /></label>
          <label>Why no code?<input value={reason} onChange={(e) => setReason(e.target.value)} placeholder="e.g. Manager off today; met assistant manager" /></label>
          <button className="primary big" disabled={!person.trim() || reason.trim().length < 5} onClick={send}>Check in (will be flagged for review)</button>
          <button onClick={() => setMode('code')}>Back to code</button>
        </>
      )}
    </div>
  );
}

function Camera({ job, kind, label, onTaken, extra }) {
  const [busy, setBusy] = useState(false);
  return (
    <label className="camera">
      {busy ? 'Saving…' : `📷 ${label}`}
      <input type="file" accept="image/*" capture="environment" disabled={busy} onChange={async (e) => {
        const f = e.target.files?.[0]; e.target.value = '';
        if (!f) return;
        setBusy(true);
        const p = await T.position(3000);
        const id = await T.addPhoto(job, kind, f, { lat: p?.lat ?? null, lon: p?.lon ?? null, ...(extra || {}) });
        setBusy(false);
        onTaken && onTaken(id);
      }} />
    </label>
  );
}

function Thumbs({ job, kinds }) {
  const list = job.photos.filter((p) => !kinds || kinds.includes(p.kind));
  const [urls, setUrls] = useState({});
  useEffect(() => {
    let alive = true; const made = [];
    (async () => {
      const u = {};
      for (const p of list) {
        if (!p.local) continue;
        const b = await T.photoGet(p.id).catch(() => null);
        if (b) { u[p.id] = URL.createObjectURL(b); made.push(u[p.id]); }
      }
      if (alive) setUrls(u);
    })();
    return () => { alive = false; made.forEach((x) => URL.revokeObjectURL(x)); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [list.map((p) => p.id).join(',')]);
  if (!list.length) return null;
  return <div className="thumbs">{list.map((p) => <div key={p.id} className="t">{urls[p.id] ? <img src={urls[p.id]} alt={p.kind} /> : '✓'}<span>{p.kind}</span></div>)}</div>;
}

function Equipment({ job, cat, done }) {
  const w = job.wo;
  const current = job.equipment.find((e) => e.id === w.equipment_id);
  const [edit, setEdit] = useState(!current);
  const [pick, setPick] = useState(current?.id || '');
  const base = job.equipment.find((e) => e.id === pick);
  const [f, setF] = useState({ type: current?.type_code || w.equipment_type_code || '', mfr: current?.manufacturer || '', model: current?.model || '', serial: current?.serial || '', loc: current?.location || '' });
  const hasPlate = job.photos.some((p) => p.kind === 'nameplate' || p.kind === 'equipment');
  useEffect(() => {
    if (!base) return;
    setF({ type: base.type_code || '', mfr: base.manufacturer || '', model: base.model || '', serial: base.serial || '', loc: base.location || '' });
  }, [pick]); // eslint-disable-line react-hooks/exhaustive-deps
  const save = () => {
    T.act('confirm_equipment', { p_visit: job.visit.id, p_type_code: f.type, p_manufacturer: f.mfr, p_model: f.model, p_serial: f.serial,
      p_location: f.loc || null, p_equipment: pick && !String(pick).startsWith('local-') ? pick : null }, { label: 'Equipment' });
    setEdit(false);
  };
  return (
    <div className="sec">
      <h3><span className={`tick ${done ? 'on' : ''}`}>{done ? '✓' : ''}</span>Equipment</h3>
      <Camera job={job} kind="nameplate" label={hasPlate ? 'Another nameplate photo' : 'Photo of the nameplate'} />
      <Thumbs job={job} kinds={['nameplate', 'equipment']} />
      {!edit && current ? (
        <div className="spread">
          <div><strong>{current.type}</strong> — {current.manufacturer} {current.model}<div className="small muted">S/N {current.serial}{current.location ? ` · ${current.location}` : ''}</div></div>
          <div className="stack" style={{ gap: 6, alignItems: 'flex-end' }}>
            {current.confirmed && <span className="chip tone-green">On record ✓</span>}
            <button onClick={() => { setPick(current.id); setEdit(true); }}>{current.confirmed ? 'Wrong unit / fix' : 'Check & confirm'}</button>
          </div>
        </div>
      ) : (
        <>
          {job.equipment.length > 0 && (
            <label>Which unit?
              <select value={pick} onChange={(e) => setPick(e.target.value)}>
                <option value="">New unit (not listed)</option>
                {job.equipment.map((e) => <option key={e.id} value={e.id}>{e.type} — {e.manufacturer} {e.model} {e.location ? `(${e.location})` : ''}</option>)}
              </select>
            </label>
          )}
          <label>Type
            <select value={f.type} onChange={(e) => setF({ ...f, type: e.target.value })}>
              <option value="">Choose…</option>
              {cat.equipment_types.map((t) => <option key={t.code} value={t.code}>{t.name}</option>)}
            </select>
          </label>
          <div className="row"><label className="grow">Make<input value={f.mfr} onChange={(e) => setF({ ...f, mfr: e.target.value })} /></label>
            <label className="grow">Model<input value={f.model} onChange={(e) => setF({ ...f, model: e.target.value })} /></label></div>
          <label>Serial <span className="muted" style={{ fontWeight: 400 }}>(can't read it? type UNREADABLE — the photo is the record)</span><input value={f.serial} onChange={(e) => setF({ ...f, serial: e.target.value })} /></label>
          <label>Where is it?<input value={f.loc} onChange={(e) => setF({ ...f, loc: e.target.value })} placeholder="e.g. Roof, condenser 3" /></label>
          {!hasPlate && <div className="small muted">Take the nameplate photo first.</div>}
          <button className="primary big" disabled={!hasPlate || !f.type || !f.mfr.trim() || !f.model.trim() || !f.serial.trim()} onClick={save}>Confirm equipment</button>
        </>
      )}
    </div>
  );
}

function Photos({ job }) {
  const k = new Set(job.photos.map((p) => p.kind));
  return (
    <div className="sec">
      <h3><span className={`tick ${k.has('before') && k.has('after') ? 'on' : ''}`}>{k.has('before') && k.has('after') ? '✓' : ''}</span>Before & after photos</h3>
      <div className="row" style={{ gap: 8 }}>
        <Camera job={job} kind="before" label={k.has('before') ? 'Before ✓' : 'Before'} />
        <Camera job={job} kind="after" label={k.has('after') ? 'After ✓' : 'After'} />
        <Camera job={job} kind="other" label="Other" />
      </div>
      <Thumbs job={job} kinds={['before', 'after', 'other', 'part']} />
    </div>
  );
}

function Repair({ job, cat }) {
  const w = job.wo;
  const eqCode = job.equipment.find((e) => e.id === w.equipment_id)?.type_code || w.equipment_type_code;
  const list = cat.repair_types.filter((r) => !r.equipment_type_codes || !eqCode || r.equipment_type_codes.includes(eqCode));
  const others = cat.repair_types.filter((r) => !list.includes(r));
  const cur = cat.repair_types.find((r) => r.id === w.repair_type_id);
  return (
    <div className="sec">
      <h3><span className={`tick ${cur ? 'on' : ''}`}>{cur ? '✓' : ''}</span>Repair performed</h3>
      <select value={w.repair_type_id || ''} onChange={(e) => e.target.value && T.act('set_repair_type', { p_visit: job.visit.id, p_repair_type: e.target.value, p_apply_kit: true }, { label: 'Repair' })}>
        <option value="">Choose the repair…</option>
        {list.map((r) => <option key={r.id} value={r.id}>{r.name}</option>)}
        {others.length > 0 && <optgroup label="Other repairs">{others.map((r) => <option key={r.id} value={r.id}>{r.name}</option>)}</optgroup>}
      </select>
      {cur && (cur.kit || []).length > 0 && <div className="small muted">Usual parts for this repair were added below — change them if needed.</div>}
    </div>
  );
}

function Parts({ job, cat, m, onNeedMore }) {
  const [adding, setAdding] = useState(false);
  const [q, setQ] = useState('');
  const w = job.wo;
  const found = useMemo(() => cat.parts.filter((p) => `${p.name} ${p.sku} ${p.category}`.toLowerCase().includes(q.toLowerCase())).slice(0, 40), [q, cat.parts]);
  const price = (p) => (job.rules.parts_covered ? 0 : Math.round(Number(p.price) * (1 - Number(job.rules.parts_disc || 0) / 100) * 100) / 100);
  function setQty(partId, qty, unit) {
    const cur = job.parts.find((x) => x.part_id === partId);
    const add = (qty - Number(cur?.qty || 0)) * unit;
    if (add > 0 && m.limit != null && m.used + add > m.limit) {
      const p = cat.parts.find((x) => x.id === partId);
      window.alert(`That part takes the job to ${money(m.used + add)} — over the approved ${money(m.limit)}. Request approval first.`);
      onNeedMore({ part_id: partId, name: p?.name, qty: qty - Number(cur?.qty || 0), price: unit });
      return;
    }
    T.act('set_part_used', { p_visit: job.visit.id, p_part: partId, p_qty: qty }, { label: 'Part' });
  }
  const ok = job.parts.length > 0 || w.no_parts_used;
  return (
    <div className="sec">
      <h3><span className={`tick ${ok ? 'on' : ''}`}>{ok ? '✓' : ''}</span>Parts used</h3>
      {job.parts.map((p) => (
        <div key={p.part_id} className="spread">
          <div>{p.name}<div className="small muted">{p.covered ? 'covered' : `${money(p.unit_price)} each`}</div></div>
          <div className="stepper">
            <button onClick={() => setQty(p.part_id, Number(p.qty) - 1, Number(p.unit_price))}>−</button>
            <span>{Number(p.qty)}</span>
            <button onClick={() => setQty(p.part_id, Number(p.qty) + 1, Number(p.unit_price))}>+</button>
          </div>
        </div>
      ))}
      {adding ? (
        <>
          <input autoFocus placeholder="Search parts…" value={q} onChange={(e) => setQ(e.target.value)} />
          <div className="pick">
            {found.map((p) => (
              <button key={p.id} onClick={() => { setQty(p.id, Number(job.parts.find((x) => x.part_id === p.id)?.qty || 0) + 1, price(p)); setAdding(false); setQ(''); }}>
                <span>{p.name}<span className="small muted"> · {p.sku}</span></span><span>{money(price(p))}</span>
              </button>
            ))}
          </div>
          <button onClick={() => setAdding(false)}>Cancel</button>
        </>
      ) : (
        <div className="row" style={{ gap: 8 }}>
          <button className="primary" onClick={() => setAdding(true)}>+ Add part</button>
          {job.parts.length === 0 && (
            <button className={w.no_parts_used ? 'primary' : ''} onClick={() => T.act('set_no_parts_used', { p_visit: job.visit.id, p_value: !w.no_parts_used }, { label: 'No parts' })}>
              {w.no_parts_used ? '✓ No parts used' : 'No parts used'}
            </button>
          )}
        </div>
      )}
    </div>
  );
}

function Checklist({ job }) {
  const w = job.wo;
  const items = Array.isArray(w.checklist) ? w.checklist : [];
  const res = w.checklist_results || {};
  const [reading, setReading] = useState({});
  const doneAll = items.every((it, i) => it.required === false || res[String(i)]?.done);
  return (
    <div className="sec">
      <h3><span className={`tick ${doneAll ? 'on' : ''}`}>{doneAll ? '✓' : ''}</span>PM checklist</h3>
      {items.map((it, i) => {
        const r = res[String(i)];
        const photo = job.photos.find((p) => p.kind === 'checklist' && p.checklist_index === i) || (r?.photo_id ? { id: r.photo_id } : null);
        return (
          <div key={i} className="stack" style={{ gap: 6, borderBottom: '1px solid var(--line)', paddingBottom: 8 }}>
            <div className="spread"><strong>{r?.done ? '✓ ' : ''}{it.item}</strong></div>
            {it.reading && <input placeholder={`Reading (${it.reading})`} value={reading[i] ?? r?.reading ?? ''} onChange={(e) => setReading({ ...reading, [i]: e.target.value })} inputMode="decimal" />}
            <div className="row" style={{ gap: 8 }}>
              {it.photo && <Camera job={job} kind="checklist" label={photo ? 'Photo ✓' : 'Photo'} onTaken={(id) => setReading((x) => ({ ...x, [`p${i}`]: id }))} />}
              <button className={r?.done ? '' : 'primary'} disabled={(it.photo && !photo && !reading[`p${i}`]) || (it.reading && !(reading[i] ?? r?.reading))}
                onClick={() => T.act('set_checklist_result', { p_visit: job.visit.id, p_index: i, p_done: !r?.done, p_reading: reading[i] ?? r?.reading ?? null, p_photo: reading[`p${i}`] || r?.photo_id || null }, { label: 'Checklist' })}>
                {r?.done ? 'Undo' : 'Done'}
              </button>
            </div>
          </div>
        );
      })}
    </div>
  );
}

function Quote({ job, cat, m, init, onClose }) {
  const [hours, setHours] = useState(1);
  const [parts, setParts] = useState(init.parts || []);
  const [why, setWhy] = useState('');
  const [q, setQ] = useState('');
  const [photo, setPhoto] = useState(null);
  const rate = m.rate;
  const price = (p) => (job.rules.parts_covered ? 0 : Math.round(Number(p.price) * (1 - Number(job.rules.parts_disc || 0) / 100) * 100) / 100);
  const labor = Math.round(hours * rate * 100) / 100;
  const partsTotal = parts.reduce((t, p) => t + p.qty * p.price, 0);
  const amount = Math.round((labor + partsTotal) * 100) / 100;
  const newLimit = (m.limit || 0) + amount;
  const emergencyOk = m.emergencyLimit != null && newLimit <= m.emergencyLimit;
  const found = q ? cat.parts.filter((p) => `${p.name} ${p.sku}`.toLowerCase().includes(q.toLowerCase())).slice(0, 20) : [];
  const needPhoto = job.wo.priority === 1;
  const send = () => {
    T.act('request_quote', { p_wo: job.wo.id, p_hours: hours, p_parts: parts.map((p) => ({ part_id: p.part_id, qty: p.qty })), p_description: why,
      p_photo_ids: photo ? [photo] : null }, { label: 'Request for more', amount });
    onClose();
  };
  return (
    <div className="sec" style={{ borderColor: 'var(--brand)' }}>
      <h3>Request approval for more</h3>
      <div className="spread"><span>Labor hours needed</span>
        <div className="stepper"><button onClick={() => setHours(Math.max(0, hours - 0.5))}>−</button><span>{hours}</span><button onClick={() => setHours(hours + 0.5)}>+</button></div></div>
      <div className="small muted">{hours} h × {money(rate)}/h = {money(labor)}{rate === 0 ? ' (labor covered by the agreement)' : ''}</div>
      {parts.map((p, i) => (
        <div key={p.part_id} className="spread small">
          <span>{p.name} × {p.qty}</span>
          <span>{money(p.qty * p.price)} <button onClick={() => setParts(parts.filter((_, k) => k !== i))}>✕</button></span>
        </div>
      ))}
      <input placeholder="Add a part to the quote…" value={q} onChange={(e) => setQ(e.target.value)} />
      {found.length > 0 && <div className="pick">{found.map((p) => (
        <button key={p.id} onClick={() => { setParts([...parts.filter((x) => x.part_id !== p.id), { part_id: p.id, name: p.name, qty: 1, price: price(p) }]); setQ(''); }}>
          <span>{p.name}</span><span>{money(price(p))}</span></button>))}</div>}
      <label>What's wrong and what you'll do (the customer reads this)
        <textarea value={why} onChange={(e) => setWhy(e.target.value)} placeholder="e.g. Contactor burned — replace and test" /></label>
      <Camera job={job} kind="other" label={photo ? 'Photo ✓' : `Photo of the problem${needPhoto ? ' (required)' : ''}`} onTaken={setPhoto} />
      <div className="notice"><strong>Not to exceed {money(amount)}</strong> — labor {money(labor)} + parts {money(partsTotal)}. The job's limit becomes {money(newLimit)}.
        {emergencyOk && <div>Emergency: this is within the customer's pre-approved {money(m.emergencyLimit)} — you can continue right away.</div>}</div>
      <button className="primary big" disabled={amount <= 0 || why.trim().length < 5 || (needPhoto && !photo)} onClick={send}>{emergencyOk ? 'Send — continue under emergency limit' : 'Send for approval'}</button>
      <button onClick={onClose}>Cancel</button>
    </div>
  );
}

function Finish({ job, cat, m, eqDone }) {
  const [mode, setMode] = useState(null);
  const [note, setNote] = useState('');
  const [need, setNeed] = useState({ part_id: '', description: '', quantity: 1, supplier: '', expected_on: '' });
  const w = job.wo; const v = job.visit;
  const kinds = new Set(job.photos.map((p) => p.kind));
  const missing = [];
  if (w.kind === 'service' || w.kind === 'install') {
    if (!eqDone) missing.push('Confirm the equipment (with nameplate photo)');
    if (!kinds.has('before')) missing.push('Before photo');
    if (!kinds.has('after')) missing.push('After photo');
    if (!w.repair_type_id) missing.push('Repair performed');
    if (!job.parts.length && !w.no_parts_used) missing.push('Parts used (or "No parts used")');
  }
  if (w.kind === 'pm') {
    (w.checklist || []).forEach((it, i) => { if (it.required !== false && !w.checklist_results?.[String(i)]?.done) missing.push(`PM: ${it.item}`); });
  }
  // Leaving for parts / a return / an approval still needs the basics on record.
  const leaveMissing = [];
  if (v.checkin_required && !(v.checkin_verified || v.checkin_local)) leaveMissing.push('Check in with the store');
  if (w.kind === 'service' || w.kind === 'install') {
    if (!eqDone) leaveMissing.push('Confirm the equipment (with nameplate photo)');
    if (!kinds.has('before')) leaveMissing.push('Before photo');
  }
  if (m.pending) missing.push(`Approval for ${m.pending.po} is still pending`);
  if (m.limit != null && m.used > m.limit) missing.push(`Cost ${money(m.used)} is over the approved ${money(m.limit)} — request more`);

  async function finish(outcome, extra = {}) {
    T.act('tech_finish_visit', { p_visit: v.id, p_outcome: outcome, p_note: note || null, ...extra }, { label: 'Finish visit' });
    const p = await T.position(4000);
    T.act('tech_depart', { p_visit: v.id, p_lat: p?.lat ?? null, p_lon: p?.lon ?? null }, { label: 'Left site' });
    setMode(null);
  }

  return (
    <div className="sec">
      <h3>Finish this visit</h3>
      {!mode && (
        <>
          {missing.length > 0 && <div className="small"><strong>Before you can complete:</strong><ul style={{ margin: '4px 0 0 18px', padding: 0 }}>{missing.map((x) => <li key={x}>{x}</li>)}</ul></div>}
          <button className="primary big" disabled={missing.length > 0} onClick={() => window.confirm('Complete the job? The store will be told the work is done.') && finish('completed')}>✓ Job complete</button>
          {leaveMissing.length > 0 && <div className="small muted">To leave without completing, first: {leaveMissing.join(' · ')}</div>}
          <div className="row" style={{ gap: 8 }}>
            <button style={{ flex: 1 }} disabled={leaveMissing.length > 0} onClick={() => setMode('parts')}>Parts needed</button>
            <button style={{ flex: 1 }} disabled={leaveMissing.length > 0} onClick={() => setMode('return')}>Return needed</button>
            {m.pending && <button style={{ flex: 1 }} disabled={leaveMissing.length > 0} onClick={() => setMode('quote')}>Quote sent — leaving</button>}
          </div>
        </>
      )}
      {mode === 'parts' && (
        <>
          <label>Part
            <select value={need.part_id} onChange={(e) => setNeed({ ...need, part_id: e.target.value })}>
              <option value="">Not on the list (describe below)</option>
              {cat.parts.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
            </select>
          </label>
          {!need.part_id && <label>Description<input value={need.description} onChange={(e) => setNeed({ ...need, description: e.target.value })} /></label>}
          <div className="row">
            <label className="grow">Qty<input type="number" min="1" value={need.quantity} onChange={(e) => setNeed({ ...need, quantity: e.target.value })} /></label>
            <label className="grow">Supplier<input value={need.supplier} onChange={(e) => setNeed({ ...need, supplier: e.target.value })} /></label>
          </div>
          <label>Expected date<input type="date" value={need.expected_on} onChange={(e) => setNeed({ ...need, expected_on: e.target.value })} /></label>
          <label>Note<input value={note} onChange={(e) => setNote(e.target.value)} placeholder="e.g. Motor not on truck" /></label>
          <button className="primary big" disabled={!need.part_id && !need.description.trim()} onClick={() => finish('parts_needed', {
            p_parts: [{ part_id: need.part_id || null, description: need.description || null, quantity: Number(need.quantity) || 1,
              supplier: need.supplier || null, expected_on: need.expected_on || null }] })}>Leave — waiting for parts</button>
          <button onClick={() => setMode(null)}>Back</button>
        </>
      )}
      {mode === 'return' && (
        <>
          <label>Why is a return visit needed?<textarea value={note} onChange={(e) => setNote(e.target.value)} /></label>
          <button className="primary big" disabled={note.trim().length < 5} onClick={() => finish('return_needed')}>Leave — return visit needed</button>
          <button onClick={() => setMode(null)}>Back</button>
        </>
      )}
      {mode === 'quote' && (
        <>
          <div className="small">The equipment is safe and you're leaving while {m.pending?.po} waits for approval. The office schedules the return once it's approved.</div>
          <label>Note<input value={note} onChange={(e) => setNote(e.target.value)} placeholder="e.g. Unit running on backup; no answer from store" /></label>
          <button className="primary big" onClick={() => finish('quote_needed')}>Leave — waiting on approval</button>
          <button onClick={() => setMode(null)}>Back</button>
        </>
      )}
    </div>
  );
}

function Done({ job }) {
  const v = job.visit;
  const label = { completed: 'Job complete', parts_needed: 'Waiting for parts', return_needed: 'Return visit needed', quote_needed: 'Waiting on approval' }[v.outcome] || 'Visit finished';
  return (
    <div className="sec">
      <h3><span className="tick on">✓</span>{label}</h3>
      <div className="small muted">Finished {time(v.completed_at)}{v.departed_at ? ` · left ${time(v.departed_at)}` : ''}</div>
      {!v.departed_at && <button onClick={async () => { const p = await T.position(4000); T.act('tech_depart', { p_visit: v.id, p_lat: p?.lat ?? null, p_lon: p?.lon ?? null }, { label: 'Left site' }); }}>I'm leaving the site</button>}
    </div>
  );
}

function Background({ job }) {
  const [open, setOpen] = useState(false);
  return (
    <div className="sec">
      <button onClick={() => setOpen(!open)} style={{ textAlign: 'left' }}>{open ? '▾' : '▸'} Equipment & history at this site</button>
      {open && (
        <>
          {job.equipment.map((e) => <div key={e.id} className="small"><strong>{e.type}</strong> — {e.manufacturer} {e.model} · S/N {e.serial}{e.location ? ` · ${e.location}` : ''}{e.refrigerant ? ` · ${e.refrigerant}` : ''}</div>)}
          {job.history.length === 0 && <div className="small muted">No earlier calls on record.</div>}
          {job.history.map((h) => <div key={h.number} className="small"><strong>#{h.number}</strong> {date(h.date)} — {h.summary}</div>)}
          {job.po_lines.length > 0 && <div className="small muted">Approvals: {job.po_lines.map((l) => `${l.po} ${money(l.amount)} ${l.status}${l.emergency ? ' (emergency)' : ''}`).join(' · ')}</div>}
        </>
      )}
    </div>
  );
}
