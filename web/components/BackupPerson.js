'use client';

// Who gets it when nobody at this location answers: the reminder goes to the location's people first, then to
// this person (urgent: after 30 min; routine: the next morning). Not set: your company's admins.
import { useState } from 'react';
import { act } from '@/lib/supabase';

export default function BackupPerson({ siteId, siteName, value, team, onSaved }) {
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState('');
  const [err, setErr] = useState('');
  async function pick(id) {
    setBusy(true); setErr(''); setMsg('');
    try {
      const r = await act('set_site_backup', { p_site: siteId, p_profile: id || null });
      setMsg(id ? `Saved. If nobody at ${siteName} answers, it goes to ${r?.name}.` : 'Saved. If nobody answers, it goes to your admins.');
      onSaved?.();
    } catch (x) { setErr(x.message); } finally { setBusy(false); }
  }
  return (
    <div className="stack" style={{ gap: 4 }}>
      <label className="small">If nobody here answers, send it to
        <select value={value || ''} disabled={busy} onChange={(e) => pick(e.target.value)} style={{ width: 'auto', marginLeft: 8 }}>
          <option value="">Our admins (default)</option>
          {(team || []).map((p) => <option key={p.id} value={p.id}>{p.full_name}{p.title ? ` (${p.title})` : ''}</option>)}
        </select>
      </label>
      <div className="small muted">Things waiting on {siteName} (a tech&apos;s crew, a return-trip time, an approval) get a reminder first: after 15 minutes if urgent, 4 hours if not. Still no answer: it goes to this person, after 30 minutes or the next morning.</div>
      {err && <div className="error">{err}</div>}
      {msg && <div className="notice small">{msg}</div>}
    </div>
  );
}
