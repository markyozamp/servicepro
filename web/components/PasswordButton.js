'use client';

// "Password" in the top bar: set or change the password for this login.
import { useState } from 'react';
import { createPortal } from 'react-dom';
import { supabase } from '@/lib/supabase';

export default function PasswordButton() {
  const [open, setOpen] = useState(false);
  const [pw, setPw] = useState('');
  const [pw2, setPw2] = useState('');
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState('');
  const [err, setErr] = useState('');

  async function save(e) {
    e.preventDefault();
    setErr(''); setMsg('');
    if (pw.length < 10) return setErr('Use at least 10 characters.');
    if (pw !== pw2) return setErr('The two passwords don\'t match.');
    setBusy(true);
    const { error } = await supabase.auth.updateUser({ password: pw });
    setBusy(false);
    if (error) return setErr(error.message);
    setPw(''); setPw2(''); setMsg('Password saved. Use it with your email to sign in on any device.');
  }

  return (
    <>
      <button onClick={() => { setOpen(true); setMsg(''); setErr(''); }}>Password</button>
      {open && createPortal(
        <>
          <div className="scrim" onClick={() => setOpen(false)} />
          <aside className="drawer" role="dialog" aria-label="Set your password" style={{ width: 'min(420px, 100vw)', color: 'var(--ink)' }}>
            <div className="drawer-head row" style={{ justifyContent: 'space-between' }}>
              <h2 style={{ margin: 0 }}>Set your password</h2>
              <button onClick={() => setOpen(false)}>Close</button>
            </div>
            <form className="drawer-body" onSubmit={save}>
              <div className="small muted">Pick a password you'll remember. Your sign-in is your email address and this password.</div>
              {err && <div className="error">{err}</div>}
              {msg && <div className="notice">{msg}</div>}
              <label>New password
                <input id="pw-new" type="password" autoComplete="new-password" value={pw} onChange={(e) => setPw(e.target.value)} required />
              </label>
              <label>Type it again
                <input id="pw-again" type="password" autoComplete="new-password" value={pw2} onChange={(e) => setPw2(e.target.value)} required />
              </label>
              <button className="primary big" disabled={busy}>{busy ? 'Saving…' : 'Save password'}</button>
            </form>
          </aside>
        </>,
        document.body
      )}
    </>
  );
}
