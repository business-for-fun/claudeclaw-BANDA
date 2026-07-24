// BUG-20260424-001+002 Deep Check — Commit d297341
// Focus: Toyota_Panasonic duplicate details, Admin row audit, Sony fix

const { chromium } = require('playwright');

async function openTradeDeals(page, url, label) {
  await page.goto(url, { timeout: 60000, waitUntil: 'load' });
  await page.waitForTimeout(5000);

  // Debug: what tabs are present?
  const pageTitle = await page.title();
  console.log(`  ${label} page title: ${pageTitle}`);

  // Find entry tab - try multiple options
  let entry = null;
  const logBtn = page.locator('button:has-text("Log"), a:has-text("Log"), [role="tab"]:has-text("Log")').first();
  const nettingBtn = page.locator('text=Netting Results').first();

  if (await logBtn.isVisible({ timeout: 2000 }).catch(() => false)) {
    entry = logBtn;
    console.log(`  ${label}: found Log tab button`);
  } else if (await nettingBtn.isVisible({ timeout: 2000 }).catch(() => false)) {
    entry = nettingBtn;
    console.log(`  ${label}: using Netting Results as entry`);
  } else {
    // Print all visible buttons for debug
    const btns = await page.locator('button, [role="tab"]').all();
    for (const b of btns.slice(0, 10)) {
      const t = await b.textContent().catch(() => '?');
      const v = await b.isVisible().catch(() => false);
      if (v && t && t.trim()) console.log(`  ${label} tab: "${t.trim()}"`);
    }
    throw new Error(`No Log or Netting Results tab in ${label}`);
  }

  await entry.click();
  await page.waitForTimeout(5000); // longer wait for round list to populate

  // Debug what's in the table
  const tableCount = await page.locator('table').count();
  console.log(`  ${label}: ${tableCount} table(s) on page`);

  // Try table tbody tr, then fall back to table tr (excluding header)
  let rounds = await page.locator('table tbody tr').all();
  if (rounds.length === 0) {
    rounds = await page.locator('table tr:not(:first-child)').all();
  }
  if (rounds.length === 0) {
    // Last resort: print page text excerpt for debug
    const bodyText = await page.locator('body').innerText().catch(() => '');
    console.log(`  ${label} body excerpt: ${bodyText.substring(0, 300)}`);
    throw new Error(`No rounds in ${label}`);
  }
  console.log(`  ${label}: ${rounds.length} round(s) — opening first`);
  await rounds[0].click();
  await page.waitForTimeout(3000);

  const tdTab = page.locator('text=Trade Deals').first();
  if (!await tdTab.isVisible({ timeout: 5000 }).catch(() => false)) {
    throw new Error(`Trade Deals sub-tab missing in ${label}`);
  }
  await tdTab.click();
  await page.waitForTimeout(2000);

  const rows = await page.locator('table tbody tr').all();
  const texts = [];
  for (const r of rows) {
    const t = await r.textContent().catch(() => null);
    if (t && t.trim()) texts.push(t.trim());
  }
  return texts;
}

(async () => {
  console.log('🔬 DEEP ANALYSIS — BUG-20260424-001+002 (d297341)');

  let browser;
  const cLog = { postFlipSynth: [], deduplicate: [], synthesize: 0, symmetry: 0 };

  try {
    browser = await chromium.launch({ headless: true });
    const context = await browser.newContext({
      viewport: { width: 1440, height: 900 },
      httpCredentials: {
        username: process.env.R4G_DEV_USER,
        password: process.env.R4G_DEV_PASS
      }
    });
    const page = await context.newPage();

    page.on('console', msg => {
      const t = msg.text();
      if (t.includes('[R4G postFlipSynth]')) { cLog.postFlipSynth.push(t); }
      else if (t.includes('[R4G dedup') || t.includes('[R4G deduplicate]')) { cLog.deduplicate.push(t); console.log(`🔁 ${t}`); }
      else if (t.includes('[R4G synthesize]')) { cLog.synthesize++; }
      else if (t.includes('[R4G symmetry]')) { cLog.symmetry++; }
    });

    // ─── PANASONIC FULL ROW DUMP ────────────────────────────────
    console.log('\n📍 Opening Panasonic broker...');
    const pRows = await openTradeDeals(page,
      'https://dev.r4g.business-for-fun.com/?broker=Panasonic&share=lzoknmqo',
      'Panasonic');

    console.log(`\n📋 PANASONIC TRADE DEALS — ${pRows.length} total rows (RAW):`);
    pRows.forEach((r, i) => console.log(`  ${String(i+1).padStart(2)}. ${r}`));

    // Per-trader breakdown
    const byTrader = {};
    pRows.forEach((r, idx) => {
      const tm = r.match(/Panasonic(\w+)TARGET_(BUY|SELL)/);
      if (!tm) return;
      const trader = tm[1];
      const dir = tm[2];
      const vm = r.match(/(EEX|OTC)(\d{1,4})(?!\d)/);
      const vol = vm ? parseInt(vm[2]) : 0;
      if (!byTrader[trader]) byTrader[trader] = { BUY: [], SELL: [] };
      byTrader[trader][dir].push({ vol, row: idx + 1, text: r.substring(0, 80) });
    });

    console.log('\n📊 PANASONIC PER-TRADER BREAKDOWN:');
    for (const [t, d] of Object.entries(byTrader)) {
      const buyN = d.BUY.length, sellN = d.SELL.length;
      const sym = buyN === sellN ? '⚖️' : '⚠️';
      console.log(`  ${sym} ${t}_Panasonic: BUY×${buyN} SELL×${sellN}`);
      d.BUY.forEach(x => console.log(`      BUY ${x.vol}MW [row ${x.row}] ${x.text}`));
      d.SELL.forEach(x => console.log(`      SELL ${x.vol}MW [row ${x.row}] ${x.text}`));
    }

    // Exact check results
    const toyota = byTrader['Toyota'];
    const volvo  = byTrader['Volvo'];
    const ford   = byTrader['Ford'];
    const honda  = byTrader['Honda'];

    console.log('\n─── CHECK A: Toyota_Panasonic ───');
    if (!toyota) { console.log('  ❌ FAIL — no Toyota rows'); }
    else {
      const totalT = toyota.BUY.length + toyota.SELL.length;
      if (totalT === 1 && toyota.BUY.length === 0 && toyota.SELL.length === 1) {
        console.log(`  ✅ PASS — 1 row, SELL only (${toyota.SELL[0].vol}MW)`);
      } else {
        console.log(`  ❌ FAIL — ${totalT} row(s): BUY×${toyota.BUY.length}, SELL×${toyota.SELL.length}`);
        console.log(`     Expected: 1 row, SELL only (UNSOLVED — no phantom BUY)`);
        // Check if these look like leftovers from previous fix
        console.log(`     BUY rows: ${toyota.BUY.map(x => `row${x.row}/${x.vol}MW`).join(', ')}`);
        console.log(`     SELL rows: ${toyota.SELL.map(x => `row${x.row}/${x.vol}MW`).join(', ')}`);
      }
    }

    console.log('\n─── CHECK B: Volvo_Panasonic ───');
    if (!volvo) { console.log('  ❌ FAIL — no Volvo rows'); }
    else {
      const totalV = volvo.BUY.length + volvo.SELL.length;
      if (totalV === 1 && volvo.BUY.length === 1 && volvo.SELL.length === 0) {
        console.log(`  ✅ PASS — 1 row, BUY only (${volvo.BUY[0].vol}MW)`);
      } else {
        console.log(`  ❌ FAIL — ${totalV} row(s): BUY×${volvo.BUY.length}, SELL×${volvo.SELL.length}`);
      }
    }

    console.log('\n─── CHECK C: Ford_Panasonic ───');
    if (!ford) { console.log('  ❌ FAIL — no Ford rows'); }
    else {
      const totalF = ford.BUY.length + ford.SELL.length;
      if (totalF === 2 && ford.BUY.length === 1 && ford.SELL.length === 1) {
        console.log(`  ✅ PASS — 2 rows (BUY ${ford.BUY[0].vol}MW + SELL ${ford.SELL[0].vol}MW)`);
      } else {
        console.log(`  ❌ FAIL — ${totalF} row(s): BUY×${ford.BUY.length}, SELL×${ford.SELL.length}`);
      }
    }

    console.log('\n─── CHECK D: Honda_Panasonic ───');
    if (!honda) { console.log('  ❌ FAIL — no Honda rows'); }
    else {
      const totalH = honda.BUY.length + honda.SELL.length;
      if (totalH === 2 && honda.BUY.length === 1 && honda.SELL.length === 1) {
        console.log(`  ✅ PASS — 2 rows (BUY ${honda.BUY[0].vol}MW + SELL ${honda.SELL[0].vol}MW)`);
      } else {
        console.log(`  ❌ FAIL — ${totalH} row(s): BUY×${honda.BUY.length}, SELL×${honda.SELL.length}`);
      }
    }

    console.log(`\n─── CHECK E: Total Row Count ───`);
    console.log(`  Total: ${pRows.length} — ${pRows.length <= 10 ? '✅ PASS (≤10)' : '❌ FAIL (>10, duplicates suspected)'}`);

    // ─── ADMIN CHECK ────────────────────────────────────────────
    console.log('\n\n📍 Opening Admin...');
    const adminRows = await openTradeDeals(page,
      'https://dev.r4g.business-for-fun.com/',
      'Admin');

    console.log(`\n📋 ADMIN TRADE DEALS — ${adminRows.length} rows (RAW):`);
    adminRows.forEach((r, i) => console.log(`  ${String(i+1).padStart(2)}. ${r}`));

    // Detect duplicates: exact full text
    const adminSeen = new Map();
    adminRows.forEach((r, i) => {
      const key = r;
      if (!adminSeen.has(key)) adminSeen.set(key, []);
      adminSeen.get(key).push(i + 1);
    });
    const adminDups = [...adminSeen.entries()].filter(([, indices]) => indices.length > 1);
    console.log(`\n─── CHECK F: Admin Duplicates ───`);
    if (adminDups.length === 0) {
      console.log(`  ✅ PASS — No exact duplicates in ${adminRows.length} admin rows`);
    } else {
      console.log(`  ❌ FAIL — ${adminDups.length} duplicate group(s):`);
      adminDups.forEach(([text, indices]) => {
        console.log(`     Rows ${indices.join(', ')}: ${text.substring(0, 80)}`);
      });
    }

    // ─── SONY CHECK ─────────────────────────────────────────────
    console.log('\n\n📍 Opening Sony...');
    try {
      const sonyRows = await openTradeDeals(page,
        'https://dev.r4g.business-for-fun.com/?broker=Sony&share=gei29u4l',
        'Sony');

      console.log(`\n📋 SONY TRADE DEALS — ${sonyRows.length} rows:`);
      sonyRows.forEach((r, i) => console.log(`  ${String(i+1).padStart(2)}. ${r}`));

      let hBuy = 0, hSell = 0;
      sonyRows.forEach(r => {
        if (!r.includes('Honda')) return;
        const dir = r.match(/TARGET_(BUY|SELL)/);
        const vol = r.match(/(EEX|OTC)(\d{1,4})(?!\d)/);
        if (dir && vol) {
          if (dir[1] === 'BUY') hBuy += parseInt(vol[2]);
          else hSell += parseInt(vol[2]);
        }
      });

      console.log(`\n─── CHECK G: Honda_Sony Symmetry ───`);
      if (hBuy === hSell && hBuy > 0) {
        console.log(`  ✅ PASS — Honda_Sony BUY=${hBuy}MW == SELL=${hSell}MW`);
      } else if (hBuy === 0 && hSell === 0) {
        console.log(`  ⚠️  INCONCLUSIVE — Honda not found in Sony Trade Deals rows`);
      } else {
        console.log(`  ❌ FAIL — Honda_Sony ASYMMETRIC: BUY=${hBuy} ≠ SELL=${hSell}`);
      }
    } catch (e) {
      console.log(`  ⚠️  Sony check error: ${e.message}`);
    }

    // ─── CONSOLE SUMMARY ────────────────────────────────────────
    console.log('\n' + '='.repeat(60));
    console.log('CONSOLE MESSAGE SUMMARY:');
    console.log(`  🆕 [R4G postFlipSynth]: ${cLog.postFlipSynth.length}`);
    console.log(`  🔁 [R4G deduplicate]:   ${cLog.deduplicate.length} ${cLog.deduplicate.length === 0 ? '⚠️  (0 — dedup may not be logging)' : ''}`);
    console.log(`  🔄 [R4G synthesize]:    ${cLog.synthesize}`);
    console.log(`  ⚠️  [R4G symmetry]:      ${cLog.symmetry} (must be 0)`);
    if (cLog.deduplicate.length > 0) {
      cLog.deduplicate.forEach(m => console.log(`     > ${m}`));
    }
    console.log('='.repeat(60));

  } catch (err) {
    console.error(`\n❌ FATAL: ${err.message}`);
    console.error(err.stack);
  } finally {
    if (browser) await browser.close();
  }
})();
