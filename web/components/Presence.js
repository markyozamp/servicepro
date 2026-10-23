'use client';

// Store: who's in the building right now, who's expected today, and logging someone we weren't expecting.
import { useCallback, useEffect, useState } from 'react';
import { supabase, act, q } from '@/lib/supabase';
import { time, dateTime } from '@/lib/format';
import { ErrorBox, Notice } from './bits';

// Shrink a phone photo before upload (faster on store Wi-Fi, smaller to keep).
async function shrink(file) {
  const img = await createImageBitmap(file);
  const k = Math.min(1, 1280 / Math.max(img.width, img.height));
  const c = document.createElement('canvas');
  c.width = Math.round(img.width * k); c.height = Math.round(img.height * k);
  c.getContext('2d').drawImage(img, 0, 0, c.width, c.height);
  return new Promise((res) => c.toBlob(res, 'image/jpeg', 0.72));
}
const telOf = (p) => (p || '').replace(/[^0-9+]/g, '');

const SEL = `id, status, arrived_at, scheduled_start, scheduled_end, missed_alert_at, visit_no, checkin_at, checkin_verified, crew_helpers,
  profiles(full_name), work_orders(id, site_id, number, unit, issue_description, store_po_number, sites(id, name), contractors(name),
  equipment(location_description, equipment_types(name)))`;

export default function Presence({ onOpen, refreshKey, siteId }) {
  const [inside, setInside] = useState([]);
  const [expected, setExpected] = useState([]);
  const [visitors, setVisitors] = useState([]);
  const [form, setForm] = useState(null);
  const [sites, setSites] = useState([]);
  const [cc, setCc] = useState([]);
  const [err, setErr] = useState('');
  const [msg, setMsg] = useState('');
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    try {
      const day0 = new Date(); day0.setHours(0, 0, 0, 0);
      const day1 = new Date(day0.getTime() + 86400000);
      const [a, b, c] = await Promise.all([
        q(supabase.from('visits').select(SEL).eq('status', 'on_site').order('arrived_at')),
        q(supabase.from('visits').select(SEL).in('status', ['assigned', 'en_route']).lt('scheduled_start', day1.toISOString()).order('scheduled_start')),
        q(supabase.from('site_visitors').select('id, site_id, visitor_name, company, note, recorded_at, vehicle_plate, photo_path, resolved_at, resolved_note, sites(name), contractors(name, phone)').gte('recorded_at', day0.toISOString()).order('recorded_at', { ascending: false })),
      ]);
      const keep = (x) => !siteId || x.work_orders?.site_id === siteId;
      setInside(a.filter(keep)); setExpected(b.filter(keep)); setVisitors(c.filter((x) => !siteId || x.site_id === siteId));
    } catch (e) { setErr(e.message); }
  }, [siteId]);
  useEffect(() => { load(); }, [load, refreshKey]);

  async function openForm() {
    setForm({ site: '', name: '', contractor: '', company: '', note: '', plate: '', photo: null });
    try {
      const [s, c] = await Promise.all([q(supabase.from('sites').select('id, name, customer_id, visitor_require_plate, visitor_require_photo').order('name')),
        q(supabase.from('customer_contractors').select('contractor_id, contractors(name, phone)'))]);
      setSites(s); setCc(c);
      if (s.length === 1 || siteId) setForm((f) => ({ ...f, site: siteId || s[0].id }));
    } catch (e) { setErr(e.message); }
  }

  async function save(e) {
    e.preventDefault();
    setBusy(true); setErr('');
    try {
      const st = sites.find((x) => x.id === form.site);
      let path = null;
      if (form.photo) {
        const blob = await shrink(form.photo);
        path = `${st.customer_id}/${crypto.randomUUID()}.jpg`;
        const up = await supabase.storage.from('visitor-photos').upload(path, blob, { contentType: 'image/jpeg', upsert: false });
        if (up.error) throw new Error(`Photo didn't upload: ${up.error.message}`);
      }
      await act('store_visitor_log', { p_site: form.site, p_name: form.name, p_contractor: form.contractor || null,
        p_company: form.company || null, p_note: form.note || null, p_plate: form.plate || null, p_photo_path: path });
      setMsg(`Recorded. ${form.contractor ? 'Their office and ' : ''}your people have been told.`); setForm(null); await load();
    } catch (x) { setErr(x.message); } finally { setBusy(false); }
  }

  async function showPhoto(path) {
    const { data, error } = await supabase.storage.from('visitor-photos').createSignedUrl(path, 300);
    if (error) return setErr(error.message);
    window.open(data.signedUrl, '_blank', 'noopener');
  }

  const site = form && sites.find((x) => x.id === form.site);
  const office = form && cc.find((c) => c.contractor_id === form.contractor)?.contractors;

  const label = (v) => {
    const w = v.work_orders || {};
    const eq = w.equipment ? [w.equipment.equipment_types?.name, w.equipment.location_description].filter(Boolean).join(' — ') : null;
    return `${w.sites?.name || ''}${w.unit ? `, unit ${w.unit}` : ''} · ${eq || w.issue_description || ''}`;
  };

  return (
    <div className="panel panel-pad stack" id="presence" style={{ gap: 10 }}>
      <ErrorBox error={err} /><Notice>{msg}</Notice>
      <div className="spread">
        <h3>In the building now {inside.length > 0 && <span className="chip tone-green">{inside.length}</span>}</h3>
        {!form && <button onClick={openForm}>Someone's here we weren't expecting</button>}
      </div>
      {inside.length === 0 && <div className="small muted">No contractor technicians checked in right now.</div>}
      {inside.map((v) => (
        <div key={v.id} className="spread small click" style={{ cursor: 'pointer' }} onClick={() => onOpen(v.work_orders?.id)}>
          <span><strong>{v.profiles?.full_name}</strong>{v.crew_helpers > 0 ? ` + ${v.crew_helpers === 1 ? '1 helper' : `${v.crew_helpers} helpers`}` : ''} ({v.work_orders?.contractors?.name}) — {label(v)}</span>
          <span className="muted">since {time(v.arrived_at)}{v.checkin_at ? (v.checkin_verified ? ' · checked in' : ' · check-in NOT verified') : ' · waiting for code'}</span>
        </div>
      ))}

      {form && (
        <form className="stack" style={{ gap: 6, background: 'var(--bg)', borderRadius: 8, padding: 10 }} onSubmit={save}>
          <strong>Log an unexpected visitor</strong>
          <div className="small muted">Someone from a contractor is here with no trip scheduled. This records it and tells your people and their office.</div>
          <div className="row">
            <label className="grow">Location<select value={form.site} onChange={(e) => setForm({ ...form, site: e.target.value })} required>
              <option value="">Choose…</option>{sites.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</select></label>
            <label className="grow">Their name<input value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} required /></label>
          </div>
          <div className="row">
            <label className="grow">Company<select value={form.contractor} onChange={(e) => setForm({ ...form, contractor: e.target.value })}>
              <option value="">Other / not one of ours</option>{cc.map((c) => <option key={c.contractor_id} value={c.contractor_id}>{c.contractors?.name}</option>)}</select></label>
            {!form.contractor && <label className="grow">Company name<input value={form.company} onChange={(e) => setForm({ ...form, company: e.target.value })} /></label>}
          </div>
          {office?.phone && (
            <a className="callbtn" href={`tel:${telOf(office.phone)}`}>📞 Call {office.name}'s office · {office.phone}</a>
          )}
          {office && !office.phone && <div className="small muted">No office phone on file for {office.name}.</div>}
          <input value={form.note} onChange={(e) => setForm({ ...form, note: e.target.value })} placeholder="What are they doing? (optional)" />
          <div className="row">
            <label className="grow">Vehicle plate {site?.visitor_require_plate ? <span className="chip tone-amber">required here</span> : <span className="muted" style={{ fontWeight: 400 }}>(optional)</span>}
              <input value={form.plate} onChange={(e) => setForm({ ...form, plate: e.target.value })} required={!!site?.visitor_require_plate} placeholder="e.g. ND 123-ABC" /></label>
            <label className="grow">Photo {site?.visitor_require_photo ? <span className="chip tone-amber">required here</span> : <span className="muted" style={{ fontWeight: 400 }}>(optional: person, badge or vehicle)</span>}
              <input type="file" accept="image/*" capture="environment" onChange={(e) => setForm({ ...form, photo: e.target.files?.[0] || null })} required={!!site?.visitor_require_photo} /></label>
          </div>
          <div className="row"><button className="primary" disabled={busy}>Record it</button><button type="button" onClick={() => setForm(null)}>Cancel</button></div>
        </form>
      )}

      <h3>Expected today {expected.length > 0 && <span className="chip tone-blue">{expected.length}</span>}</h3>
      {expected.length === 0 && <div className="small muted">No trips scheduled for today.</div>}
      {expected.map((v) => (
        <div key={v.id} className="spread small click" style={{ cursor: 'pointer' }} onClick={() => onOpen(v.work_orders?.id)}>
          <span><strong>{v.profiles?.full_name}</strong> ({v.work_orders?.contractors?.name}) — {label(v)}{v.visit_no > 1 ? ' · return trip' : ''}</span>
          <span>{v.status === 'en_route' ? <span className="chip tone-amber">on the way</span>
            : v.missed_alert_at ? <span className="chip tone-red">missed {time(v.scheduled_end || v.scheduled_start)}</span>
            : <span className="muted">{v.scheduled_start ? `${time(v.scheduled_start)}${v.scheduled_end ? `–${time(v.scheduled_end)}` : ''}` : ''}</span>}</span>
        </div>
      ))}
      {visitors.length > 0 && (
        <div className="stack" style={{ gap: 4 }}>
          <div className="small" style={{ color: visitors.some((x) => !x.resolved_at) ? 'var(--red-fg)' : 'var(--muted, #777)', fontWeight: 700 }}>Unscheduled today</div>
          {visitors.map((x) => (
            <div key={x.id} id={`visitor-${x.id}`} className={`spread small${x.resolved_at ? ' muted' : ''}`} style={{ gap: 8 }}>
              <span>{x.visitor_name} ({x.company}) at {x.sites?.name}, {dateTime(x.recorded_at)}{x.vehicle_plate ? ` · plate ${x.vehicle_plate}` : ''}{x.note ? ` · ${x.note}` : ''}
                {x.resolved_at && <> · <strong style={{ color: 'var(--green-fg)' }}>✓ taken care of {dateTime(x.resolved_at)}</strong></>}</span>
              <span className="row" style={{ gap: 6 }}>
                {x.photo_path && <button onClick={() => showPhoto(x.photo_path)}>Photo</button>}
                {!x.resolved_at && x.contractors?.phone && <a className="callbtn small" href={`tel:${telOf(x.contractors.phone)}`}>📞 Call office</a>}
                {!x.resolved_at && (
                  <button className="small" onClick={async () => {
                    try { await act('store_resolve_visitor', { p_id: x.id }); load(); } catch (e) { setErr(e.message); }
                  }}>✓ Taken care of</button>
                )}
              </span>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
