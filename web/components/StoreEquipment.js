'use client';

// Settings → Equipment: the store's own list of units by location, with warranties. Each unit gets a QR sticker.
import { useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import { supabase, act, q } from '@/lib/supabase';
import { date } from '@/lib/format';
import { ErrorBox, Notice } from './bits';
import Info from './Info';

const blank = (site) => ({ id: null, site, type: '', make: '', model: '', serial: '', refrigerant: '', where: '', installed: '' });

export default function StoreEquipment() {
  const router = useRouter();
  const [rows, setRows] = useState([]);
  const [sites, setSites] = useState([]);
  const [types, setTypes] = useState([]);
  const [site, setSite] = useState('');
  const [form, setForm] = useState(null);
  const [war, setWar] = useState(null);
  const [err, setErr] = useState('');
  const [msg, setMsg] = useState('');
  const [busy, setBusy] = useState(false);

  async function load() {
    try {
      const [e, s, t] = await Promise.all([
        q(supabase.from('equipment').select('id, site_id, manufacturer, model, serial, refrigerant, location_description, install_date, equipment_types(code, name), warranties(kind, ends_on, description)').order('created_at')),
        q(supabase.from('sites').select('id, name').order('name')),
        q(supabase.from('equipment_types').select('code, name').is('contractor_id', null).order('name')),
      ]);
      setRows(e); setSites(s); setTypes(t);
      if (!site && s.length === 1) setSite(s[0].id);
    } catch (x) { setErr(x.message); }
  }
  useEffect(() => { load(); }, []); // eslint-disable-line react-hooks/exhaustive-deps

  const set = (k) => (e) => setForm({ ...form, [k]: e.target.value });
  async function save(e) {
    e.preventDefault();
    setBusy(true); setErr(''); setMsg('');
    try {
      await act('save_equipment', { p_id: form.id, p_site: form.site, p_type_code: form.type || null, p_manufacturer: form.make, p_model: form.model,
        p_serial: form.serial, p_location: form.where, p_install_date: form.installed || null, p_refrigerant: form.refrigerant });
      setMsg(form.id ? 'Saved.' : 'Added. It now has its own QR sticker.'); setForm(null); await load();
    } catch (x) { setErr(x.message); } finally { setBusy(false); }
  }
  async function saveWarranty(e) {
    e.preventDefault();
    setBusy(true); setErr(''); setMsg('');
    try {
      await act('add_equipment_warranty', { p_equipment: war.id, p_kind: war.kind, p_starts: war.starts || null, p_ends: war.ends || null, p_description: war.desc });
      setMsg('Warranty saved. You\'ll be warned when you open a call on this unit while it\'s covered.'); setWar(null); await load();
    } catch (x) { setErr(x.message); } finally { setBusy(false); }
  }

  const shown = rows.filter((r) => !site || r.site_id === site);
  const siteName = (id) => sites.find((s) => s.id === id)?.name || '';
  const today = new Date().toISOString().slice(0, 10);
  return (
    <div className="stack">
      <div className="spread">
        <h3>Equipment <Info title="Equipment">List each unit at each location: refrigeration cases, walk-ins, rooftop units, ice machines, water heaters and so on. When you open a call you pick the unit, so the history, the warranty and the right contractor follow it. Each unit gets its own QR sticker employees can scan to report a problem. You don't have to list everything on day one: your contractors add units on their visits too.</Info></h3>
        <div className="row">
          {sites.length > 1 && <select value={site} onChange={(e) => setSite(e.target.value)}><option value="">All locations</option>{sites.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</select>}
          <button onClick={() => router.push('/store/stickers')}>QR stickers</button>
        </div>
      </div>
      <ErrorBox error={err} /><Notice>{msg}</Notice>

      <div className="notice small">
        <strong>Want it done for you?</strong> Service Call Proof can come on site to find, tag, label and list all your equipment, with photos of every nameplate. Quoted in advance. <strong>Contact us for a quote:</strong> support@servicecallproof.com
      </div>

      <table>
        <thead><tr><th>Unit</th><th className="hide-sm">Make / model / serial</th><th>Warranty</th><th /></tr></thead>
        <tbody>
          {shown.length === 0 && <tr><td colSpan={4} className="muted">No equipment listed{site ? ' for this location' : ''} yet.</td></tr>}
          {shown.map((r) => {
            const w = (r.warranties || []).filter((x) => x.ends_on >= today).sort((a, b) => b.ends_on.localeCompare(a.ends_on))[0];
            return (
              <tr key={r.id}>
                <td><strong>{r.equipment_types?.name || r.model || 'Unit'}</strong><div className="small muted">{r.location_description || ''}{sites.length > 1 ? ` · ${siteName(r.site_id)}` : ''}</div></td>
                <td className="hide-sm small">{[r.manufacturer, r.model].filter(Boolean).join(' ')}{r.serial ? <div className="muted">S/N {r.serial}</div> : null}</td>
                <td className="small">{w ? <span className="chip tone-green">{w.kind} until {date(w.ends_on)}</span> : <span className="muted">none on file</span>}</td>
                <td className="num"><div className="row" style={{ justifyContent: 'flex-end', gap: 6 }}>
                  <button onClick={() => { setWar(null); setForm({ id: r.id, site: r.site_id, type: r.equipment_types?.code || '', make: r.manufacturer || '', model: r.model || '', serial: r.serial || '', refrigerant: r.refrigerant || '', where: r.location_description || '', installed: r.install_date || '' }); }}>Edit</button>
                  <button onClick={() => { setForm(null); setWar({ id: r.id, kind: 'manufacturer', starts: r.install_date || '', ends: '', desc: '' }); }}>+ Warranty</button>
                </div></td>
              </tr>
            );
          })}
        </tbody>
      </table>

      {war && (
        <form className="stack" style={{ gap: 8, border: '1px solid var(--line)', borderRadius: 10, padding: 12 }} onSubmit={saveWarranty}>
          <h3>Add a warranty</h3>
          <div className="row">
            <label className="grow">Type<select value={war.kind} onChange={(e) => setWar({ ...war, kind: e.target.value })}>
              <option value="manufacturer">Manufacturer</option><option value="extended">Extended</option><option value="labor">Labor (installer)</option><option value="parts">Parts</option></select></label>
            <label className="grow">Starts<input type="date" value={war.starts} onChange={(e) => setWar({ ...war, starts: e.target.value })} /></label>
            <label className="grow">Ends<input type="date" value={war.ends} onChange={(e) => setWar({ ...war, ends: e.target.value })} required /></label>
          </div>
          <label>What it covers<input value={war.desc} onChange={(e) => setWar({ ...war, desc: e.target.value })} placeholder="e.g. Compressor 5 years, parts 1 year" /></label>
          <div className="row"><button className="primary" disabled={busy}>Save warranty</button><button type="button" onClick={() => setWar(null)}>Cancel</button></div>
        </form>
      )}

      {form ? (
        <form className="stack" style={{ gap: 8, border: '1px solid var(--line)', borderRadius: 10, padding: 12 }} onSubmit={save}>
          <h3>{form.id ? 'Edit unit' : 'Add a unit'}</h3>
          <div className="row">
            <label className="grow">Location<select value={form.site} onChange={set('site')} required><option value="">Choose…</option>{sites.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</select></label>
            <label className="grow">Type<select value={form.type} onChange={set('type')}><option value="">Choose…</option>{types.map((t) => <option key={t.code} value={t.code}>{t.name}</option>)}</select></label>
          </div>
          <label>Where is it? <span className="muted" style={{ fontWeight: 400 }}>— so a technician can find it</span><input value={form.where} onChange={set('where')} placeholder="e.g. Back wall of dairy, roof over produce" /></label>
          <div className="row">
            <label className="grow">Make<input value={form.make} onChange={set('make')} placeholder="e.g. Hussmann" /></label>
            <label className="grow">Model<input value={form.model} onChange={set('model')} /></label>
            <label className="grow">Serial number<input value={form.serial} onChange={set('serial')} /></label>
          </div>
          <div className="row">
            <label className="grow">Refrigerant <span className="muted" style={{ fontWeight: 400 }}>(if any)</span><input value={form.refrigerant} onChange={set('refrigerant')} placeholder="e.g. R-448A" /></label>
            <label className="grow">Installed<input type="date" value={form.installed} onChange={set('installed')} /></label>
          </div>
          <div className="small muted">Tip: the make, model and serial are on the nameplate sticker. A photo of it on your phone is enough to fill this in later.</div>
          <div className="row"><button className="primary" disabled={busy}>{form.id ? 'Save' : 'Add unit'}</button><button type="button" onClick={() => setForm(null)}>Cancel</button></div>
        </form>
      ) : <div><button onClick={() => { setWar(null); setForm(blank(site || (sites.length === 1 ? sites[0].id : ''))); }}>+ Add a unit</button></div>}
    </div>
  );
}
