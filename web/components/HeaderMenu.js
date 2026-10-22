'use client';

// Header buttons: shown in a row on wide screens; on phones they fold into a "Menu" that opens below the header,
// so nothing squeezes into or spills out of the dark bar.
import { useEffect, useState } from 'react';

export default function HeaderMenu({ name, children }) {
  const [open, setOpen] = useState(false);
  useEffect(() => {
    if (!open) return undefined;
    const close = (e) => { if (!e.target.closest('.hdr-menu')) setOpen(false); };
    document.addEventListener('click', close);
    return () => document.removeEventListener('click', close);
  }, [open]);
  return (
    <div className={`hdr-menu who${open ? ' open' : ''}`}>
      {name && <span className="hdr-name">{name}</span>}
      <button type="button" className="hdr-toggle" aria-expanded={open} onClick={() => setOpen(!open)}>{open ? 'Close' : 'Menu'}</button>
      <div className="hdr-items" onClick={(e) => { if (e.target.closest('button') && !e.target.closest('[data-keep]')) setOpen(false); }}>{children}</div>
    </div>
  );
}
