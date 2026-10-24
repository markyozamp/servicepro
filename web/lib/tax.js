// Sales tax / use tax on bill and quote lines (same rules as the database's _tax_calc).
//   sales = taxed: sales tax on the price, shown to the customer
//   use   = built in (becomes part of the building): no tax on the bill; use tax on the contractor's cost
//   none  = not taxed
export const TAX_OPTS = [['sales', 'Taxed'], ['use', 'Built-in (use tax)'], ['none', 'No tax']];

export function defaultTax(kind, area) {
  if (['labor', 'after_hours', 'helper', 'flat'].includes(kind)) return area?.labor ? 'sales' : 'none';
  if (kind === 'trip') return area?.trip ? 'sales' : 'none';
  return 'sales';
}

const r2 = (n) => Math.round(n * 100) / 100;
export const lineAmount = (l) => (l.rate === '' || l.rate == null ? null : r2(Number(l.qty || 0) * Number(l.rate)));

// tax: the server's tax object ({ on, area, rate, exempt, ... })
export function taxTotals(lines, tax) {
  const area = tax?.area || null;
  const rate = Number(area?.rate || 0);
  let subtotal = 0, taxable = 0, useBasis = 0, noCost = 0;
  for (const l of lines) {
    const a = lineAmount(l) || 0;
    const t = l.tax || defaultTax(l.kind, area);
    subtotal += a;
    if (t === 'sales') taxable += a;
    if (t === 'use') { if (l.cost === '' || l.cost == null) noCost += 1; else useBasis += r2(Number(l.qty || 0) * Number(l.cost)); }
  }
  const live = !!(tax?.on && area);
  const salesTax = live && !tax?.exempt ? r2(taxable * rate / 100) : 0;
  const useTax = live ? r2(useBasis * rate / 100) : 0;
  return { subtotal: r2(subtotal), taxable: r2(taxable), salesTax, useBasis: r2(useBasis), useTax, noCost, total: r2(subtotal + salesTax),
    missing: !!(tax?.on && !area && taxable > 0 && !tax?.exempt), rate, area, exempt: !!tax?.exempt, on: !!tax?.on };
}

export const pct = (n) => `${Number(n || 0).toFixed(3).replace(/\.?0+$/, '')}%`;
