'use client';

// Browser tab indicator: "(3) Name · Service Call Proof" plus a red dot on the tab icon when something is waiting.
// With an urgent message (a technician at the door) the tab title flashes.
import { useEffect, useRef } from 'react';

const BASE_ICON = '/icon-192.png';

function setIcon(href) {
  let link = document.querySelector('link[rel="icon"][data-badge]');
  if (!link) {
    document.querySelectorAll('link[rel~="icon"]').forEach((l) => l.parentNode.removeChild(l));
    link = document.createElement('link');
    link.rel = 'icon';
    link.setAttribute('data-badge', '1');
    document.head.appendChild(link);
  }
  link.href = href;
}

function badgedIcon(count) {
  return new Promise((resolve) => {
    const img = new Image();
    img.onload = () => {
      const c = document.createElement('canvas');
      c.width = 64; c.height = 64;
      const g = c.getContext('2d');
      g.drawImage(img, 0, 0, 64, 64);
      g.beginPath(); g.arc(46, 18, 17, 0, Math.PI * 2); g.fillStyle = '#d93025'; g.fill();
      g.lineWidth = 3; g.strokeStyle = '#ffffff'; g.stroke();
      g.fillStyle = '#ffffff'; g.font = 'bold 22px Arial, sans-serif'; g.textAlign = 'center'; g.textBaseline = 'middle';
      g.fillText(count > 9 ? '9+' : String(count), 46, 19);
      resolve(c.toDataURL('image/png'));
    };
    img.onerror = () => resolve(BASE_ICON);
    img.src = BASE_ICON;
  });
}

export function useTabBadge(name, count, urgent) {
  const timer = useRef(null);
  useEffect(() => {
    const base = `${name ? `${name} · ` : ''}Service Call Proof`;
    const plain = count > 0 ? `(${count}) ${base}` : base;
    document.title = plain;
    if (count > 0) badgedIcon(count).then(setIcon); else setIcon(BASE_ICON);
    clearInterval(timer.current);
    if (urgent) {
      let on = false;
      timer.current = setInterval(() => { on = !on; document.title = on ? `⚠ ${urgent}` : plain; }, 1200);
    }
    return () => clearInterval(timer.current);
  }, [name, count, urgent]);
  useEffect(() => () => { document.title = 'Service Call Proof'; setIcon(BASE_ICON); }, []);
}
