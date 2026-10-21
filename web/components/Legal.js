// Shared bits for the Privacy Policy and Terms of Service pages.
import Link from 'next/link';

// Fill these in once settled (see BUILD_PLAN §22). They appear on both pages.
export const LEGAL = {
  operator: 'Service Call Proof',          // replace with the owning company's legal name, e.g. "XYZ LLC, doing business as Service Call Proof"
  email: 'support@servicecallproof.com',
  site: 'servicecallproof.com',
  state: 'Idaho',
  county: 'Kootenai County',
  effective: 'October 20, 2026',
};

export function LegalFooter() {
  return (
    <div className="small muted" style={{ textAlign: 'center', marginTop: 12 }}>
      <Link href="/privacy">Privacy</Link> · <Link href="/terms">Terms</Link>
    </div>
  );
}

export function LegalPage({ title, children }) {
  return (
    <main style={{ maxWidth: 760, margin: '0 auto', padding: '24px 16px 48px' }}>
      <div style={{ marginBottom: 16 }}>
        <Link href="/" className="brand" style={{ fontSize: 22, color: 'var(--ink)', textDecoration: 'none' }}>
          Service Call <span style={{ color: 'var(--brand)' }}>Proof</span>
        </Link>
      </div>
      <article className="panel panel-pad legal">
        <h1 style={{ marginTop: 0 }}>{title}</h1>
        <p className="muted small">Effective {LEGAL.effective}</p>
        {children}
      </article>
      <div className="small muted" style={{ textAlign: 'center', marginTop: 16 }}>
        <Link href="/privacy">Privacy Policy</Link> · <Link href="/terms">Terms of Service</Link> · <a href={`mailto:${LEGAL.email}`}>{LEGAL.email}</a>
      </div>
    </main>
  );
}
