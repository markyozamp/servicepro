// End-to-end: Time Verify on the live site — store PO call → office accepts → tech I'm going / I'm here /
// code / parts run / Leaving → office invoice → store invoice check + PO log → QR report → sign-in link.
import { chromium, devices } from 'playwright';
const SITE = process.env.SITE || 'https://servicepro-two.vercel.app';
const U = 'https://svaoljxdoaefdqvvshhv.supabase.co', K = 'sb_publishable_KqvxfxaerUNeBkVQvwhvZQ_HFviMsbL';
const PW = 'DemoService2026!';
const log = (...a) => console.log(...a);
const login = async (e) => { const t = await (await fetch(U + '/auth/v1/token?grant_type=password', { method: 'POST', headers: { apikey: K, 'content-type': 'application/json' }, body: JSON.stringify({ email: e, password: PW }) })).json(); return { apikey: K, Authorization: 'Bearer ' + t.access_token, 'content-type': 'application/json' }; };
const rpc = async (H, f, b) => { const r = await fetch(U + '/rest/v1/rpc/' + f, { method: 'POST', headers: H, body: JSON.stringify(b) }); const j = await r.json(); if (r.status >= 300) throw new Error(f + ': ' + JSON.stringify(j)); return j; };
const get = async (H, p) => (await fetch(U + '/rest/v1/' + p, { headers: H })).json();
let n = 0; const shot = async (page, name) => { await page.screenshot({ path: `tv-${String(++n).padStart(2, '0')}-${name}.png`, fullPage: true }); };
const S121 = '30000000-0000-0000-0000-000000000002';

(async () => {
  const maria = await login('maint@northside.demo'), pete = await login('pete@prairieplumbing.demo');
  const browser = await chromium.launch();
  const watch = (p, who) => { p.on('pageerror', (e) => log(who, 'PAGE ERROR', e.message)); p.on('console', (m) => { if (m.type() === 'error') log(who, 'console', m.text().slice(0, 200)); }); p.on('dialog', (d) => d.accept()); };
  const signIn = async (page, email) => {
    await page.goto(SITE + '/');
    await page.locator('input[type=email]').fill(email);
    await page.locator('input[type=password]').fill(PW);
    await page.getByRole('button', { name: 'Sign in', exact: true }).click();
  };

  // ---- 1. Store opens a PO call ----
  const desk = await browser.newContext({ viewport: { width: 1280, height: 900 } });
  const store = await desk.newPage(); watch(store, 'store');
  await signIn(store, 'maint@northside.demo');
  await store.waitForURL('**/store', { timeout: 20000 });
  await store.getByRole('button', { name: '+ New service call' }).click();
  await store.locator('label', { hasText: 'Location' }).locator('select').selectOption(S121);
  await store.locator('label', { hasText: "What's the problem?" }).locator('select').selectOption({ label: 'Drain clogged / backing up' });
  await store.getByText('Goes to').waitFor();
  const po = 'E2E-' + Date.now().toString().slice(-5);
  await store.locator('label', { hasText: 'Not to exceed' }).locator('input').fill('300');
  await store.locator('label', { hasText: 'Your PO number' }).locator('input').fill(po);
  await store.locator('label', { hasText: 'Details' }).locator('textarea').fill('Mop sink drain backing up (Time Verify test)');
  await shot(store, 'store-new-po-call');
  await store.getByRole('button', { name: 'Send service call' }).click();
  await store.getByText('Time Verify · PO ' + po).waitFor({ timeout: 20000 });
  await shot(store, 'store-call-waiting-accept');
  const wo = (await get(maria, `work_orders?select=id,number,contractor_id,mode,nte&store_po_number=eq.${po}`))[0];
  if (wo.mode !== 'verify' || Number(wo.nte) !== 300) throw new Error('call not Time Verify: ' + JSON.stringify(wo));
  log('✓ store opened PO', po, 'call #' + wo.number, '→ Prairie Plumbing, Time Verify, NTE $300');

  // ---- 2. Office accepts and schedules the trip (the store is told who is coming) ----
  const offCtx = await browser.newContext({ viewport: { width: 1280, height: 900 } });
  const office = await offCtx.newPage(); watch(office, 'office');
  await signIn(office, 'pete@prairieplumbing.demo');
  await office.waitForURL('**/office', { timeout: 20000 });
  await office.getByText(`#${wo.number}`).first().click();
  await office.getByRole('button', { name: 'Accept — on the way now' }).click();
  await office.getByText('Accepted').first().waitFor({ timeout: 15000 });
  log('✓ office accepted ("on the way now")');
  await office.locator('aside.drawer').getByRole('button', { name: 'Schedule a trip' }).click();
  await office.locator('label', { hasText: 'Technician' }).locator('select').selectOption({ label: 'Tony Berg' });
  await office.locator('label', { hasText: 'Going now' }).locator('input').check();
  await office.locator('input[placeholder^="Note for the store"]').fill('Bringing the drain machine');
  await office.getByRole('button', { name: 'Schedule — tell the store' }).click();
  await office.getByText('Trip scheduled').waitFor({ timeout: 15000 });
  await shot(office, 'office-trip-scheduled');
  log('✓ office scheduled Tony — store told who is coming');
  for (let i = 0; i < 10; i++) { const n = await get(maria, `notifications?select=message&work_order_id=eq.${wo.id}&message=like.*is%20scheduled*`); if (n.length) { log('  store was told:', n[0].message); break; } await new Promise((r) => setTimeout(r, 1000)); }
  await store.reload();
  await store.getByText('Expected today').waitFor({ timeout: 15000 });
  await store.locator('.panel', { hasText: 'Expected today' }).getByText('Tony Berg').first().waitFor({ timeout: 15000 });
  await shot(store, 'store-expected-today');
  log('✓ store sees Tony under "Expected today"');

  // ---- 3. Tech: scheduled job → Start driving → I'm here → code → parts run → Leaving ----
  const phone = await browser.newContext({ ...devices['iPhone 13'], geolocation: { latitude: 47.92, longitude: -97.03 }, permissions: ['geolocation'] });
  const tech = await phone.newPage(); watch(tech, 'tech');
  await signIn(tech, 'tony@prairieplumbing.demo');
  await tech.waitForURL('**/tech', { timeout: 20000 });
  await tech.getByText(`#${wo.number}`).first().waitFor({ timeout: 20000 });
  await shot(tech, 'tech-job-list');
  try { await rpc(pete, 'tech_claim_call', { p_wo: wo.id }); throw new Error('double dispatch allowed'); }
  catch (e) { if (!/Already taken/.test(e.message)) throw e; log('✓ second tech blocked:', e.message.match(/Already taken[^"]*/)[0]); }
  await tech.getByText(`#${wo.number}`).first().click();
  await tech.getByRole('button', { name: '20 min' }).click();
  await tech.getByText('On the way').first().waitFor({ timeout: 15000 });
  log('✓ Tony started driving');
  await phone.setGeolocation({ latitude: 47.8935, longitude: -97.0631 });
  await tech.getByText('Check in with the store').waitFor({ timeout: 20000 });
  log('✓ arrival by GPS');
  let v; for (let i = 0; i < 20 && !v; i++) { v = (await get(maria, `visits?select=id&work_order_id=eq.${wo.id}&status=eq.on_site`))[0]; if (!v) await new Promise((r) => setTimeout(r, 1000)); }
  const code = (await get(maria, `visit_codes?select=code&visit_id=eq.${v.id}`))[0].code;
  await tech.locator('input.codebox').fill(code);
  await tech.getByRole('button', { name: 'Check in', exact: true }).click();
  await tech.getByText('Parts run — leaving to get parts').waitFor({ timeout: 20000 });
  await shot(tech, 'tech-on-site');
  log('✓ checked in with the store\'s code');
  await store.reload();
  await store.locator('.panel', { hasText: 'In the building now' }).getByText('Tony Berg').first().waitFor({ timeout: 20000 });
  await shot(store, 'store-in-building');
  log('✓ store sees Tony "In the building now"');
  await tech.getByText('Parts run — leaving to get parts').click();
  await tech.getByText('On a parts run').waitFor({ timeout: 10000 });
  await phone.setGeolocation({ latitude: 47.9005, longitude: -97.0580 });
  await tech.locator('label', { hasText: 'Supplier' }).locator('input').fill('Ferguson');
  await tech.getByRole('button', { name: "I'm at the supplier" }).click();
  await tech.getByText('at the supplier').first().waitFor();
  await shot(tech, 'tech-parts-run');
  await phone.setGeolocation({ latitude: 47.8935, longitude: -97.0631 });
  await tech.getByRole('button', { name: "I'm back on site" }).click();
  await tech.getByRole('button', { name: '✓ Done' }).waitFor({ timeout: 10000 });
  log('✓ parts run: left → at supplier (GPS) → back');
  await tech.getByRole('button', { name: '✓ Done' }).click();
  await tech.locator('input[placeholder="What you did (optional)"]').fill('Cleared drain, replaced P-trap');
  await tech.getByRole('button', { name: 'Leave — job done' }).click();
  await tech.getByText('Job complete').waitFor({ timeout: 15000 });
  await shot(tech, 'tech-done');
  for (let i = 0; i < 15; i++) { const s = (await get(maria, `work_orders?select=status&id=eq.${wo.id}`))[0].status; if (s === 'completed') break; await new Promise((r) => setTimeout(r, 1000)); }
  log('✓ Leaving — done; call completed');

  // ---- 4. Office enters the invoice ----
  await office.reload();
  await office.getByText(`#${wo.number}`).first().click();
  await office.getByText('Your invoice for this PO').waitFor({ timeout: 20000 });
  await office.locator('label', { hasText: 'Invoice #' }).locator('input').fill('PP-E2E');
  await office.locator('label', { hasText: 'Total ($)' }).locator('input').fill('340');
  await office.locator('label', { hasText: 'Hours billed' }).locator('input').fill('2');
  await office.getByText('more than verified').waitFor();
  await shot(office, 'office-invoice-form');
  await office.getByRole('button', { name: 'Save invoice' }).click();
  await office.getByRole('heading', { name: 'Invoice PP-E2E' }).waitFor({ timeout: 15000 });
  log('✓ office entered invoice PP-E2E: $340, 2 h');

  // ---- 5. Store sees billed vs verified, the flags, and the PO log ----
  await store.reload();
  await store.getByRole('button', { name: 'PO log' }).click();
  await store.getByText(po).first().waitFor({ timeout: 15000 });
  await shot(store, 'store-po-log');
  await store.locator('tr', { hasText: po }).getByText('h not explained').waitFor();
  await store.locator('tr', { hasText: po }).getByText('Over the not-to-exceed').waitFor();
  log('✓ PO log row shows unexplained hours and over-limit');
  await store.getByRole('button', { name: /Open calls/ }).click();
  await store.getByRole('button', { name: 'Invoiced' }).click();
  await store.getByText(`#${wo.number}`).first().click();
  await store.getByText('Not explained', { exact: true }).waitFor({ timeout: 15000 });
  await shot(store, 'store-invoice-check');
  await store.getByRole('button', { name: 'Approve invoice' }).click();
  await store.getByText('approved').first().waitFor({ timeout: 15000 });
  log('✓ store reviewed and approved the invoice');

  // ---- 5b. Someone shows up unannounced ----
  await store.goto(SITE + '/store');
  await store.getByRole('button', { name: "Someone's here we weren't expecting" }).click();
  await store.locator('label', { hasText: 'Location' }).locator('select').selectOption({ label: 'Store #121' });
  await store.locator('label', { hasText: 'Their name' }).locator('input').fill('Kyle (E2E)');
  await store.locator('label', { hasText: 'Company' }).first().locator('select').selectOption({ label: 'Prairie Plumbing (demo)' });
  await store.getByRole('button', { name: 'Record it' }).click();
  await store.getByText('Unscheduled today').waitFor({ timeout: 15000 });
  await shot(store, 'store-unexpected-visitor');
  log('✓ unexpected visitor logged; store and contractor office told');

  // ---- 6. QR sticker report (no login) ----
  const eq = (await get(maria, 'equipment?select=qr_token,site_id&site_id=eq.30000000-0000-0000-0000-000000000001'))[0];
  const anon = await (await browser.newContext({ ...devices['iPhone 13'] })).newPage(); watch(anon, 'qr');
  await anon.goto(`${SITE}/r/${eq.qr_token}`);
  await anon.getByText('Store PIN').waitFor({ timeout: 15000 }).catch(async () => { await anon.getByText('Already reported').waitFor(); });
  await shot(anon, 'qr-report');
  if (await anon.getByRole('button', { name: 'Report problem' }).count()) {
    await anon.locator('label', { hasText: 'Your name' }).locator('input').fill('Jen (E2E)');
    await anon.locator('label', { hasText: 'Details' }).locator('textarea').fill('Making a loud rattling noise (E2E test)');
    await anon.locator('input.codebox').fill('1111');
    await anon.getByRole('button', { name: 'Report problem' }).click();
    await anon.getByText('Wrong store PIN').waitFor({ timeout: 10000 });
    log('✓ QR: wrong PIN refused');
    await anon.locator('input.codebox').fill('2468');
    await anon.getByRole('button', { name: 'Report problem' }).click();
    await anon.getByText(/Sent\.|already reported/).first().waitFor({ timeout: 15000 });
    await shot(anon, 'qr-sent');
    log('✓ QR: reported with the store PIN');
  }

  // ---- 7. Sign-in link for a new tech ----
  const tok = await rpc(pete, 'add_team_member', { p_name: 'E2E Tech ' + Date.now().toString().slice(-4), p_phone: '701-555-0199' });
  const np = await (await browser.newContext({ ...devices['iPhone 13'] })).newPage(); watch(np, 'join');
  await np.goto(`${SITE}/join/${tok}`);
  await np.getByRole('button', { name: 'Sign in on this phone' }).click();
  await np.waitForURL('**/tech', { timeout: 20000 });
  await np.getByText('Your jobs').waitFor({ timeout: 20000 });
  await shot(np, 'join-signed-in');
  log('✓ sign-in link: new tech signed in with no password');
  await np.goto(`${SITE}/join/${tok}`);
  await np.getByText('already used').waitFor({ timeout: 10000 });
  log('✓ the link works only once');

  // ---- 8. Stickers + alert sender ----
  await store.goto(SITE + '/store/stickers');
  await store.locator('.sticker img').first().waitFor({ timeout: 20000 });
  await shot(store, 'stickers');
  log('✓ QR sticker sheet renders', await store.locator('.sticker').count(), 'stickers');
  const ob = await fetch(SITE + '/api/outbox', { method: 'POST' });
  log(ob.status === 401 ? '✓ alert sender refuses calls without its key' : 'outbox status ' + ob.status);

  await browser.close();
  log('ALL TIME VERIFY STEPS PASSED');
})().catch((e) => { console.error('FAILED:', e.message); process.exit(1); });
