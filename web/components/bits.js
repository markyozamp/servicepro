'use client';

import { STATUS, PRIORITY, minutesUntil, time, date, daysUntil } from '@/lib/format';

export function StatusChip({ status }) {
  const s = STATUS[status] || { label: status, tone: 'slate' };
  return <span className={`chip tone-${s.tone}`}>{s.label}</span>;
}

export function PriorityChip({ priority }) {
  if (priority === 1) return <span className="chip tone-red">⚠ {PRIORITY[1]}</span>;
  if (priority === 3) return <span className="chip tone-slate">{PRIORITY[3]}</span>;
  return null;
}

export function KindChip({ kind }) {
  if (kind === 'pm') return <span className="chip tone-green">PM</span>;
  if (kind === 'install') return <span className="chip tone-violet">Install</span>;
  return null;
}

// What's happening right now on a job, from its latest visit
export function LiveLine({ wo, visit }) {
  if (wo.status === 'waiting_parts') return <span className="small">Waiting for parts</span>;
  if (!visit) return null;
  if (visit.status === 'assigned' && !visit.received_at) return <span className="small muted">Not yet received by tech</span>;
  if (visit.status === 'en_route' && visit.eta_at) {
    const m = minutesUntil(visit.eta_at);
    return <span className="small"><strong>ETA {time(visit.eta_at)}</strong>{m != null && m > 0 ? <span className="muted"> · {m} min</span> : null}</span>;
  }
  if (visit.status === 'en_route') return <span className="small muted">On the way</span>;
  if (visit.status === 'on_site') return <span className="small muted">Arrived {time(visit.arrived_at)}{visit.checkin_required && !visit.checkin_at ? ' · not checked in yet' : ''}</span>;
  return null;
}

export function BillLine({ wo }) {
  if (wo.status !== 'completed' || !wo.invoice_due_at) return null;
  const d = daysUntil(wo.invoice_due_at);
  if (d < 0) return <span className="chip tone-red">Bill late · due {date(wo.invoice_due_at)}</span>;
  return <span className="small muted">Bill pending · due {date(wo.invoice_due_at)}</span>;
}

export function ErrorBox({ error }) {
  return error ? <div className="error">{error}</div> : null;
}

export function Notice({ children }) {
  return children ? <div className="notice">{children}</div> : null;
}
