'use client';

// Contractor side: pick a customer or one of its stores (filters the whole office screen). Red dot + reasons where something needs
// attention; the pin blinks when anything does (same "Blink" setting as the store side, per device).
import { useEffect, useState } from 'react';

export const pickMatch = (pick, customerId, siteId) => !pick
  || (pick.startsWith('c:') && pick.slice(2) === customerId) || (pick.startsWith('s:') && pick.slice(2) === siteId);

export default function CustomerPicker({ book, value, onChange }) {
  const [open, setOpen] = useState(false);
  const [blink, setBlink] = useState(true);
  useEffect(() => { try { setBlink(localStorage.getItem('scp_blink') !== '0'); } catch { /* fine */ } }, []);
  useEffect(() => {
    if (!open) return undefined;
    const close = (e) => { if (!e.target.closest('.locpick')) setOpen(false); };
    document.addEventListener('click', close);
    return () => document.removeEventListener('click', close);
  }, [open]);
  const setBlinkPref = (v) => { setBlink(v); try { localStorage.setItem('scp_blink', v ? '1' : '0'); } catch { /* fine */ } };

  const custReasons = (c) => [...new Set(c.sites.flatMap((s) => s.reasons))];
  const hotCustomers = book.filter((c) => custReasons(c).length);
  const cur = value?.startsWith('c:') ? book.find((c) => c.customer_id === value.slice(2)) : null;
  const curSite = value?.startsWith('s:') ? book.flatMap((c) => c.sites.map((s) => ({ ...s, customer: c.name }))).find((s) => s.site_id === value.slice(2)) : null;
  const anyHot = cur ? custReasons(cur).length > 0 : curSite ? curSite.reasons.length > 0 : hotCustomers.length > 0;
  const label = cur ? cur.name : curSite ? `${curSite.customer} · ${curSite.name}` : `All customers (${book.length})`;

  return (
    <div className="locpick">
      <button type="button" className={`locpick-btn${anyHot ? ' hot' : ''}${anyHot && blink ? ' blink' : ''}`} aria-expanded={open} onClick={() => setOpen(!open)}
        title={anyHot ? 'A customer needs attention' : ''}>
        <svg className="pin" viewBox="0 0 24 24" width="18" height="18" aria-hidden="true"><path d="M12 2a7 7 0 0 0-7 7c0 5.2 7 13 7 13s7-7.8 7-13a7 7 0 0 0-7-7z" /><circle cx="12" cy="9" r="2.6" fill="#fff" /></svg>
        <span>{label}</span>
        {!value && hotCustomers.length > 0 && <span className="chip tone-red">{hotCustomers.length} need{hotCustomers.length === 1 ? 's' : ''} attention</span>}
        <span aria-hidden="true">▾</span>
      </button>
      {open && (
        <div className="locpick-menu custpick" role="menu">
          <button role="menuitem" className={!value ? 'on' : ''} onClick={() => { onChange(''); setOpen(false); }}>
            <span>All customers</span>{hotCustomers.length > 0 && <span className="dot" />}
          </button>
          {book.length === 0 && <div className="small muted" style={{ padding: '8px 10px' }}>No customers yet. Stores add you when they invite you.</div>}
          {book.map((c) => {
            const r = custReasons(c);
            return (
              <div key={c.customer_id} className="custpick-group">
                <button role="menuitem" className={value === `c:${c.customer_id}` ? 'on' : ''} onClick={() => { onChange(`c:${c.customer_id}`); setOpen(false); }}>
                  <span><strong>{c.name}</strong><span className="small muted">{c.sites.length} store{c.sites.length === 1 ? '' : 's'}{c.open_calls ? ` · ${c.open_calls} open` : ''}</span></span>
                  {r.length > 0 && <span className="dot" />}
                </button>
                {c.sites.length > 1 && c.sites.map((s) => (
                  <button key={s.site_id} role="menuitem" className={`sub${value === `s:${s.site_id}` ? ' on' : ''}`} onClick={() => { onChange(`s:${s.site_id}`); setOpen(false); }}>
                    <span>{s.name}{s.reasons.length > 0 && <span className="small" style={{ color: 'var(--red-fg)' }}>{s.reasons.join(' · ')}</span>}</span>
                    {s.reasons.length > 0 && <span className="dot" />}
                  </button>
                ))}
                {c.sites.length === 1 && r.length > 0 && <div className="small sub-why">{r.join(' · ')}</div>}
              </div>
            );
          })}
          <label className="row small blinkpref"><input type="checkbox" style={{ width: 'auto' }} checked={blink} onChange={(e) => setBlinkPref(e.target.checked)} />Blink the pin when a customer needs attention</label>
        </div>
      )}
    </div>
  );
}
