// End-to-end: drive the technician app on a phone-size screen against the live site.
import { chromium, devices } from 'playwright';
import fs from 'fs';
const SITE = process.env.SITE || 'https://servicepro-two.vercel.app';
const U = 'https://svaoljxdoaefdqvvshhv.supabase.co', K = 'sb_publishable_KqvxfxaerUNeBkVQvwhvZQ_HFviMsbL';
const PW = 'DemoService2026!';
const log = (...a) => console.log(...a);
const login = async (e) => { const t = await (await fetch(U + '/auth/v1/token?grant_type=password', { method: 'POST', headers: { apikey: K, 'content-type': 'application/json' }, body: JSON.stringify({ email: e, password: PW }) })).json(); return { apikey: K, Authorization: 'Bearer ' + t.access_token, 'content-type': 'application/json' }; };
const rpc = async (H, f, b) => { const r = await fetch(U + '/rest/v1/rpc/' + f, { method: 'POST', headers: H, body: JSON.stringify(b) }); const j = await r.json(); if (r.status >= 300) throw new Error(f + ': ' + JSON.stringify(j)); return j; };
const get = async (H, p) => (await fetch(U + '/rest/v1/' + p, { headers: H })).json();
const shot = async (page, n) => { await page.screenshot({ path: `shot-${n}.png`, fullPage: true }); };

(async () => {
  const sam = await login('store@northside.demo'), maria = await login('maint@northside.demo'), pat = await login('dispatch@arcticair.demo');
  const issues = await get(sam, 'issue_types?select=id,code');
  const iid = (c) => issues.find((i) => i.code === c).id;
  // Job 1: Store #114 (check-in code required, agreement covers labor)
  const w1 = await rpc(sam, 'create_work_order', { p_site: '30000000-0000-0000-0000-000000000001', p_issue_type: iid('self_contained_down'), p_description: 'Deli grab-and-go cooler at 48°F (app test)' });
  const v1 = await rpc(pat, 'assign_work_order', { p_wo: w1.id, p_tech: '00000000-0000-0000-0000-0000000000a3' });
  const code = (await get(sam, `visit_codes?select=code&visit_id=eq.${v1.id}`))[0].code;
  log('job1', w1.number, 'code', code);
  // Job 2: Store #121 (no agreement: $125/hr, $45 trip, $125 diagnosis limit)
  const w2 = await rpc(maria, 'create_work_order', { p_site: '30000000-0000-0000-0000-000000000002', p_issue_type: iid('self_contained_down'), p_description: 'Beer cave door cooler warm (app test)' });
  const v2 = await rpc(pat, 'assign_work_order', { p_wo: w2.id, p_tech: '00000000-0000-0000-0000-0000000000a3' });
  log('job2', w2.number);

  const browser = await chromium.launch();
  const ctx = await browser.newContext({ ...devices['iPhone 13'], geolocation: { latitude: 47.95, longitude: -97.10 }, permissions: ['geolocation'] });
  const page = await ctx.newPage();
  page.on('pageerror', (e) => log('PAGE ERROR', e.message));
  page.on('console', (m) => { if (m.type() === 'error') log('console error', m.text()); });
  page.on('dialog', (d) => d.accept());

  await page.goto(SITE + '/');
  await page.getByText('Technician (phone app)').click();
  await page.waitForURL('**/tech', { timeout: 20000 });
  await page.getByText(`#${w1.number}`).waitFor({ timeout: 20000 });
  await shot(page, '01-list'); log('✓ tech signed in, sees job list');

  // ---- Job 1 ----
  await page.getByText(`#${w1.number}`).first().click();
  await page.getByRole('button', { name: '20 min' }).click();
  await page.getByText('On the way').first().waitFor();
  log('✓ start driving + ETA');
  await ctx.setGeolocation({ latitude: 47.9100, longitude: -97.0490 });   // at Store #114
  await page.getByText('Check in with the store').waitFor({ timeout: 20000 });
  log('✓ arrival detected automatically by GPS');
  await page.locator('input.codebox').fill(code);
  await page.getByRole('button', { name: 'Check in', exact: true }).click();
  await page.getByText('Photo of the nameplate').waitFor({ timeout: 15000 });
  log('✓ checked in with code');
  await page.locator('label.camera', { hasText: 'nameplate' }).locator('input').setInputFiles('plate.jpg');
  await page.getByText('Another nameplate photo').waitFor();
  await page.locator('select').filter({ hasText: 'New unit (not listed)' }).selectOption({ label: 'New unit (not listed)' }).catch(() => {});
  const typeSel = page.locator('label', { hasText: 'Type' }).locator('select');
  await typeSel.selectOption({ label: 'Self-contained cooler / freezer' });
  await page.locator('label', { hasText: 'Make' }).locator('input').fill('True');
  await page.locator('label', { hasText: 'Model' }).locator('input').fill('GDM-23');
  await page.locator('label', { hasText: 'Serial' }).locator('input').fill('9087123');
  await page.locator('label', { hasText: 'Where is it?' }).locator('input').fill('Deli, by registers');
  await page.getByRole('button', { name: 'Confirm equipment' }).click();
  log('✓ nameplate photo + equipment confirmed');
  await page.locator('label.camera', { hasText: /^📷 Before/ }).locator('input').setInputFiles('before.jpg');
  await page.locator('select').filter({ hasText: 'Choose the repair' }).selectOption({ label: 'Clean condenser coil' });
  await page.getByText('Usual parts for this repair were added').waitFor();
  log('✓ before photo, repair picked, kit parts added');
  await shot(page, '02-onsite');

  // Go offline in the "basement" and finish there
  await ctx.setOffline(true);
  await page.locator('label.camera', { hasText: /^📷 After/ }).locator('input').setInputFiles('after.jpg');
  await page.getByText(/No signal/).waitFor({ timeout: 10000 });
  await page.getByText('After ✓').waitFor();
  await shot(page, '03-offline');
  await page.getByRole('button', { name: '✓ Job complete' }).click();
  await page.getByText('Job complete').first().waitFor();
  log('✓ finished the job with NO signal — saved on the phone');
  const waiting = await page.locator('.syncbar').innerText(); log('   sync bar:', waiting);
  await ctx.setOffline(false);
  await page.evaluate(() => window.dispatchEvent(new Event('online')));
  await page.getByText(/All synced/).waitFor({ timeout: 60000 });
  log('✓ signal back — everything sent automatically');
  await shot(page, '04-synced');
  const after1 = (await get(sam, `work_orders?select=number,status,total_cost,work_summary&id=eq.${w1.id}`))[0];
  const ph1 = await get(sam, `photos?select=kind,storage_path&work_order_id=eq.${w1.id}`);
  log('   store sees:', JSON.stringify(after1), 'photos:', ph1.map((p) => p.kind).join(','));
  const signed = await fetch(U + '/storage/v1/object/sign/job-photos/' + ph1.find((p) => p.kind === 'after').storage_path, { method: 'POST', headers: sam, body: JSON.stringify({ expiresIn: 60 }) }).then((r) => r.json());
  log('   store can open the AFTER photo:', !!signed.signedURL);
  const problems = await page.evaluate(() => localStorage.getItem('sp_tech_problems')); log('   problems on phone:', problems);

  // ---- Job 2: meter stops the tech, quote from hours + parts ----
  await page.getByRole('button', { name: '‹ Jobs' }).click();
  await page.getByText(`#${w2.number}`).first().click();
  await page.getByRole('button', { name: '10 min' }).click();
  await ctx.setGeolocation({ latitude: 47.8935, longitude: -97.0631 });   // at Store #121
  await page.locator('.meter').waitFor({ timeout: 20000 });
  log('✓ job 2 arrival; meter:', (await page.locator('.meter').innerText()).replace(/\n/g, ' | '));
  const stop = await page.locator('.stopwall').count(); log('   STOP wall showing:', stop > 0);
  await shot(page, '05-meter-stop');
  await page.getByRole('button', { name: 'Request more' }).first().click();
  await page.getByPlaceholder('Add a part to the quote…').fill('contactor');
  await page.locator('.pick button').first().click();
  await page.locator('textarea').fill('Contactor contacts burned; replace and test (app test)');
  const quoteText = await page.locator('.notice', { hasText: 'Not to exceed' }).innerText(); log('   quote:', quoteText.replace(/\n/g, ' '));
  await page.getByRole('button', { name: 'Send for approval' }).click();
  await page.getByText(/Waiting for approval/).waitFor({ timeout: 20000 });
  await page.getByText(/All synced/).waitFor({ timeout: 30000 });
  log('✓ quote sent; tech sees "waiting for approval"');
  await shot(page, '06-waiting');
  const pl = await get(maria, `po_lines?select=seq,amount,status,breakdown&work_order_id=eq.${w2.id}&order=seq`);
  log('   store sees PO lines:', JSON.stringify(pl.map((l) => ({ seq: l.seq, amount: l.amount, status: l.status, labor: l.breakdown?.labor, parts: l.breakdown?.parts_total }))));
  await page.getByRole('button', { name: 'Quote sent — leaving' }).click();
  await page.getByRole('button', { name: 'Leave — waiting on approval' }).click();
  await page.getByText('Waiting on approval').first().waitFor();
  await page.getByText(/All synced/).waitFor({ timeout: 30000 });
  const after2 = (await get(maria, `work_orders?select=number,status&id=eq.${w2.id}`))[0];
  log('✓ left while waiting; call is now:', after2.status);
  // manifest + offline worker present
  const man = await page.evaluate(() => fetch('/manifest.webmanifest').then((r) => r.json()).then((j) => j.name));
  const sw = await page.evaluate(() => navigator.serviceWorker.getRegistration().then((r) => !!r));
  log('✓ installable:', man, '| offline worker registered:', sw);
  await browser.close();
  fs.writeFileSync('ids.json', JSON.stringify({ w1: w1.id, w2: w2.id }));
})().catch((e) => { console.error('E2E FAILED:', e.message); process.exit(1); });
