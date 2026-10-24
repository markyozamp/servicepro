'use client';

// Temperatures and doors: every sensor live (temperature, door, battery, last heard), open alarms to acknowledge,
// typed readings for units without a sensor, the history, and setup (gateways, sensors, the store's alarm list).
// Used by the store (its locations) and the contractor's office (its customers' locations).
import { useCallback, useEffect, useState } from 'react';
import { act } from '@/lib/supabase';
import { dateTime } from '@/lib/format';

const ago = (t) => {
  if (!t) return 'never';
  const m = Math.round((Date.now() - new Date(t).getTime()) / 60000);
  if (m < 1) return 'just now'; if (m < 60) return `${m} min ago`;
  const h = Math.round(m / 60); return h < 48 ? `${h} h ago` : `${Math.round(h / 24)} days ago`;
};
const f1 = (n) => (n == null ? '—' : `${Number(n).toFixed(1).replace(/\.0$/, '')}°F`);
const KIND = { temp: 'Temperature sensor', door: 'Door sensor', manual: 'Typed log (no sensor)' };
const ALARM = { high: 'Too warm', low: 'Too cold', door: 'Door open', quiet: 'Not reporting', battery: 'Battery low', gateway: 'Gateway offline' };
const PROBLEMS = [['wi_cooler_down', 'Walk-in cooler'], ['wi_freezer_down', 'Walk-in freezer'], ['case_warm', 'Display case'], ['self_contained_down', 'Reach-in / self-contained'], ['ice_machine', 'Ice machine'], ['rack_alarm', 'Refrigeration rack']];
const blank = (site) => ({ id: null, site, kind: 'temp', name: '', ext: '', low: '', high: '', after: 30, door: 10, quiet: 60, auto: true, issue: '' });

function Spark({ pts, low, high }) {
  const t = pts.filter((p) => p.temp_f != null);
  if (t.length < 2) return null;
  const vals = t.map((p) => Number(p.temp_f)).concat([low, high].filter((x) => x != null).map(Number));
  const lo = Math.min(...vals) - 2, hi = Math.max(...vals) + 2, W = 560, H = 120;
  const t0 = new Date(t[0].at).getTime(), t1 = new Date(t[t.length - 1].at).getTime() || t0 + 1;
  const x = (p) => ((new Date(p.at).getTime() - t0) / Math.max(1, t1 - t0)) * W;
  const y = (v) => H - ((v - lo) / (hi - lo)) * H;
  return (
    <svg viewBox={`0 0 ${W} ${H}`} style={{ width: '100%', maxWidth: W, height: H, background: 'var(--panel-2, #f7f7f5)', borderRadius: 8 }} role="img" aria-label="Temperature history">
      {high != null && <line x1="0" x2={W} y1={y(high)} y2={y(high)} stroke="#d64545" strokeDasharray="4 4" />}
      {low != null && <line x1="0" x2={W} y1={y(low)} y2={y(low)} stroke="#3b7dd8" strokeDasharray="4 4" />}
      <polyline fill="none" stroke="currentColor" strokeWidth="2" points={t.map((p) => `${x(p).toFixed(1)},${y(Number(p.temp_f)).toFixed(1)}`).join(' ')} />
    </svg>
  );
}

function History({ id, onClose }) {
  const [h, setH] = useState(null);
  const [err, setErr] = useState('');
  useEffect(() => { act('monitor_history', { p_device: id, p_hours: 48 }).then(setH).catch((x) => setErr(x.message)); }, [id]);
  if (err) return <div className="error small">{err}</div>;
  if (!h) return <div className="small muted">Loading…</div>;
  const rows = [...h.readings].reverse().slice(0, 40);
  return (
    <div className="stack small" style={{ gap: 6 }}>
      <div className="spread"><strong>Last 48 hours</strong><button className="linkbtn small" onClick={onClose}>Close</button></div>
      <Spark pts={h.readings} low={h.device.low_f} high={h.device.high_f} />
      {rows.length === 0 ? <div className="muted">No readings yet.</div> : (
        <div className="tablewrap" style={{ maxHeight: 220, overflow: 'auto' }}>
          <table className="small"><tbody>
            {rows.map((r, i) => <tr key={i}><td>{dateTime(r.at)}</td><td className="num">{r.temp_f != null ? f1(r.temp_f) : r.door_open != null ? (r.door_open ? 'Opened' : 'Closed') : ''}</td>
              <td className="muted">{r.source === 'typed' ? `typed${r.by ? ` by ${r.by}` : ''}` : ''}{r.note ? ` · ${r.note}` : ''}{r.battery != null ? ` · battery ${r.battery}%` : ''}</td></tr>)}
          </tbody></table>
        </div>
      )}
    </div>
  );
}

function DeviceCard({ d, manage, onEdit, onChanged }) {
  const [log, setLog] = useState('');
  const [hist, setHist] = useState(false);
  const [err, setErr] = useState('');
  const alarm = (d.alarms || []).filter((k) => ['high', 'low', 'door'].includes(k));
  const warn = (d.alarms || []).filter((k) => ['quiet', 'battery'].includes(k));
  const tone = alarm.length ? 'var(--red-fg)' : warn.length ? '#b26b00' : 'var(--green-fg)';
  return (
    <div className="panel panel-pad stack" style={{ gap: 6, borderColor: alarm.length ? 'var(--red-fg)' : undefined }}>
      <div className="spread">
        <span><strong>{d.name}</strong> <span className="small muted">{d.kind === 'door' ? 'door' : d.kind === 'manual' ? 'typed log' : ''}</span></span>
        <span className="chip" style={{ color: tone, borderColor: tone }}>{alarm.length ? ALARM[alarm[0]] : warn.length ? ALARM[warn[0]] : d.active ? 'OK' : 'Paused'}</span>
      </div>
      <div className="row" style={{ alignItems: 'baseline', gap: 10 }}>
        <span style={{ fontSize: 28, fontWeight: 700, color: alarm.length ? 'var(--red-fg)' : undefined }}>
          {d.kind === 'door' ? (d.door_open ? 'OPEN' : d.door_open === false ? 'Closed' : '—') : f1(d.last_temp_f)}</span>
        <span className="small muted">{d.kind === 'door' ? (d.door_open && d.door_since ? `open since ${dateTime(d.door_since)} · alarm after ${d.door_max_min} min` : `alarm if open ${d.door_max_min} min`)
          : `keep ${d.low_f != null ? f1(d.low_f) : 'any'} to ${d.high_f != null ? f1(d.high_f) : 'any'}`}</span>
      </div>
      <div className="small muted">{d.kind === 'manual' ? `Last typed ${ago(d.last_seen_at)}` : `Heard ${ago(d.last_seen_at)}`}{d.battery_pct != null ? ` · battery ${d.battery_pct}%` : ''}</div>
      {d.kind !== 'door' && (
        <form className="row small" style={{ gap: 6 }} onSubmit={async (e) => {
          e.preventDefault(); setErr('');
          try { const r = await act('log_temperature', { p_device: d.id, p_temp_f: Number(log) }); setLog(''); onChanged(r.alarm ? 'Logged. It’s out of range: the alarm went out.' : 'Logged.'); } catch (x) { setErr(x.message); }
        }}>
          <input type="number" step="0.1" value={log} onChange={(e) => setLog(e.target.value)} placeholder="°F now" style={{ width: 90 }} aria-label={`Type the temperature for ${d.name}`} />
          <button disabled={log === ''}>Log reading</button>
          <button type="button" className="linkbtn small" onClick={() => setHist(!hist)}>History</button>
          {manage && <button type="button" className="linkbtn small" onClick={onEdit}>Change</button>}
        </form>
      )}
      {d.kind === 'door' && <div className="row small" style={{ gap: 6 }}><button type="button" className="linkbtn small" onClick={() => setHist(!hist)}>History</button>{manage && <button type="button" className="linkbtn small" onClick={onEdit}>Change</button>}</div>}
      {hist && <History id={d.id} onClose={() => setHist(false)} />}
      {err && <div className="error small">{err}</div>}
    </div>
  );
}

function DeviceForm({ f, setF, sites, gateways, onDone, onCancel }) {
  const [err, setErr] = useState('');
  const set = (k) => (e) => setF({ ...f, [k]: e.target.type === 'checkbox' ? e.target.checked : e.target.value });
  const heard = gateways.filter((g) => g.site_id === f.site).flatMap((g) => g.heard || []);
  const save = async (e) => {
    e.preventDefault(); setErr('');
    try {
      await act('save_monitor_device', { p_id: f.id, p_site: f.site, p_kind: f.kind, p_name: f.name, p_external_id: f.ext || null,
        p_low_f: f.low === '' ? null : Number(f.low), p_high_f: f.high === '' ? null : Number(f.high), p_alarm_after_min: Number(f.after) || 0,
        p_door_max_min: Number(f.door) || 10, p_quiet_after_min: Number(f.quiet) || 60, p_auto_call: f.auto, p_equipment: null,
        p_issue_code: f.issue || null, p_contractor: f.contractor || null, p_active: true });
      onDone(f.id ? 'Saved.' : 'Added.');
    } catch (x) { setErr(x.message); }
  };
  return (
    <form className="panel panel-pad stack" style={{ gap: 8 }} onSubmit={save}>
      <h3 style={{ margin: 0 }}>{f.id ? 'Change' : 'Add'} a sensor</h3>
      <div className="row">
        <label className="grow">Location<select value={f.site} onChange={set('site')} required disabled={!!f.id}><option value="">Pick…</option>{sites.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</select></label>
        <label className="grow">Type<select value={f.kind} onChange={set('kind')}>{Object.entries(KIND).map(([k, n]) => <option key={k} value={k}>{n}</option>)}</select></label>
        <label className="grow">Name<input value={f.name} onChange={set('name')} placeholder="e.g. Walk-in freezer" required /></label>
      </div>
      {f.kind !== 'manual' && (
        <div className="row">
          <label className="grow">Sensor ID <span className="muted" style={{ fontWeight: 400 }}>(on its label: DevEUI or serial)</span><input value={f.ext} onChange={set('ext')} placeholder="e.g. 24E124126B123456" required /></label>
          {heard.length > 0 && <label className="grow">…or pick one the gateway hears<select value="" onChange={(e) => setF({ ...f, ext: e.target.value })}>
            <option value="">{heard.length} not set up yet…</option>{heard.map((h) => <option key={h.id} value={h.id}>{h.id} · {h.sample?.temp_c != null ? `${h.sample.temp_c}°C` : h.sample?.temp_f != null ? `${h.sample.temp_f}°F` : h.sample?.door_open != null ? (h.sample.door_open ? 'open' : 'closed') : ''} · {ago(h.last_seen_at)}</option>)}</select></label>}
        </div>
      )}
      {f.kind !== 'door' ? (
        <div className="row">
          <label style={{ flex: '0 0 120px' }}>Low limit °F<input type="number" step="0.1" value={f.low} onChange={set('low')} placeholder="e.g. -10" /></label>
          <label style={{ flex: '0 0 120px' }}>High limit °F<input type="number" step="0.1" value={f.high} onChange={set('high')} placeholder="e.g. 10" /></label>
          {f.kind === 'temp' && <label style={{ flex: '0 0 170px' }}>Alarm after (min out of range)<input type="number" min="0" max="720" value={f.after} onChange={set('after')} /></label>}
          <label className="grow">Unit (for the service call)<select value={f.issue} onChange={set('issue')}><option value="">From the name</option>{PROBLEMS.map(([k, n]) => <option key={k} value={k}>{n}</option>)}</select></label>
        </div>
      ) : (
        <div className="row"><label style={{ flex: '0 0 200px' }}>Alarm if open longer than (min)<input type="number" min="1" max="240" value={f.door} onChange={set('door')} /></label></div>
      )}
      {f.kind !== 'manual' && <div className="row"><label style={{ flex: '0 0 220px' }}>Flag it if not heard for (min)<input type="number" min="15" max="1440" value={f.quiet} onChange={set('quiet')} /></label></div>}
      {f.kind !== 'door' && <label className="row small" style={{ gap: 6, fontWeight: 400 }}><input type="checkbox" style={{ width: 'auto' }} checked={f.auto} onChange={set('auto')} />Out of range: open a service call to the contractor automatically (with the readings)</label>}
      {err && <div className="error">{err}</div>}
      <div className="row"><button className="primary">Save</button><button type="button" onClick={onCancel}>Cancel</button>
        {f.id && <button type="button" className="linkbtn small" onClick={async () => { if (!window.confirm(`Remove ${f.name}?`)) return; try { await act('remove_monitor_device', { p_id: f.id }); onDone('Removed.'); } catch (x) { setErr(x.message); } }}>Remove this sensor</button>}</div>
    </form>
  );
}

function Gateways({ gateways, sites, onChanged }) {
  const [add, setAdd] = useState(null);
  const [err, setErr] = useState('');
  const origin = typeof window !== 'undefined' ? window.location.origin : '';
  return (
    <div className="panel panel-pad stack" style={{ gap: 8 }}>
      <h3 style={{ margin: 0 }}>Gateways</h3>
      <div className="small muted">One gateway per building collects every sensor there. Plug it into the store&apos;s router (or use its cellular), and give it battery backup. In the gateway, send its data to the address below (Milesight: Network Server → Applications → add an HTTP data destination, payload codec on). Keep the address private: it&apos;s that gateway&apos;s key.</div>
      {gateways.map((g) => (
        <div key={g.id} className="stack small" style={{ gap: 2, borderTop: '1px solid var(--line)', paddingTop: 6 }}>
          <div className="spread"><span><strong>{g.name}</strong> · {g.site} · {g.vendor}</span><span className={g.last_seen_at && Date.now() - new Date(g.last_seen_at) < 30 * 60000 ? '' : 'muted'}>heard {ago(g.last_seen_at)}</span></div>
          <div className="row" style={{ gap: 6 }}><code style={{ wordBreak: 'break-all' }}>{`${origin}/api/monitor/${g.token}`}</code>
            <button type="button" className="linkbtn small" onClick={() => navigator.clipboard?.writeText(`${origin}/api/monitor/${g.token}`)}>Copy</button>
            <button type="button" className="linkbtn small" onClick={async () => { if (!window.confirm(`Remove gateway ${g.name}?`)) return; try { await act('remove_gateway', { p_id: g.id }); onChanged('Gateway removed.'); } catch (x) { setErr(x.message); } }}>Remove</button></div>
          {(g.heard || []).length > 0 && <div className="muted">Hears {g.heard.length} sensor{g.heard.length > 1 ? 's' : ''} not set up yet: + Add a sensor to pick {g.heard.length > 1 ? 'them' : 'it'}.</div>}
        </div>
      ))}
      {add ? (
        <form className="row" style={{ alignItems: 'flex-end' }} onSubmit={async (e) => { e.preventDefault(); setErr(''); try { await act('save_gateway', { p_id: null, p_site: add.site, p_name: add.name, p_vendor: add.vendor }); setAdd(null); onChanged('Gateway added. Put its address into the gateway.'); } catch (x) { setErr(x.message); } }}>
          <label className="grow">Location<select value={add.site} onChange={(e) => setAdd({ ...add, site: e.target.value })} required><option value="">Pick…</option>{sites.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</select></label>
          <label className="grow">Name<input value={add.name} onChange={(e) => setAdd({ ...add, name: e.target.value })} placeholder="e.g. Back office" required /></label>
          <label style={{ flex: '0 0 140px' }}>Brand<select value={add.vendor} onChange={(e) => setAdd({ ...add, vendor: e.target.value })}><option value="milesight">Milesight</option><option value="monnit">Monnit</option><option value="other">Other</option></select></label>
          <button className="primary">Add</button><button type="button" onClick={() => setAdd(null)}>Cancel</button>
        </form>
      ) : <div><button onClick={() => setAdd({ site: sites.length === 1 ? sites[0].id : '', name: '', vendor: 'milesight' })}>+ Add a gateway</button></div>}
      {err && <div className="error small">{err}</div>}
    </div>
  );
}

function AlarmList({ contacts, sites, onChanged }) {
  const [err, setErr] = useState('');
  const set = async (p, site, on) => { setErr(''); try { await act('set_alarm_contact', { p_profile: p, p_site: site, p_on: on }); onChanged(); } catch (x) { setErr(x.message); } };
  const anyone = contacts.some((c) => c.all || c.sites.length);
  return (
    <div className="panel panel-pad stack" style={{ gap: 6 }}>
      <h3 style={{ margin: 0 }}>Who gets alarms</h3>
      <div className="small muted">They get every temperature, door and sensor alarm, plus your contractor&apos;s office. {anyone ? '' : 'Nobody picked yet, so alarms go to everyone who opens service calls.'}</div>
      {contacts.map((c) => (
        <div key={c.profile_id} className="row small" style={{ gap: 10, flexWrap: 'wrap' }}>
          <label className="row" style={{ gap: 6, fontWeight: 400, minWidth: 220 }}><input type="checkbox" style={{ width: 'auto' }} checked={c.all} onChange={(e) => set(c.profile_id, null, e.target.checked)} /><strong>{c.name}</strong>{c.title ? <span className="muted"> · {c.title}</span> : null}</label>
          {!c.all && sites.length > 1 && sites.map((s) => (
            <label key={s.id} className="row" style={{ gap: 4, fontWeight: 400 }}><input type="checkbox" style={{ width: 'auto' }} checked={c.sites.includes(s.id)} onChange={(e) => set(c.profile_id, s.id, e.target.checked)} />{s.name}</label>
          ))}
        </div>
      ))}
      {err && <div className="error small">{err}</div>}
    </div>
  );
}

// The temperature log for a claim or an inspector: pick the location, dates and unit, open it to print or download
function ReportForm({ sites, devices, siteFilter }) {
  const today = new Date(); const pad = (n) => String(n).padStart(2, '0');
  const ymd = (x) => `${x.getFullYear()}-${pad(x.getMonth() + 1)}-${pad(x.getDate())}`;
  const [f, setF] = useState({ site: siteFilter || (sites.length === 1 ? sites[0].id : ''), from: ymd(new Date(today.getTime() - 6 * 864e5)), to: ymd(today), unit: '' });
  const units = devices.filter((x) => x.site_id === f.site);
  return (
    <div className="panel panel-pad stack" style={{ gap: 8 }}>
      <h3 style={{ margin: 0 }}>Temperature log</h3>
      <div className="small muted">For a product claim, your insurer or the health inspector: hour by hour with each hour&apos;s high and low, a graph, the alarms and door openings. Print it, save it as a PDF, or download it. Up to 31 days at a time.</div>
      <div className="row" style={{ alignItems: 'flex-end' }}>
        {sites.length > 1 && <label className="grow">Location<select value={f.site} onChange={(e) => setF({ ...f, site: e.target.value, unit: '' })}><option value="">Pick…</option>{sites.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</select></label>}
        <label className="grow">Unit<select value={f.unit} onChange={(e) => setF({ ...f, unit: e.target.value })}><option value="">All units</option>{units.map((u) => <option key={u.id} value={u.id}>{u.name}{u.kind === 'door' ? ' (door)' : ''}</option>)}</select></label>
        <label style={{ flex: '0 0 160px' }}>From<input type="date" value={f.from} onChange={(e) => setF({ ...f, from: e.target.value })} /></label>
        <label style={{ flex: '0 0 160px' }}>To<input type="date" value={f.to} onChange={(e) => setF({ ...f, to: e.target.value })} /></label>
        <button disabled={!f.site || !f.from || !f.to} onClick={() => window.open(`/temperature-log?site=${f.site}&from=${f.from}&to=${f.to}${f.unit ? `&unit=${f.unit}` : ''}`, '_blank')}>Open the log</button>
      </div>
    </div>
  );
}

export default function Monitoring({ sites, onOpenCall, onClose, siteFilter }) {
  const [d, setD] = useState(null);
  const [err, setErr] = useState('');
  const [msg, setMsg] = useState('');
  const [form, setForm] = useState(null);
  const load = useCallback(async () => { try { setD(await act('monitor_overview', {})); } catch (x) { setErr(x.message); } }, []);
  useEffect(() => { load(); const t = setInterval(load, 60000); return () => clearInterval(t); }, [load]);
  const changed = (m) => { if (m) setMsg(m); setForm(null); load(); };
  if (!d) return err ? <div className="error">{err}</div> : <div className="muted">Loading sensors…</div>;
  const devs = d.devices.filter((x) => !siteFilter || x.site_id === siteFilter);
  const open = d.alarms.filter((a) => !a.cleared_at && (!siteFilter || a.site_id === siteFilter));
  const bySite = devs.reduce((m, x) => { const k = `${x.customer} · ${x.site}`; (m[k] = m[k] || []).push(x); return m; }, {});
  return (
    <div className="stack" style={{ gap: 12 }}>
      <div className="spread"><h2 style={{ margin: 0 }}>Temperatures and doors</h2>{onClose && <button onClick={onClose}>Close</button>}</div>
      {msg && <div className="notice small">{msg}</div>}
      {err && <div className="error">{err}</div>}
      {open.length > 0 && (
        <div className="stack" style={{ gap: 6 }}>
          {open.map((a) => (
            <div key={a.id} className="panel panel-pad spread" style={{ borderColor: ['high', 'low', 'door', 'gateway'].includes(a.kind) ? 'var(--red-fg)' : '#e6c98a', background: ['high', 'low', 'door', 'gateway'].includes(a.kind) ? '#fff5f5' : '#fffcf3' }}>
              <span className="stack" style={{ gap: 2 }}>
                <strong>{ALARM[a.kind]}: {a.label}</strong>
                <span className="small">since {dateTime(a.started_at)}{a.call_number ? <> · <button className="linkbtn small" onClick={() => onOpenCall?.(a.work_order_id)}>service call #{a.call_number}</button></> : ''}{a.ack_at ? ` · acknowledged by ${a.ack_name || 'someone'}` : ''}</span>
              </span>
              {!a.ack_at && <button className="primary" onClick={async () => { try { await act('ack_alarm', { p_alarm: a.id }); load(); } catch (x) { setErr(x.message); } }}>I&apos;m on it</button>}
            </div>
          ))}
        </div>
      )}
      {form && <DeviceForm f={form} setF={setForm} sites={sites} gateways={d.gateways} onDone={changed} onCancel={() => setForm(null)} />}
      {!devs.length && !form && <div className="panel panel-pad small muted">No sensors yet. {d.can_manage ? 'Add a gateway for the building, then add its sensors, or add a typed log for units without a sensor.' : 'Your admin or contractor can set them up.'}</div>}
      {Object.entries(bySite).map(([k, list]) => (
        <div key={k} className="stack" style={{ gap: 6 }}>
          <strong className="small">{d.side === 'store' ? list[0].site : k}</strong>
          <div className="quotegrid">{list.map((x) => <DeviceCard key={x.id} d={x} manage={d.can_manage}
            onEdit={() => setForm({ id: x.id, site: x.site_id, kind: x.kind, name: x.name, ext: x.external_id || '', low: x.low_f ?? '', high: x.high_f ?? '', after: x.alarm_after_min, door: x.door_max_min, quiet: x.quiet_after_min, auto: x.auto_call, issue: x.issue_code || '', contractor: x.contractor_id })}
            onChanged={changed} />)}</div>
        </div>
      ))}
      {d.can_manage && !form && <div><button className="primary" onClick={() => setForm(blank(siteFilter || (sites.length === 1 ? sites[0].id : '')))}>+ Add a sensor</button></div>}
      {d.can_manage && <Gateways gateways={d.gateways.filter((g) => !siteFilter || g.site_id === siteFilter)} sites={sites} onChanged={changed} />}
      {d.contacts && <AlarmList contacts={d.contacts} sites={sites} onChanged={() => load()} />}
      {devs.length > 0 && <ReportForm sites={sites.filter((s) => d.devices.some((x) => x.site_id === s.id))} devices={d.devices} siteFilter={siteFilter} />}
      {d.alarms.some((a) => a.cleared_at) && (
        <details className="small"><summary style={{ cursor: 'pointer' }}>Alarms in the last 7 days</summary>
          <table className="small" style={{ marginTop: 6 }}><tbody>
            {d.alarms.filter((a) => a.cleared_at).map((a) => <tr key={a.id}><td>{ALARM[a.kind]}</td><td>{a.label}</td><td>{dateTime(a.started_at)} to {dateTime(a.cleared_at)}</td><td>{a.call_number ? `call #${a.call_number}` : ''}</td></tr>)}
          </tbody></table>
        </details>
      )}
    </div>
  );
}

// A small strip for the top of the store / office screen when something is in alarm
export function AlarmStrip({ onOpen }) {
  const [n, setN] = useState(0);
  useEffect(() => {
    let live = true;
    const tick = () => act('monitor_overview', {}).then((r) => live && setN((r?.alarms || []).filter((a) => !a.cleared_at && ['high', 'low', 'door', 'gateway'].includes(a.kind)).length)).catch(() => {});
    tick(); const t = setInterval(tick, 60000); return () => { live = false; clearInterval(t); };
  }, []);
  if (!n) return null;
  return <button className="danger" style={{ width: '100%' }} onClick={onOpen}>🌡 {n} temperature / door alarm{n > 1 ? 's' : ''}: open Temperatures</button>;
}
