'use client';

// The technician app's offline engine.
// - The job list is downloaded (tech_jobs) and kept on the phone.
// - Every tap becomes an action in a queue with the time it happened; the screen updates at once.
// - When there is signal, actions go to the database in order. Photos wait on the phone until sent.
// - Anything the database refuses (e.g. a wrong check-in code) shows up as a problem to fix.
import { supabase } from './supabase';

const K_SNAP = 'sp_tech_snapshot';
const K_QUEUE = 'sp_tech_queue';
const K_PROBLEMS = 'sp_tech_problems';
const K_SYNCED = 'sp_tech_last_sync';

const read = (k, d) => { try { const v = localStorage.getItem(k); return v ? JSON.parse(v) : d; } catch { return d; } };
const write = (k, v) => { try { localStorage.setItem(k, JSON.stringify(v)); } catch { /* storage full */ } };

export const uuid = () => (crypto.randomUUID ? crypto.randomUUID()
  : 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
    const r = (Math.random() * 16) | 0; return (c === 'x' ? r : (r & 0x3) | 0x8).toString(16);
  }));

// ---------- photos kept on the phone until sent (IndexedDB) ----------
function idb() {
  return new Promise((resolve, reject) => {
    const r = indexedDB.open('servicepro', 1);
    r.onupgradeneeded = () => r.result.createObjectStore('photos');
    r.onsuccess = () => resolve(r.result);
    r.onerror = () => reject(r.error);
  });
}
async function photoPut(id, blob) {
  const db = await idb();
  return new Promise((res, rej) => { const t = db.transaction('photos', 'readwrite'); t.objectStore('photos').put(blob, id); t.oncomplete = res; t.onerror = () => rej(t.error); });
}
export async function photoGet(id) {
  const db = await idb();
  return new Promise((res, rej) => { const q = db.transaction('photos').objectStore('photos').get(id); q.onsuccess = () => res(q.result); q.onerror = () => rej(q.error); });
}
async function photoDel(id) {
  const db = await idb();
  return new Promise((res) => { const t = db.transaction('photos', 'readwrite'); t.objectStore('photos').delete(id); t.oncomplete = res; t.onerror = res; });
}

// Shrink a camera photo to a sensible size before keeping it (saves phone storage and upload time).
export async function shrinkPhoto(file, max = 1600) {
  const url = URL.createObjectURL(file);
  try {
    const img = await new Promise((res, rej) => { const i = new Image(); i.onload = () => res(i); i.onerror = rej; i.src = url; });
    const scale = Math.min(1, max / Math.max(img.width, img.height));
    const c = document.createElement('canvas');
    c.width = Math.round(img.width * scale); c.height = Math.round(img.height * scale);
    c.getContext('2d').drawImage(img, 0, 0, c.width, c.height);
    return await new Promise((res) => c.toBlob((b) => res(b || file), 'image/jpeg', 0.8));
  } catch {
    return file;
  } finally {
    URL.revokeObjectURL(url);
  }
}

// ---------- state ----------
// sent = actions the database accepted but that are not yet in a fresh download; still shown on screen.
let state = { server: null, queue: [], sent: [], problems: [], lastSync: null, syncing: false, online: true };
const subs = new Set();
const emit = () => subs.forEach((f) => f());
export function subscribe(f) { subs.add(f); return () => subs.delete(f); }
export function getState() { return state; }
function set(patch) { state = { ...state, ...patch }; emit(); }

export function load() {
  set({
    server: read(K_SNAP, null), queue: read(K_QUEUE, []), problems: read(K_PROBLEMS, []),
    lastSync: read(K_SYNCED, null), online: typeof navigator === 'undefined' ? true : navigator.onLine,
  });
}
function saveQueue(q) { write(K_QUEUE, q); set({ queue: q }); }
function saveProblems(p) { write(K_PROBLEMS, p); set({ problems: p }); }
export function dismissProblem(id) { saveProblems(state.problems.filter((p) => p.id !== id)); }
export function clearAll() { [K_SNAP, K_QUEUE, K_PROBLEMS, K_SYNCED].forEach((k) => localStorage.removeItem(k)); load(); }

// ---------- what the screen shows: the downloaded jobs with not-yet-sent actions applied ----------
export function view() {
  const base = state.server;
  if (!base) return null;
  const s = JSON.parse(JSON.stringify(base));
  for (const a of [...state.sent, ...state.queue]) applyLocal(s, a);
  return s;
}
const findJob = (s, visitId) => s.jobs.find((j) => j.visit.id === visitId);
const jobByWo = (s, woId) => s.jobs.find((j) => j.wo.id === woId);

function applyLocal(s, a) {
  const x = a.args || {};
  const j = x.p_visit ? findJob(s, x.p_visit) : x.p_wo ? jobByWo(s, x.p_wo) : null;
  const at = a.at;
  switch (a.fn) {
    case 'tech_received': if (j && !j.visit.received_at) j.visit.received_at = at; break;
    case 'tech_start': if (j && j.visit.status === 'assigned') { j.visit.status = 'en_route'; j.visit.started_at = at; } break;
    case 'tech_update_eta': if (j) j.visit.eta_at = x.p_eta_at; break;
    case 'tech_arrive': if (j && j.visit.status === 'en_route') { j.visit.status = 'on_site'; j.visit.arrived_at = at; } break;
    case 'tech_checkin':
      if (j && !x.p_checkout) { j.visit.checkin_at = j.visit.checkin_at || at; j.visit.checkin_local = x.p_method; }
      break;
    case 'tech_depart': if (j) j.visit.departed_at = at; break;
    case 'confirm_equipment': {
      if (!j) break;
      const t = s.catalog.equipment_types.find((e) => e.code === x.p_type_code);
      let e = x.p_equipment && j.equipment.find((q) => q.id === x.p_equipment);
      if (!e) { e = { id: x.p_equipment || `local-${a.id}`, local: true }; j.equipment.unshift(e); }
      Object.assign(e, { type: t?.name, type_code: x.p_type_code, manufacturer: x.p_manufacturer, model: x.p_model,
        serial: x.p_serial, location: x.p_location, confirmed: true });
      j.wo.equipment_id = e.id; j.wo.equipment_confirmed = true;
      break;
    }
    case 'set_repair_type': {
      if (!j) break;
      j.wo.repair_type_id = x.p_repair_type;
      const rt = s.catalog.repair_types.find((r) => r.id === x.p_repair_type);
      if (rt && x.p_apply_kit !== false) {
        for (const k of rt.kit || []) {
          if (!j.parts.some((p) => p.part_id === k.part_id)) j.parts.push(localPart(s, j, k.part_id, Number(k.qty)));
        }
        if ((rt.kit || []).length) j.wo.no_parts_used = false;
      }
      break;
    }
    case 'set_part_used': {
      if (!j) break;
      const i = j.parts.findIndex((p) => p.part_id === x.p_part);
      if (Number(x.p_qty) <= 0) { if (i >= 0) j.parts.splice(i, 1); break; }
      if (i >= 0) j.parts[i].qty = Number(x.p_qty); else j.parts.push(localPart(s, j, x.p_part, Number(x.p_qty)));
      j.wo.no_parts_used = false;
      break;
    }
    case 'set_no_parts_used': if (j) j.wo.no_parts_used = !!x.p_value; break;
    case 'set_checklist_result':
      if (j) j.wo.checklist_results = { ...(j.wo.checklist_results || {}), [String(x.p_index)]: { done: x.p_done, reading: x.p_reading, photo_id: x.p_photo, at } };
      break;
    case 'request_quote': {
      if (!j) break;
      const seq = Math.max(0, ...j.po_lines.map((l) => l.seq)) + 1;
      const est = a.meta?.amount || 0;
      const used = j.po_lines.filter((l) => l.status === 'approved').reduce((t, l) => t + Number(l.amount), 0);
      const em = j.meter?.emergency_limit != null && j.wo.priority === 1 && used + est <= Number(j.meter.emergency_limit);
      j.po_lines.push({ id: `local-${a.id}`, po: `${j.wo.po_number}${String.fromCharCode(64 + seq)}`, seq, amount: est,
        description: x.p_description, status: em ? 'approved' : 'pending', emergency: em, local: true });
      break;
    }
    case 'tech_finish_visit': if (j) { j.visit.status = 'done'; j.visit.outcome = x.p_outcome; j.visit.completed_at = at; } break;
    case 'photo': if (j) j.photos.push({ id: a.photo.id, kind: a.photo.kind, visit_id: j.visit.id, local: true }); break;
    case 'clock': {
      const c = s.clock || (s.clock = {});
      if (x.p_action === 'in') c.shift = { id: x.p_id, start_at: at };
      if (x.p_action === 'out') { c.shift = null; c.brk = null; }
      if (x.p_action === 'break_start') c.brk = { id: x.p_id, start_at: at };
      if (x.p_action === 'break_end') c.brk = null;
      break;
    }
    default:
  }
}

function localPart(s, j, partId, qty) {
  const p = s.catalog.parts.find((q) => q.id === partId);
  const covered = !!j.rules.parts_covered;
  const price = covered ? 0 : Math.round(Number(p?.price || 0) * (1 - Number(j.rules.parts_disc || 0) / 100) * 100) / 100;
  return { part_id: partId, name: p?.name || 'Part', qty, unit_price: price, covered, source: 'truck', local: true };
}

// ---------- the live cost meter, worked out on the phone ----------
export function meter(j, now = Date.now()) {
  const r = j.rules; const v = j.visit;
  const limitLines = j.po_lines.filter((l) => l.status === 'approved');
  const limit = j.po_lines.length ? limitLines.reduce((t, l) => t + Number(l.amount), 0) : null;
  let labor = Number(r.other_labor || 0); let minutes = 0;
  if (v.arrived_at) {
    const end = v.completed_at ? new Date(v.completed_at).getTime() : now;
    let raw = Math.max(0, Math.ceil((end - new Date(v.arrived_at).getTime()) / 60000));
    if (r.bill_travel && v.started_at) raw += Math.max(0, Math.ceil((new Date(v.arrived_at) - new Date(v.started_at)) / 60000));
    minutes = Math.max(Number(r.min_minutes), Math.ceil(raw / Number(r.increment)) * Number(r.increment));
    labor += Math.round((minutes / 60) * Number(r.rate) * 100) / 100;
  }
  const trips = (Number(r.other_trips || 0) + (v.arrived_at ? 1 : 0)) * Number(r.trip_eff || 0);
  const parts = j.parts.reduce((t, p) => t + Number(p.qty) * Number(p.unit_price || 0), 0);
  const used = Math.round((labor + parts + trips + Number(r.flat || 0)) * 100) / 100;
  const wait = Number(j.meter?.wait_minutes ?? 15);
  const reserve = Math.round(((wait + 15) / 60) * Number(r.rate) * 100) / 100;
  const stopAt = limit == null ? null : Math.max(0, Math.min(limit * Number(r.warn_pct) / 100, limit - reserve));
  const pending = j.po_lines.find((l) => l.status === 'pending');
  const state = limit == null ? 'no_limit' : used > limit ? 'over' : used >= stopAt ? 'stop' : 'ok';
  return { limit, used, labor, parts, trips, minutes, stopAt, reserve, wait, state, pending, rate: Number(r.rate),
    emergencyLimit: j.wo.priority === 1 && j.meter?.emergency_limit != null ? Number(j.meter.emergency_limit) : null };
}

// ---------- doing things ----------
export function act(fn, args, meta) {
  const a = { id: uuid(), fn, args: { ...args }, at: new Date().toISOString(), meta };
  // Times come from the moment the tech tapped, so a job done in a basement with no signal keeps true times.
  if (['tech_received', 'tech_start', 'tech_arrive', 'tech_checkin', 'tech_depart', 'tech_finish_visit', 'clock'].includes(fn)) {
    a.args.p_at = a.at;
  }
  saveQueue([...state.queue, a]);
  sync();
  return a;
}

export async function addPhoto(job, kind, file, extra = {}) {
  const id = uuid();
  const blob = await shrinkPhoto(file);
  await photoPut(id, blob);
  const a = { id: uuid(), fn: 'photo', at: new Date().toISOString(), args: { p_wo: job.wo.id },
    photo: { id, kind, wo: job.wo.id, visit: job.visit.id, ...extra } };
  saveQueue([...state.queue, a]);
  sync();
  return id;
}

const isNetwork = (msg = '') => /Failed to fetch|NetworkError|Load failed|network|fetch failed|timed out/i.test(msg);

async function send(a) {
  if (a.fn === 'photo') {
    const p = a.photo;
    const blob = await photoGet(p.id);
    if (blob) {
      const path = `${p.wo}/${p.id}.jpg`;
      const up = await supabase.storage.from('job-photos').upload(path, blob, { contentType: 'image/jpeg', upsert: false });
      if (up.error && !/exists|Duplicate/i.test(up.error.message)) throw up.error;
    }
    let pos = {};
    if (p.lat != null) pos = { lat: p.lat, lon: p.lon };
    const ins = await supabase.from('photos').insert({ id: p.id, work_order_id: p.wo, visit_id: p.visit, kind: p.kind,
      part_id: p.part_id || null, storage_path: `${p.wo}/${p.id}.jpg`, taken_at: a.at, uploaded_by: state.server?.me?.id, ...pos });
    if (ins.error && !/duplicate key/i.test(ins.error.message)) throw ins.error;
    await photoDel(p.id);
    return null;
  }
  const { data, error } = await supabase.rpc(a.fn, a.args);
  if (error) throw error;
  if (a.fn === 'tech_checkin' && data && data.verified === false && ['code', 'backup_code'].includes(a.args.p_method)) {
    const e = new Error(data.message || 'Wrong code — try again.'); e.business = true; throw e;
  }
  if (a.fn === 'tech_finish_visit' && data && data.ok === false && data.missing) {
    const e = new Error('Not finished — still needed: ' + data.missing.map((m) => m.message).join(' '));
    e.business = true; throw e;
  }
  return data;
}

let running = false;
export async function sync({ refresh = true } = {}) {
  if (running) return;
  if (typeof navigator !== 'undefined' && !navigator.onLine) { set({ online: false }); return; }
  running = true; set({ syncing: true, online: true });
  try {
    let stopped = false; let retries = 0;
    // Always work from the live queue: taps made while sending are added to the end and sent too.
    while (state.queue.length) {
      const a = state.queue[0];
      try {
        await send(a);
      } catch (e) {
        const msg = e?.message || String(e);
        if (/JWT expired|jwt/i.test(msg) && retries++ < 2) { await supabase.auth.refreshSession(); continue; }
        if (isNetwork(msg) && !e.business) { set({ online: false }); stopped = true; break; }
        // The database refused it: keep a note for the tech and move on.
        saveProblems([...state.problems, { id: a.id, fn: a.fn, visit: a.args?.p_visit, label: a.meta?.label || a.fn, message: msg, at: a.at }]);
      }
      retries = 0;
      set({ sent: [...state.sent, a] });
      saveQueue(state.queue.filter((x) => x.id !== a.id));
    }
    if (refresh && !stopped && state.queue.length === 0) {
      const included = new Set(state.sent.map((x) => x.id));
      // Report this phone's clock (after the saved actions went in, so their times are judged fairly).
      const hello = await supabase.rpc('device_hello', { p_device_now: new Date().toISOString() });
      if (!hello.error && hello.data) set({ clock: hello.data });
      const { data, error } = await supabase.rpc('tech_jobs');
      if (!error && data) {
        // Store guest Wi-Fi (only the stores where this tech has an open job), kept for no-signal use
        const wifi = await supabase.from('site_wifi').select('site_id, ssid, password').not('ssid', 'is', null);
        data.wifi = Object.fromEntries((wifi.data || []).map((x) => [x.site_id, { ssid: x.ssid, password: x.password }]));
        write(K_SNAP, data);
        const now = new Date().toISOString();
        write(K_SYNCED, now);
        set({ server: data, lastSync: now, sent: state.sent.filter((x) => !included.has(x.id)) });
      } else if (error && isNetwork(error.message)) {
        set({ online: false });
      }
    }
  } finally {
    running = false;
    set({ syncing: false });
    // Taps made while the job list was refreshing: send them now rather than waiting a minute.
    if (state.queue.length && state.online && !state.problemsBlocking) setTimeout(() => sync(), 50);
  }
}

export function startAutoSync() {
  const on = () => { set({ online: true }); sync(); };
  const off = () => set({ online: false });
  window.addEventListener('online', on);
  window.addEventListener('offline', off);
  const t = setInterval(() => { if (navigator.onLine) sync(); }, 60000);
  return () => { window.removeEventListener('online', on); window.removeEventListener('offline', off); clearInterval(t); };
}

// Distance in feet between two GPS points.
export function feet(a, b) {
  const R = 20902231; const rad = (d) => (d * Math.PI) / 180;
  const dLat = rad(b.lat - a.lat); const dLon = rad(b.lon - a.lon);
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(rad(a.lat)) * Math.cos(rad(b.lat)) * Math.sin(dLon / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(h));
}

export function position(timeout = 8000) {
  return new Promise((res) => {
    if (!navigator.geolocation) return res(null);
    navigator.geolocation.getCurrentPosition(
      (p) => res({ lat: p.coords.latitude, lon: p.coords.longitude, accuracy: p.coords.accuracy }),
      () => res(null), { enableHighAccuracy: true, timeout, maximumAge: 30000 },
    );
  });
}
