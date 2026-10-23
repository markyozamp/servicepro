'use client';

// Who on the team sees one location. Shown right after a location is added, and from each location's settings.
// People with "All locations" see it automatically.
import { useEffect, useState } from 'react';
import { act } from '@/lib/supabase';
import { ErrorBox } from './bits';

export default function SiteAccess({ siteId, siteName, isNew = false, onDone }) {
  const [people, setPeople] = useState(null);
  const [pick, setPick] = useState([]);
  const [err, setErr] = useState('');
  const [saved, setSaved] = useState('');
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    act('site_access', { p_site: siteId }).then((r) => { setPeople(r); setPick(r.filter((p) => !p.automatic && p.sees).map((p) => p.id)); })
      .catch((e) => setErr(e.message));
  }, [siteId]);

  if (err) {
    return (
      <div className="notice small">
        {err.includes('permission') ? `Only someone who manages your team can choose who sees ${siteName}. Ask your admin to tick it for the right people under Team.` : err}
        {onDone && <div><button className="linkbtn" onClick={onDone}>OK</button></div>}
      </div>
    );
  }
  if (!people) return <div className="small muted">Loading your team…</div>;
  const auto = people.filter((p) => p.automatic);
  const others = people.filter((p) => !p.automatic);

  async function save() {
    setBusy(true); setErr(''); setSaved('');
    try { const r = await act('set_site_access', { p_site: siteId, p_profiles: pick }); setSaved(`Saved. ${r.people} ${r.people === 1 ? 'person sees' : 'people see'} ${siteName}.`); if (isNew) onDone?.(); }
    catch (e) { setErr(e.message); } finally { setBusy(false); }
  }

  return (
    <div className="stack" style={{ gap: 8, border: '1px solid var(--line)', borderRadius: 10, padding: 12, background: isNew ? 'var(--brand-soft)' : undefined }}>
      <strong>{isNew ? `Who on your team should see ${siteName}?` : `Who sees ${siteName}`}</strong>
      {auto.length > 0 && <div className="small muted">Sees it automatically (all locations): {auto.map((p) => p.name).join(', ')}</div>}
      {others.length === 0
        ? <div className="small muted">Everyone on your team already sees all locations.</div>
        : others.map((p) => (
          <label key={p.id} className="row small" style={{ gap: 6, fontWeight: 400 }}>
            <input type="checkbox" style={{ width: 'auto' }} checked={pick.includes(p.id)}
              onChange={(e) => setPick(e.target.checked ? [...pick, p.id] : pick.filter((x) => x !== p.id))} />
            <span><strong>{p.name}</strong>{p.title ? <span className="muted"> · {p.title}</span> : null}</span>
          </label>
        ))}
      <ErrorBox error={err} />
      {saved && <div className="small" style={{ color: 'var(--green-fg, #1d6b3c)' }}>{saved}</div>}
      <div className="row">
        {others.length > 0 && <button className="primary" disabled={busy} onClick={save}>Save</button>}
        {onDone && <button type="button" onClick={onDone}>{isNew && others.length > 0 ? 'Skip for now' : 'Close'}</button>}
      </div>
    </div>
  );
}
