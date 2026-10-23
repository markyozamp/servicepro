'use client';

// Settings → Equipment: the store's own list of units by location, with warranties. Each unit gets a QR sticker.
import { useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import { supabase, act, q } from '@/lib/supabase';
import { date, dateTime } from '@/lib/format';
import { ErrorBox, Notice } from './bits';
import Info from './Info';
import { usePlace } from '@/lib/terms';

const blank = (site) => ({ id: null, site, type: '', make: '', model: '', serial: '', refrigerant: '', where: '', installed: '' });

export default function StoreEquipment() {
  const place = usePlace();
  const router = useRouter();
  const [rows, setRows] = useState([]);
  const [sites, setSites] = useState([]);
  const [types, setTypes] = useState([]);
  const [site, setSite] = useState('');
  const [form, setForm] = useState(null);
  const [war, setWar] = useState(null);
  const [hist, setHist] = useState(null);       // { id, rows }
  const [rm, setRm] = useState(null);           // { id, reason }
  const [showRemoved, setShowRemoved] = useState(false);
  const [err, setErr] = useState('');
  const [msg, setMsg] = useState('');
  const [busy, setBusy] = useState(false);
  const [lease, setLease] = useState(null);

  async function load() {
    try {
      const [e, s, t] = await Promise.all([
        q(supabase.from('equipment').select('id, site_id, manufacturer, model, serial, refrigerant, location_description, install_date, created_at, updated_at, retired_at, retired_reason, lease_full, lease_company, lease_contact, lease_phone, lease_email, lease_note, equipment_types(code, name), warranties(kind, ends_on, description), equipment_log(action, at, by_name)').order('created_at')),
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

  async function saveLease(e) {
    e.preventDefault();
    setBusy(true); setErr(''); setMsg('');
    try {
      await act('set_equipment_lease', { p_equipment: lease.id, p_full: lease.full, p_company: lease.company, p_contact: lease.contact, p_phone: lease.phone, p_email: lease.email, p_note: lease.note });
      setMsg(lease.full ? `Saved. Opening a call on this unit now shows ${lease.company}'s contact first, and any bill for it is flagged.` : 'Saved. The unit is no longer marked as leased.');
      setLease(null); await load();
    } catch (x) { setErr(x.message); } finally { setBusy(false); }
  }

  async function openHistory(id) {
    if (hist?.id === id) return setHist(null);
    try { setHist({ id, rows: await q(supabase.from('equipment_log').select('action, at, by_name, detail').eq('equipment_id', id).order('at', { ascending: false })) }); }
    catch (x) { setErr(x.message); }
  }
  async function remove(e) {
    e.preventDefault();
    setBusy(true); setErr(''); setMsg('');
    try { await act('retire_equipment', { p_equipment: rm.id, p_reason: rm.reason, p_restore: false }); setMsg('Removed. It stays in the history and on past calls; "Show removed" brings it back.'); setRm(null); await load(); }
    catch (x) { setErr(x.message); } finally { setBusy(false); }
  }
  async function restore(id) {
    setBusy(true); setErr(''); setMsg('');
    try { await act('retire_equipment', { p_equipment: id, p_reason: null, p_restore: true }); setMsg('Restored.'); await load(); }
    catch (x) { setErr(x.message); } finally { setBusy(false); }
  }
  const stamp = (r) => {
    const log = [...(r.equipment_log || [])].sort((a, b) => b.at.localeCompare(a.at));
    const added = log.find((l) => l.action === 'added');
    const last = log.find((l) => l.action !== 'added');
    return [added ? `Added by ${added.by_name || 'someone'} ${date(added.at)}` : `Added ${date(r.created_at)}`, last ? `${last.action} by ${last.by_name || 'someone'} ${date(last.at)}` : null].filter(Boolean).join(' · ');
  };

  const shown = rows.filter((r) => (!site || r.site_id === site) && (showRemoved ? r.retired_at : !r.retired_at));
  const siteName = (id) => sites.find((s) => s.id === id)?.name || '';
  const today = new Date().toISOString().slice(0, 10);
  return (
    <div className="stack">
      <div className="spread">
        <h3>Equipment <Info title="Equipment">List each unit at each location: refrigeration cases, walk-ins, rooftop units, ice machines, water heaters and so on. When you open a call you pick the unit, so the history, the warranty and the right contractor follow it. Each unit gets its own QR sticker employees can scan to report a problem. You don't have to list everything on day one: your contractors add units on their visits too.</Info></h3>
        <div className="row">
          {sites.length > 1 && <select value={site} onChange={(e) => setSite(e.target.value)}><option value="">All {place.many}</option>{sites.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</select>}
          <label className="row small" style={{ gap: 4, fontWeight: 400 }}><input type="checkbox" style={{ width: 'auto' }} checked={showRemoved} onChange={(e) => setShowRemoved(e.target.checked)} />Show removed</label>
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
            return [
              <tr key={r.id}>
                <td><strong>{r.equipment_types?.name || r.model || 'Unit'}</strong><div className="small muted">{r.location_description || ''}{sites.length > 1 ? ` · ${siteName(r.site_id)}` : ''}</div>
                  <div className="small muted">{r.retired_at ? `Removed ${date(r.retired_at)}: ${r.retired_reason || ''}` : stamp(r)}</div></td>
                <td className="hide-sm small">{[r.manufacturer, r.model].filter(Boolean).join(' ')}{r.serial ? <div className="muted">S/N {r.serial}</div> : null}</td>
                <td className="small">{w ? <span className="chip tone-green">{w.kind} until {date(w.ends_on)}</span> : !r.lease_full && <span className="muted">none on file</span>}
                  {r.lease_full && <div><span className="chip tone-amber">Leased · {r.lease_company}</span><div className="muted">full coverage{r.lease_phone ? ` · ${r.lease_phone}` : ''}</div></div>}</td>
                <td className="num"><div className="row" style={{ justifyContent: 'flex-end', gap: 6 }}>
                  <button onClick={() => openHistory(r.id)}>{hist?.id === r.id ? 'Hide history' : 'History'}</button>
                  {r.retired_at ? <button disabled={busy} onClick={() => restore(r.id)}>Restore</button> : <>
                  <button onClick={() => { setWar(null); setForm({ id: r.id, site: r.site_id, type: r.equipment_types?.code || '', make: r.manufacturer || '', model: r.model || '', serial: r.serial || '', refrigerant: r.refrigerant || '', where: r.location_description || '', installed: r.install_date || '' }); }}>Edit</button>
                  <button onClick={() => { setForm(null); setWar({ id: r.id, kind: 'manufacturer', starts: r.install_date || '', ends: '', desc: '' }); }}>+ Warranty</button>
                  <button onClick={() => { setForm(null); setWar(null); setLease({ id: r.id, full: r.lease_full || true, company: r.lease_company || '', contact: r.lease_contact || '', phone: r.lease_phone || '', email: r.lease_email || '', note: r.lease_note || '', name: r.equipment_types?.name || r.model || 'this unit' }); }}>{r.lease_full ? 'Lease' : '+ Leased'}</button>
                  <button onClick={() => { setForm(null); setWar(null); setRm({ id: r.id, reason: '' }); }}>Remove</button></>}
                </div></td>
              </tr>,
              hist?.id === r.id && (
                <tr key={`${r.id}-h`}><td colSpan={4}>
                  <div className="small stack" style={{ gap: 2 }}>
                    {hist.rows.length === 0 && <span className="muted">No history recorded yet (added before history was kept).</span>}
                    {hist.rows.map((h, i) => <span key={i}><strong>{h.action}</strong> by {h.by_name || 'someone'}, {dateTime(h.at)}{h.detail ? ` — ${h.detail}` : ''}</span>)}
                  </div>
                </td></tr>
              ),
              rm?.id === r.id && (
                <tr key={`${r.id}-r`}><td colSpan={4}>
                  <form className="row" onSubmit={remove}>
                    <input className="grow" value={rm.reason} onChange={(e) => setRm({ ...rm, reason: e.target.value })} placeholder={`Why? e.g. replaced with new unit, scrapped, moved to another ${place.one}`} required />
                    <button className="danger" disabled={busy}>Remove unit</button><button type="button" onClick={() => setRm(null)}>Cancel</button>
                  </form>
                </td></tr>
              ),
            ];
          })}
        </tbody>
      </table>

      {lease && (
        <form className="stack" style={{ gap: 8, border: '1px solid var(--line)', borderRadius: 10, padding: 12 }} onSubmit={saveLease}>
          <h3>Leased or rented with full coverage</h3>
          <div className="small muted">For a unit you lease or rent (for example an ice machine from an ice company) where the lease covers all maintenance and repairs. When someone opens a call on {lease.name}, they see the lease company&apos;s contact first, and a bill from your contractor on it is flagged so you don&apos;t pay for covered work.</div>
          <label className="row" style={{ gap: 6, fontWeight: 400 }}><input type="checkbox" style={{ width: 'auto' }} checked={lease.full} onChange={(e) => setLease({ ...lease, full: e.target.checked })} />
            Leased / rental with 100% maintenance and repair coverage</label>
          {lease.full && (
            <>
              <div className="row">
                <label className="grow">Leased from (company)<input value={lease.company} onChange={(e) => setLease({ ...lease, company: e.target.value })} placeholder="e.g. Acme Ice Company" required /></label>
                <label className="grow">Contact name<input value={lease.contact} onChange={(e) => setLease({ ...lease, contact: e.target.value })} /></label>
              </div>
              <div className="row">
                <label className="grow">Service phone<input type="tel" value={lease.phone} onChange={(e) => setLease({ ...lease, phone: e.target.value })} /></label>
                <label className="grow">Email<input type="email" value={lease.email} onChange={(e) => setLease({ ...lease, email: e.target.value })} /></label>
              </div>
              <label>Note <span className="muted" style={{ fontWeight: 400 }}>(optional)</span><input value={lease.note} onChange={(e) => setLease({ ...lease, note: e.target.value })} placeholder="e.g. Account #4411, lease ends 2028" /></label>
            </>
          )}
          <div className="row"><button className="primary" disabled={busy}>Save</button><button type="button" onClick={() => setLease(null)}>Cancel</button></div>
        </form>
      )}

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
