'use client';

// Location settings a store's admin controls: emergency pre-approval, guest Wi-Fi for technicians,
// and the standing backup check-in code.
import { useEffect, useState } from 'react';
import { supabase, act, q } from '@/lib/supabase';
import { money } from '@/lib/format';
import { ErrorBox, Notice } from './bits';
import AddressFinder from './AddressFinder';
import Info from './Info';
import { dateTime } from '@/lib/format';

export default function LocationSettings({ onClose, startAdding, onChanged }) {
  const [rows, setRows] = useState([]);
  const [err, setErr] = useState('');
  const [msg, setMsg] = useState('');
  const [busy, setBusy] = useState(false);
  const [adding, setAdding] = useState(startAdding ? { name: '', addr: '' } : null);
  const [found, setFound] = useState(null);
  const [edit, setEdit] = useState(null);
  const [efound, setEfound] = useState(null);

  async function load() {
    try {
      const [sites, wifi] = await Promise.all([
        q(supabase.from('sites').select('id, name, address, emergency_limit, lat, lon, timezone, backup_code_set_at, backup_code_set_by_name, visitor_require_plate, visitor_require_photo').order('name')),
        q(supabase.from('site_wifi').select('site_id, ssid, password')),
      ]);
      setRows(sites.map((s) => {
        const w = wifi.find((x) => x.site_id === s.id);
        return { ...s, em: s.emergency_limit ?? '', ssid: w?.ssid || '', pw: w?.password || '', backup: '' };
      }));
    } catch (e) { setErr(e.message); }
  }
  useEffect(() => { load(); }, []);

  const set = (id, k) => (e) => setRows(rows.map((r) => (r.id === id ? { ...r, [k]: e.target.value } : r)));

  async function save(r) {
    setBusy(true); setErr(''); setMsg('');
    try {
      await act('set_site_settings', { p_site: r.id, p_emergency_limit: r.em === '' ? null : Number(r.em), p_wifi_ssid: r.ssid, p_wifi_password: r.pw });
      if (r.backup.trim()) await act('set_backup_code', { p_site: r.id, p_code: r.backup.trim() });
      setMsg(`Saved ${r.name}.`);
      await load();
    } catch (e) { setErr(e.message); } finally { setBusy(false); }
  }

  async function visitorRule(r, k, v) {
    setBusy(true); setErr(''); setMsg('');
    try {
      await act('set_visitor_rules', { p_site: r.id, p_require_plate: k === 'plate' ? v : r.visitor_require_plate, p_require_photo: k === 'photo' ? v : r.visitor_require_photo });
      setMsg(`Saved ${r.name}.`); await load();
    } catch (x) { setErr(x.message); } finally { setBusy(false); }
  }

  async function saveEdit(e) {
    e.preventDefault();
    setBusy(true); setErr(''); setMsg('');
    try {
      await act('update_location', { p_site: edit.id, p_name: edit.name, p_address: efound?.address || null, p_zip: efound?.zip || null,
        p_lat: efound?.lat ?? null, p_lon: efound?.lon ?? null, p_timezone: efound?.timezone || null });
      setMsg(`Saved ${edit.name}.`); setEdit(null); setEfound(null); await load();
    } catch (x) { setErr(x.message); } finally { setBusy(false); }
  }

  async function addLocation(e) {
    e.preventDefault();
    setErr(''); setMsg('');
    if (!found) return setErr('Tap Find next to the address first.');
    setBusy(true);
    try {
      const r = await act('add_location', { p_name: adding.name, p_address: found.address, p_zip: found.zip, p_lat: found.lat, p_lon: found.lon, p_timezone: found.timezone });
      setMsg(`Added ${adding.name}. You now have ${r.locations} locations.`);
      setAdding(null); setFound(null);
      await load(); onChanged?.();
    } catch (x) { setErr(x.message); } finally { setBusy(false); }
  }

  function hereNow(r) {
    setErr(''); setMsg('');
    if (!navigator.geolocation) return setErr('This device cannot share its location.');
    setBusy(true);
    navigator.geolocation.getCurrentPosition(async (p) => {
      if (p.coords.accuracy > 150) { setBusy(false); setErr(`This device only knows where it is to within about ${Math.round(p.coords.accuracy * 3.28).toLocaleString()} ft, which isn't accurate enough. Use a phone, outside at the store's entrance.`); return; }
      try {
        await act('set_site_location', { p_site: r.id, p_lat: p.coords.latitude, p_lon: p.coords.longitude });
        setMsg(`Map location saved for ${r.name} (accurate to about ${Math.round(p.coords.accuracy * 3.28)} ft).`);
        await load();
      } catch (e) { setErr(e.message); } finally { setBusy(false); }
    }, (e) => { setBusy(false); setErr(e.code === 1 ? 'Location is turned off for this website. Allow location in your browser, then try again.' : 'Could not get your location. Step outside or try again.'); },
    { enableHighAccuracy: true, timeout: 20000, maximumAge: 0 });
  }

  return (
    <div className="panel panel-pad stack">
      {onClose && <div className="spread"><h2>Location settings</h2><button onClick={onClose}>Close</button></div>}
      <h3>Locations <Info title="Locations">Each store or building you have. Its address puts it on the map, so a technician's phone notices when they arrive, and sets its time zone for schedules and reminders. Each location includes one login for your team and costs $395 per year.</Info></h3>
      <ErrorBox error={err} /><Notice>{msg}</Notice>
      {adding ? (
        <form className="stack" style={{ gap: 8, border: '1px solid var(--line)', borderRadius: 10, padding: 12 }} onSubmit={addLocation}>
          <h3>Add a location</h3>
          <label>Location name<input id="add-loc-name" value={adding.name} onChange={(e) => setAdding({ ...adding, name: e.target.value })} placeholder="e.g. M&L Market — Seattle" required /></label>
          <AddressFinder id="add-loc-addr" value={adding.addr} onChange={(v) => setAdding({ ...adding, addr: v })} onFound={setFound} found={found} />
          <div className="small muted">$395 per year for this location, prorated to your renewal date. All trades, unlimited service calls.</div>
          <div className="row"><button className="primary" disabled={busy || !found}>Add location</button><button type="button" onClick={() => { setAdding(null); setFound(null); }}>Cancel</button></div>
        </form>
      ) : <div><button onClick={() => { setAdding({ name: '', addr: '' }); setFound(null); }}>+ Add a location</button> <span className="small muted">{rows.length} location{rows.length === 1 ? '' : 's'}</span></div>}
      {rows.map((r) => (
        <div key={r.id} className="stack" style={{ gap: 8, borderTop: '1px solid var(--line)', paddingTop: 12 }}>
          {edit?.id === r.id ? (
            <form className="stack" style={{ gap: 6 }} onSubmit={saveEdit}>
              <label>Location name<input value={edit.name} onChange={(e) => setEdit({ ...edit, name: e.target.value })} required /></label>
              <div className="small muted">Current address: {r.address}. To change it, type the new one and tap Find; leave it blank to keep it.</div>
              <AddressFinder id={`edit-addr-${r.id}`} value={edit.addr} onChange={(v) => setEdit({ ...edit, addr: v })} onFound={setEfound} found={efound} />
              <div className="row"><button className="primary" disabled={busy}>Save</button><button type="button" onClick={() => { setEdit(null); setEfound(null); }}>Cancel</button></div>
            </form>
          ) : (
            <div className="spread"><div><strong>{r.name}</strong> <span className="small muted">{r.address}</span></div>
              <button onClick={() => { setEdit({ id: r.id, name: r.name, addr: '' }); setEfound(null); }}>Edit name / address</button></div>
          )}
          <div className="row" style={{ gap: 8, alignItems: 'center' }}>
            {r.lat != null ? <span className="chip tone-green">On the map · arrival detection on</span> : <span className="chip tone-amber">Not on the map yet</span>}
            <span className="small muted">{(r.timezone || '').replace('America/', '').replace('_', ' ')} time</span>
            <button disabled={busy} onClick={() => hereNow(r)}>Fine-tune map point (on site)</button>
            <Info title="Fine-tune map point">The address already puts this location on the map. If technicians park or enter somewhere else (a back lot, a loading dock, a big property), stand at that spot with your phone and tap this, so their arrival is noticed there. Use a phone at the store; a computer only knows roughly where it is.</Info>
          </div>
          <label>Emergency calls are approved up to ($) <span className="muted" style={{ fontWeight: 400 }}>— leave blank to approve every emergency request yourself</span>
            <input type="number" min="0" step="any" value={r.em} onChange={set(r.id, 'em')} placeholder="e.g. 1500" /></label>
          {r.em !== '' && <div className="small muted">On emergency calls the technician can go ahead up to {money(r.em)} total without waiting; you're told immediately.</div>}
          <div className="row">
            <label className="grow">Guest Wi-Fi name (for technicians)<input value={r.ssid} onChange={set(r.id, 'ssid')} placeholder="optional" /></label>
            <label className="grow">Wi-Fi password<input value={r.pw} onChange={set(r.id, 'pw')} placeholder="optional" /></label>
          </div>
          <div className="small muted">Only your people and a technician with an open job here can see the Wi-Fi details.</div>
          <div className="row small" style={{ gap: 12 }}>
            <strong>Unexpected visitors must give:</strong>
            <label className="row" style={{ gap: 4, fontWeight: 400 }}><input type="checkbox" style={{ width: 'auto' }} disabled={busy} checked={!!r.visitor_require_plate} onChange={(e) => visitorRule(r, 'plate', e.target.checked)} />Vehicle plate</label>
            <label className="row" style={{ gap: 4, fontWeight: 400 }}><input type="checkbox" style={{ width: 'auto' }} disabled={busy} checked={!!r.visitor_require_photo} onChange={(e) => visitorRule(r, 'photo', e.target.checked)} />Photo</label>
            <Info title="Unexpected visitors">When someone shows up with no trip scheduled, your people log them with "Someone's here we weren't expecting". By default a name and company are enough; plate and photo are optional. Tick these to make them required at this location (for example a location with security rules). Leave them off if it would slow your people down.</Info>
          </div>
          <div className="small"><strong>Backup check-in code</strong> <Info title="Backup check-in code">Every call has its own check-in code; it shows on the call and in the alert when the technician arrives, and someone at the store reads it to them. The backup code is a standing code for when that isn't possible (the person with the call's code is away, the screen is down). The technician taps "Use store backup code" and enters it; the call is marked "checked in with backup code" so you can see it was used. It's stored scrambled, so nobody can look it up, not even us. Tell it only to people at your store, and change it if it gets around.</Info>
            {' '}{r.backup_code_set_at ? <span className="chip tone-green">Set {dateTime(r.backup_code_set_at)}{r.backup_code_set_by_name ? ` by ${r.backup_code_set_by_name}` : ''}</span> : <span className="chip tone-amber">No backup code yet</span>}</div>
          <label>{r.backup_code_set_at ? 'Replace the backup code' : 'Set a backup code'} <span className="muted" style={{ fontWeight: 400 }}>— leave blank to keep {r.backup_code_set_at ? 'the current one' : 'none'}</span>
            <input value={r.backup} onChange={set(r.id, 'backup')} inputMode="numeric" placeholder="4–8 digits" /></label>
          <button className="primary" disabled={busy} onClick={() => save(r)}>Save {r.name}</button>
        </div>
      ))}
    </div>
  );
}
