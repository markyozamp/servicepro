'use client';

// A row that scrolls sideways on small screens, with a visible cue: a fade and a ‹ › arrow on whichever side has more.
import { useEffect, useRef, useState } from 'react';

export default function ScrollRow({ className = '', children, style }) {
  const ref = useRef(null);
  const [more, setMore] = useState({ left: false, right: false });
  useEffect(() => {
    const el = ref.current;
    if (!el) return undefined;
    const check = () => setMore({ left: el.scrollLeft > 4, right: el.scrollLeft + el.clientWidth < el.scrollWidth - 4 });
    check();
    el.addEventListener('scroll', check, { passive: true });
    const ro = typeof ResizeObserver !== 'undefined' ? new ResizeObserver(check) : null;
    ro?.observe(el);
    window.addEventListener('resize', check);
    return () => { el.removeEventListener('scroll', check); ro?.disconnect(); window.removeEventListener('resize', check); };
  }, []);
  // Keep the selected item in view
  // (moves only this row sideways, never the page)
  const onKey = ref.current?.querySelector('.on')?.textContent;
  useEffect(() => {
    const el = ref.current; const on = el?.querySelector('.on');
    if (!el || !on || el.scrollWidth <= el.clientWidth) return;
    const l = on.offsetLeft - el.offsetLeft, r = l + on.offsetWidth;
    if (l < el.scrollLeft) el.scrollLeft = l - 24;
    else if (r > el.scrollLeft + el.clientWidth) el.scrollLeft = r - el.clientWidth + 24;
  }, [onKey]);
  const nudge = (dir) => ref.current?.scrollBy({ left: dir * ref.current.clientWidth * 0.7, behavior: 'smooth' });
  return (
    <div className={`scrollrow${more.left ? ' more-left' : ''}${more.right ? ' more-right' : ''}`} style={style}>
      <div ref={ref} className={`scrollrow-inner ${className}`}>{children}</div>
      {more.left && <button type="button" className="scrollrow-arrow left" aria-label="Scroll left" onClick={() => nudge(-1)}>‹</button>}
      {more.right && <button type="button" className="scrollrow-arrow right" aria-label="More — scroll right" onClick={() => nudge(1)}>›</button>}
    </div>
  );
}
