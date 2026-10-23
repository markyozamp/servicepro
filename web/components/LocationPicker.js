'use client';

// Location menu: shows the location you're looking at, every other location (with a red dot if something needs attention there),
// and "+ Add location". The pin blinks when any location needs attention (can be turned off).
import { useEffect, useState } from 'react';
import { usePlace } from '@/lib/terms';

export default function LocationPicker({ sites, attention, value, onChange, canAdd, onAdd }) {
  const place = usePlace();
  const [open, setOpen] = useState(false);
  const [blink, setBlink] = useState(true);
  useEffect(() => { try { setBlink(localStorage.getItem('scp_blink') !== '0'); } catch { /* fine */ } }, []);
  useEffect(() => {
    if (!open) return undefined;
    const close = (e) => { if (!e.target.closest('.locpick')) setOpen(false); };
    document.addEventListener('click', close);
    return () => document.removeEventListener('click', close);
  }, [open]);

  const why = (id) => attention.find((a) => a.site_id === id)?.reasons || [];
  const anyHot = value ? why(value).length > 0 : attention.some((a) => a.reasons.length);
  const current = sites.find((s) => s.id === value);
  const setBlinkPref = (v) => { setBlink(v); try { localStorage.setItem('scp_blink', v ? '1' : '0'); } catch { /* fine */ } };
  const hotCount = attention.filter((a) => a.reasons.length).length;

  return (
    <div className="locpick">
      <button type="button" className={`locpick-btn${anyHot ? ' hot' : ''}${anyHot && blink ? ' blink' : ''}`} aria-expanded={open} onClick={() => setOpen(!open)}
        title={anyHot ? 'Something needs attention' : ''}>
        <svg className="pin" viewBox="0 0 24 24" width="18" height="18" aria-hidden="true"><path d="M12 2a7 7 0 0 0-7 7c0 5.2 7 13 7 13s7-7.8 7-13a7 7 0 0 0-7-7z" /><circle cx="12" cy="9" r="2.6" fill="#fff" /></svg>
        <span>{current ? current.name : sites.length > 1 ? `All ${place.many} (${sites.length})` : sites[0]?.name || place.Many}</span>
        {hotCount > 0 && !value && <span className="chip tone-red">{hotCount} need{hotCount === 1 ? 's' : ''} attention</span>}
        <span aria-hidden="true">▾</span>
      </button>
      {open && (
        <div className="locpick-menu" role="menu">
          {sites.length > 1 && (
            <button role="menuitem" className={!value ? 'on' : ''} onClick={() => { onChange(''); setOpen(false); }}>
              <span>All {place.many}</span>{hotCount > 0 && <span className="dot" />}
            </button>
          )}
          {sites.map((s) => {
            const r = why(s.id);
            return (
              <button key={s.id} role="menuitem" className={value === s.id ? 'on' : ''} onClick={() => { onChange(s.id); setOpen(false); }}>
                <span><strong>{s.name}</strong>{r.length > 0 && <span className="small" style={{ color: 'var(--red-fg)' }}>{r.join(' · ')}</span>}</span>
                {r.length > 0 && <span className="dot" />}
              </button>
            );
          })}
          {canAdd && <button role="menuitem" className="add" onClick={() => { setOpen(false); onAdd(); }}>+ Add location</button>}
          <label className="row small blinkpref"><input type="checkbox" style={{ width: 'auto' }} checked={blink} onChange={(e) => setBlinkPref(e.target.checked)} />Blink the pin when a location needs attention</label>
        </div>
      )}
    </div>
  );
}
