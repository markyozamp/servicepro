'use client';

// Settings → Team: the store company's own people. One login comes with each location; the admin picks who sees which stores.
import { useEffect, useState } from 'react';
import { supabase, act, q } from '@/lib/supabase';
import { money } from '@/lib/format';
import { ErrorBox, Notice } from './bits';
import Info from './Info';

const blank = { name: '', email: '', phone: '', title: '', admin: false, calls: true, approve: true, limit: '', equipment: false, contractors: false, locations: false, team: false, company: false, all: false, sites: [] };
const PERMS = [
  ['calls', 'Open service calls'],
  ['equipment', 'Add and change equipment'],
  ['contractors', 'Contractors & QR (invite contractors, set rules, store PIN)'],
  ['locations', 'Locations (add and edit locations, backup code, Wi-Fi)'],
  ['team', 'Team (add and change people)'],
  ['company', 'Settings & plan (company profile, logo, plan, your data)'],
];
const permsOf = (p) => ({ calls: p.can_open_calls, approve: p.can_approve, equipment: p.can_manage_equipment || p.can_manage_pm,
  contractors: p.can_manage_contractors, locations: p.can_manage_locations, team: p.can_manage_team, company: p.can_manage_company });
const summary = (p) => (p.is_org_admin ? 'Admin: everything' : PERMS.filter(([k]) => permsOf(p)[k]).map(([, l]) => l.split(' (')[0]).join(', ') || 'View only');

export default function StoreTeam({ me }) {
  const [people, setPeople] = useState([]);
  const [sites, setSites] = useState([]);
  const [seats, setSeats] = useState(null);
  const [pending, setPending] = useState([]);
  const [form, setForm] = useState(null);       // add or edit
  const [sent, setSent] = useState(null);
  const [err, setErr] = useState('');
  const [msg, setMsg] = useState('');
  const [busy, setBusy] = useState(false);

  async function load() {
    try {
      const [p, s, si, l] = await Promise.all([
        q(supabase.from('profiles').select('id, full_name, title, email, phone, is_org_admin, can_open_calls, can_approve, approval_limit, can_manage_pm, can_manage_equipment, can_manage_contractors, can_manage_locations, can_manage_team, can_manage_company, all_sites, site_ids, active').eq('customer_id', me.customer_id).order('full_name')),
        q(supabase.from('sites').select('id, name').order('name')),
        act('seat_info', {}),
        q(supabase.from('join_links').select('token, full_name, email, expires_at, used_at').eq('kind', 'customer_member').is('used_at', null).order('created_at', { ascending: false })),
      ]);
      setPeople(p); setSites(s); setSeats(si); setPending(l.filter((x) => new Date(x.expires_at) > new Date()));
    } catch (x) { setErr(x.message); }
  }
  useEffect(() => { load(); }, []); // eslint-disable-line react-hooks/exhaustive-deps

  const link = (t) => `${window.location.origin}/join/${t}`;
  const siteNames = (p) => (p.all_sites || p.is_org_admin ? 'All locations' : sites.filter((s) => (p.site_ids || []).includes(s.id)).map((s) => s.name).join(', ') || 'No locations');
  const full = false; // logins are unlimited

  const permsJson = (f) => ({ admin: f.admin, calls: f.calls, approve: f.approve, limit: f.approve && f.limit !== '' ? String(f.limit) : '',
    equipment: f.equipment, contractors: f.contractors, locations: f.locations, team: f.team, company: f.company });

  async function save(e) {
    e.preventDefault();
    setBusy(true); setErr(''); setMsg('');
    try {
      if (form.id) {
        await act('update_team_member', { p_profile: form.id, p_title: form.title, p_perms: permsJson(form), p_all_sites: form.all, p_site_ids: form.all ? [] : form.sites, p_active: true });
        setMsg(`Saved ${form.name}.`);
      } else {
        const r = await act('invite_team_member', { p_name: form.name, p_email: form.email, p_phone: form.phone, p_title: form.title,
          p_perms: permsJson(form), p_all_sites: form.all, p_site_ids: form.all ? [] : form.sites });
        setSent({ token: r.token, name: form.name, email: form.email, phone: form.phone });
      }
      setForm(null);
      await load();
    } catch (x) { setErr(x.message); } finally { setBusy(false); }
  }

  async function deactivate(p) {
    setBusy(true); setErr(''); setMsg('');
    try {
      const f = { admin: p.is_org_admin, ...permsOf(p), limit: p.approval_limit ?? '' };
      await act('update_team_member', { p_profile: p.id, p_title: p.title, p_perms: permsJson(f), p_all_sites: p.all_sites, p_site_ids: p.site_ids || [], p_active: !p.active });
      setMsg(p.active ? `${p.full_name} can no longer sign in. Their login is free for someone else.` : `${p.full_name} can sign in again.`);
      await load();
    } catch (x) { setErr(x.message); } finally { setBusy(false); }
  }

  return (
    <div className="stack">
      <div className="spread">
        <h3>Your team <Info title="Your team">{`Add the people at your company who use Service Call Proof: store managers, a director of maintenance, a facilities person. Add as many people as you need; logins are included in your plan. You choose which locations each person sees and how much they can approve. Your contractors and their technicians don't use these logins; they're free.`}</Info></h3>
        {seats && <span className="chip tone-slate">{seats.used} {seats.used === 1 ? 'person' : 'people'}</span>}
      </div>
      <ErrorBox error={err} /><Notice>{msg}</Notice>

      {sent && (
        <div className="notice stack" style={{ gap: 6 }}>
          <div>Send this sign-in link to <strong>{sent.name}</strong> (works once, for 7 days). They'll set their own password after signing in.</div>
          <input readOnly value={link(sent.token)} onFocus={(e) => e.target.select()} />
          <div className="row">
            <button onClick={() => navigator.clipboard?.writeText(link(sent.token)).then(() => setMsg('Link copied.')).catch(() => {})}>Copy link</button>
            {sent.email && <a href={`mailto:${sent.email}?subject=${encodeURIComponent('Your Service Call Proof sign-in')}&body=${encodeURIComponent(`Hi ${sent.name},\n\nYou've been added to our Service Call Proof account. Tap to sign in, then set your password under Menu → Password:\n${link(sent.token)}\n\nThanks`)}`}><button type="button">Email it</button></a>}
            {sent.phone && <a href={`sms:${sent.phone}?&body=${encodeURIComponent(`Your Service Call Proof sign-in: ${link(sent.token)}`)}`}><button type="button">Text it</button></a>}
            <button onClick={() => setSent(null)}>Done</button>
          </div>
        </div>
      )}

      <table>
        <thead><tr><th>Person</th><th className="hide-sm">Sees</th><th>Can</th><th /></tr></thead>
        <tbody>
          {people.map((p) => (
            <tr key={p.id} style={p.active ? undefined : { opacity: 0.55 }}>
              <td><strong>{p.full_name}</strong>{p.id === me.id ? ' (you)' : ''}<div className="small muted">{p.title || ''}{p.is_org_admin ? ' · Admin' : ''}{!p.active ? ' · signed out' : ''}</div><div className="small muted">{p.email}</div></td>
              <td className="hide-sm small">{siteNames(p)}</td>
              <td className="small">{summary(p)}{!p.is_org_admin && <div className="muted">{p.can_approve ? `Approves ${p.approval_limit != null ? `up to ${money(p.approval_limit)}` : 'any amount'}` : 'Does not approve spending'}</div>}</td>
              <td className="num">{p.id !== me.id && (
                <div className="row" style={{ justifyContent: 'flex-end', gap: 6 }}>
                  {p.active && (me.is_org_admin || !p.is_org_admin) && <button disabled={busy} onClick={() => setForm({ id: p.id, name: p.full_name, email: p.email, phone: p.phone || '', title: p.title || '', admin: p.is_org_admin,
                    ...permsOf(p), limit: p.approval_limit ?? '', all: p.all_sites, sites: p.site_ids || [] })}>Edit</button>}
                  {(me.is_org_admin || !p.is_org_admin) && <button disabled={busy} onClick={() => deactivate(p)}>{p.active ? 'Remove' : 'Restore'}</button>}
                </div>
              )}</td>
            </tr>
          ))}
          {pending.map((l) => (
            <tr key={l.token}><td><strong>{l.full_name}</strong><div className="small muted">{l.email} · invited, not signed in yet</div></td><td className="hide-sm" /><td /><td className="num"><button onClick={() => setSent({ token: l.token, name: l.full_name, email: l.email })}>Show link</button></td></tr>
          ))}
        </tbody>
      </table>

      {form ? (
        <form className="stack" style={{ gap: 8, border: '1px solid var(--line)', borderRadius: 10, padding: 12 }} onSubmit={save}>
          <h3>{form.id ? `Edit ${form.name}` : 'Add a person'}</h3>
          {!form.id && (
            <>
              <div className="row">
                <label className="grow">Name<input id="tm-name" value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} required /></label>
                <label className="grow">Job title<input id="tm-title" value={form.title} onChange={(e) => setForm({ ...form, title: e.target.value })} placeholder="e.g. Store manager" /></label>
              </div>
              <div className="row">
                <label className="grow">Email (their sign-in)<input id="tm-email" type="email" value={form.email} onChange={(e) => setForm({ ...form, email: e.target.value })} required /></label>
                <label className="grow">Mobile<input id="tm-phone" type="tel" value={form.phone} onChange={(e) => setForm({ ...form, phone: e.target.value })} /></label>
              </div>
            </>
          )}
          {form.id && <label>Job title<input id="tm-title-e" value={form.title} onChange={(e) => setForm({ ...form, title: e.target.value })} /></label>}
          {me.is_org_admin && <label className="row small" style={{ gap: 6, fontWeight: 400 }}><input type="checkbox" style={{ width: 'auto' }} checked={form.admin} onChange={(e) => setForm({ ...form, admin: e.target.checked, all: e.target.checked || form.all })} />
            <strong>Admin</strong>: can do everything below, sees every location, manages your plan</label>}
          {!form.admin && (
            <div className="stack" style={{ gap: 4 }}>
              <div className="small"><strong>What can they do?</strong> <span className="muted">Everyone can see calls at their locations.</span></div>
              {PERMS.map(([k, label]) => (
                <label key={k} className="row small" style={{ gap: 6, fontWeight: 400 }}><input type="checkbox" style={{ width: 'auto' }} checked={!!form[k]} onChange={(e) => setForm({ ...form, [k]: e.target.checked })} />{label}</label>
              ))}
            </div>
          )}
          <label className="row small" style={{ gap: 6, fontWeight: 400 }}><input type="checkbox" style={{ width: 'auto' }} checked={form.approve} onChange={(e) => setForm({ ...form, approve: e.target.checked })} />
            Approve spending (quotes and PO increases)</label>
          {form.approve && <label>Approves up to ($) <span className="muted" style={{ fontWeight: 400 }}>— leave blank for any amount; above it goes up to the next person</span>
            <input id="tm-limit" type="number" min="0" step="any" value={form.limit} onChange={(e) => setForm({ ...form, limit: e.target.value })} placeholder="e.g. 500" /></label>}
          {!form.admin && (
            <div className="stack" style={{ gap: 4 }}>
              <div className="small"><strong>Which locations do they see?</strong></div>
              <label className="row small" style={{ gap: 6, fontWeight: 400 }}><input type="checkbox" style={{ width: 'auto' }} checked={form.all} onChange={(e) => setForm({ ...form, all: e.target.checked })} />All locations (including ones you add later)</label>
              {!form.all && <div className="row" style={{ gap: 10 }}>
                {sites.map((s) => (
                  <label key={s.id} className="row small" style={{ gap: 4, fontWeight: 400 }}>
                    <input type="checkbox" style={{ width: 'auto' }} checked={form.sites.includes(s.id)}
                      onChange={(e) => setForm({ ...form, sites: e.target.checked ? [...form.sites, s.id] : form.sites.filter((x) => x !== s.id) })} />{s.name}
                  </label>
                ))}
              </div>}
            </div>
          )}
          <div className="row"><button className="primary" disabled={busy}>{form.id ? 'Save' : 'Create sign-in link'}</button><button type="button" onClick={() => setForm(null)}>Cancel</button></div>
        </form>
      ) : (
        <div className="row">
          <button disabled={full} onClick={() => { setForm({ ...blank }); setSent(null); }}>+ Add a person</button>
        </div>
      )}
    </div>
  );
}
