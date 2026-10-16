'use client';

import { STATUS, PRIORITY, minutesUntil, time } from '@/lib/format';

export function StatusChip({ status }) {
  const s = STATUS[status] || { label: status, tone: 'slate' };
  return <span className={`chip tone-${s.tone}`}>{s.label}</span>;
}

export function PriorityChip({ priority }) {
  if (priority === 1) return <span className="chip tone-red">⚠ {PRIORITY[1]}</span>;
  if (priority === 3) return <span className="chip tone-slate">{PRIORITY[3]}</span>;
  return null;
}

export function EtaText({ wo }) {
  if (wo.status === 'en_route' && wo.eta_at) {
    const m = minutesUntil(wo.eta_at);
    return <span className="small"><strong>ETA {time(wo.eta_at)}</strong>{m != null && m > 0 ? <span className="muted"> · {m} min</span> : null}</span>;
  }
  if (wo.status === 'en_route') return <span className="small muted">On the way</span>;
  if (wo.arrived_at && ['on_site', 'awaiting_approval'].includes(wo.status))
    return <span className="small muted">Arrived {time(wo.arrived_at)}</span>;
  return null;
}

export function ErrorBox({ error }) {
  return error ? <div className="error">{error}</div> : null;
}
