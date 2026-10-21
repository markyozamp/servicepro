'use client';

// Location settings a store's admin controls: emergency pre-approval, guest Wi-Fi for technicians,
// and the standing backup check-in code.
import { useEffect, useState } from 'react';
import { supabase, act, q } from '@/lib/supabase';
import { money } from '@/lib/format';
import { ErrorBox, Notice } from './bits';

export default function LocationSettings({ onClose }) {
  const [rows, setRows] = useState([]);
  const [err, setErr] = useState('');
  const [msg, setMsg] = useState('');
  const [busy, setBusy] = useState(false);

  async function load() {
    try {
      const [sites, wifi] = await Promise.all([
        q(supabase.from('sites').select('id, name, address, emergency_limit, lat, lon').order('name')),
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

  function hereNow(r) {
    setErr(''); setMsg('');
    if (!navigator.geolocation) return setErr('This device cannot share its location.');
    setBusy(true);
    navigator.geolocation.getCurrentPosition(async (p) => {
      try {
        await act('set_site_location', { p_site: r.id, p_lat: p.coords.latitude, p_lon: p.coords.longitude });
        setMsg(`Map location saved for ${r.name} (accurate to about ${Math.round(p.coords.accuracy * 3.28)} ft).`);
        await load();
      } catch (e) { setErr(e.message); } finally { setBusy(false); }
    }, (e) => { setBusy(false); setErr(e.code === 1 ? 'Location is turned off for this site. Allow location in your browser, then try again.' : 'Could not get your location. Step outside or try again.'); },
    { enableHighAccuracy: true, timeout: 20000, maximumAge: 0 });
  }

  return (
    <div className="panel panel-pad stack">
      <div className="spread"><h2>Location settings</h2><button onClick={onClose}>Close</button></div>
      <ErrorBox error={err} /><Notice>{msg}</Notice>
      {rows.map((r) => (
        <div key={r.id} className="stack" style={{ gap: 8, borderTop: '1px solid var(--line)', paddingTop: 12 }}>
          <div><strong>{r.name}</strong> <span className="small muted">{r.address}</span></div>
          <div className="row" style={{ gap: 8, alignItems: 'center' }}>
            {r.lat != null ? <span className="chip tone-green">Map location set</span> : <span className="chip tone-amber">No map location yet</span>}
            <button disabled={busy} onClick={() => hereNow(r)}>Use where I'm standing</button>
          </div>
          <div className="small muted">Stand at the entrance technicians use, then tap. Technicians' phones notice their arrival within about 300 ft of this point.</div>
          <label>Emergency calls are approved up to ($) <span className="muted" style={{ fontWeight: 400 }}>— leave blank to approve every emergency request yourself</span>
            <input type="number" min="0" step="50" value={r.em} onChange={set(r.id, 'em')} placeholder="e.g. 1500" /></label>
          {r.em !== '' && <div className="small muted">On emergency calls the technician can go ahead up to {money(r.em)} total without waiting; you're told immediately.</div>}
          <div className="row">
            <label className="grow">Guest Wi-Fi name (for technicians)<input value={r.ssid} onChange={set(r.id, 'ssid')} placeholder="optional" /></label>
            <label className="grow">Wi-Fi password<input value={r.pw} onChange={set(r.id, 'pw')} placeholder="optional" /></label>
          </div>
          <div className="small muted">Only your people and a technician with an open job here can see the Wi-Fi details.</div>
          <label>New backup check-in code <span className="muted" style={{ fontWeight: 400 }}>— for when the call's code can't be given; leave blank to keep the current one</span>
            <input value={r.backup} onChange={set(r.id, 'backup')} inputMode="numeric" placeholder="4–8 digits" /></label>
          <button className="primary" disabled={busy} onClick={() => save(r)}>Save {r.name}</button>
        </div>
      ))}
    </div>
  );
}
