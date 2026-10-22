'use client';

// Small ⓘ button that opens a plain-language explanation of a section.
import { useState } from 'react';

export default function Info({ title = 'What is this?', children }) {
  const [open, setOpen] = useState(false);
  return (
    <span className="info-wrap">
      <button type="button" className="info-btn" aria-expanded={open} aria-label={title} onClick={() => setOpen(!open)}>ⓘ</button>
      {open && (
        <span className="info-box" role="note">
          <strong>{title}</strong>
          <span>{children}</span>
          <button type="button" onClick={() => setOpen(false)}>Got it</button>
        </span>
      )}
    </span>
  );
}
