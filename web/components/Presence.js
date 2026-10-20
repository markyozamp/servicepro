'use client';

// Store: who's in the building right now, who's expected today, and logging someone we weren't expecting.
import { useCallback, useEffect, useState } from 'react';
import { supabase, act, q } from '@/lib/supabase';
import { time, dateTime } from '@/lib/format';
import { ErrorBox, Notice } from './bits';

const SEL = `id, status, arrived_at, scheduled_start, scheduled_end, missed_alert_at, visit_no, checkin_at, checkin_verified,
  profiles(full_name), work_orders(id, number, unit, issue_description, store_po_number, sites(id, name), contractors(name),
  equipment(location_description, equipment_types(name)))`;

export default function Presence({ onOpen, refreshKey }) {
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
        q(supabase.from('site_visitors').select('id, visitor_name, company, note, recorded_at, sites(name)').gte('recorded_at', day0.toISOString()).order('recorded_at', { ascending: false })),
      ]);
      setInside(a); setExpected(b); setVisitors(c);
    } catch (e) { setErr(e.message); }
  }, []);
  useEffect(() => { load(); }, [load, refreshKey]);

  async function openForm() {
    setForm({ site: '', name: '', contractor: '', company: '', note: '' });
    try {
      const [s, c] = await Promise.all([q(supabase.from('sites').select('id, name').order('name')),
        q(supabase.from('customer_contractors').select('contractor_id, contractors(name)'))]);
      setSites(s); setCc(c);
      if (s.length === 1) setForm((f) => ({ ...f, site: s[0].id }));
    } catch (e) { setErr(e.message); }
  }

  async function save(e) {
    e.preventDefault();
    setBusy(true); setErr('');
    try {
      await act('store_unexpected_visitor', { p_site: form.site, p_name: form.name, p_contractor: form.contractor || null,
        p_company: form.company || null, p_note: form.note || null });
      setMsg(`Recorded. ${form.contractor ? 'Their office and ' : ''}your people have been told.`); setForm(null); await load();
    } catch (x) { setErr(x.message); } finally { setBusy(false); }
  }

  const label = (v) => {
    const w = v.work_orders || {};
    const eq = w.equipment ? [w.equipment.equipment_types?.name, w.equipment.location_description].filter(Boolean).join(' — ') : null;
    return `${w.sites?.name || ''}${w.unit ? `, unit ${w.unit}` : ''} · ${eq || w.issue_description || ''}`;
  };

  return (
    <div className="panel panel-pad stack" style={{ gap: 10 }}>
      <ErrorBox error={err} /><Notice>{msg}</Notice>
      <div className="spread">
        <h3>In the building now {inside.length > 0 && <span className="chip tone-green">{inside.length}</span>}</h3>
        {!form && <button onClick={openForm}>Someone's here we weren't expecting</button>}
      </div>
      {inside.length === 0 && <div className="small muted">No contractor technicians checked in right now.</div>}
      {inside.map((v) => (
        <div key={v.id} className="spread small click" style={{ cursor: 'pointer' }} onClick={() => onOpen(v.work_orders?.id)}>
          <span><strong>{v.profiles?.full_name}</strong> ({v.work_orders?.contractors?.name}) — {label(v)}</span>
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
          <input value={form.note} onChange={(e) => setForm({ ...form, note: e.target.value })} placeholder="What are they doing? (optional)" />
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
        <div className="small" style={{ color: 'var(--red-fg)' }}>Unscheduled today: {visitors.map((x) => `${x.visitor_name} (${x.company}) at ${x.sites?.name}, ${dateTime(x.recorded_at)}`).join('; ')}</div>
      )}
    </div>
  );
}
