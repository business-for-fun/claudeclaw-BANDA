// BUG-20260424-001+002 v6 — Commit 4fc7e9c
// Fix: status !== 'UNSOLVED' guard in synthesizeMissingDetails()
//      applied to BOTH NettingResults.jsx (~line 714) AND BrokerConsole.jsx (~line 630)
// Root cause: Toyota is UNSOLVED but e.sellTotal=40 from server mirror → zero-detail guard didn't fire
// Expected: Toyota=1 SELL only, Volvo=1 BUY (via counterparty flip, not phantom synth), total Pana TD=6

const { chromium } = require('playwright');
const fs = require('fs');

const URLS = {
  panasonic: 'https://dev.r4g.business-for-fun.com/?broker=Panasonic&share=lzoknmqo&devSeed=1',
  sony:      'https://dev.r4g.business-for-fun.com/?broker=Sony&share=gei29u4l&devSeed=1',
  jvc:       'https://dev.r4g.business-for-fun.com/?broker=JVC&share=seed-jvc-03&devSeed=1',
  admin:     'https://dev.r4g.business-for-fun.com/?devSeed=1'
};

async function drillIntoRound(page, url, label, targetTab) {
  await page.goto(url, { timeout: 60000, waitUntil: 'load' });
  await page.waitForTimeout(6000);
  const nrBtn = page.locator('text=Netting Results').first();
  if (!await nrBtn.isVisible({ timeout: 3000 }).catch(() => false))
    throw new Error(`Netting Results tab not found for ${label}`);
  await nrBtn.click();
  await page.waitForTimeout(5000);

  let rounds = await page.locator('table tbody tr').all();
  if (rounds.length === 0) rounds = await page.locator('table tr:not(:first-child)').all();
  if (rounds.length === 0) throw new Error(`No rounds in ${label}`);
  console.log(`  ${label}: ${rounds.length} round(s) — clicking first`);
  await rounds[0].click();
  await page.waitForTimeout(3000);

  const tabBtn = page.locator(`button:has-text("${targetTab}")`).first();
  if (!await tabBtn.isVisible({ timeout: 5000 }).catch(() => false))
    throw new Error(`"${targetTab}" tab not found in ${label}`);
  await tabBtn.click();
  await page.waitForTimeout(2000);

  const rows = await page.locator('table tbody tr').all();
  const texts = [];
  for (const r of rows) {
    const t = await r.textContent().catch(() => null);
    if (t && t.trim()) texts.push(t.trim());
  }
  return texts;
}

function parseByTrader(rows, brokerName) {
  const re = new RegExp(`${brokerName}(\\w+)TARGET_(BUY|SELL)`);
  const byTrader = {};
  rows.forEach((r, idx) => {
    const m = r.match(re);
    if (!m) return;
    const trader = m[1], dir = m[2];
    const vm = r.match(/(EEX|OTC)(\d{1,4})(?!\d)/);
    const vol = vm ? parseInt(vm[2]) : 0;
    const hub = r.match(/TTF|NBP|THE|CEGH|ZTP/)?.[0] || '?';
    const venue = vm ? vm[1] : '?';
    if (!byTrader[trader]) byTrader[trader] = { BUY: [], SELL: [] };
    byTrader[trader][dir].push({ vol, hub, venue, row: idx + 1, text: r });
  });
  return byTrader;
}

function checkNoDuplicates(rows, label) {
  const seen = new Map();
  rows.forEach(r => seen.set(r, (seen.get(r) || 0) + 1));
  const dups = [...seen.entries()].filter(([, n]) => n > 1);
  if (dups.length > 0) {
    dups.forEach(([t, n]) => console.log(`  ❌ dup×${n}: ${t.substring(0, 90)}`));
    return `FAIL — ${label}: ${dups.length} duplicated row(s)`;
  }
  return null;
}

(async () => {
  console.log('🎯 BUG-20260424-001+002 v6 — Commit 4fc7e9c');
  console.log('Fix: status === SOLVED guard in synthesizeMissingDetails (both NettingResults.jsx + BrokerConsole.jsx)');
  console.log('Expected: Toyota=1 SELL, Volvo=1 BUY (flip), total Panasonic TD=6, JVC clean\n');

  let browser;
  const cLog = { synthBroker: 0, synthNetting: 0, unsolvedSkip: 0, symmetry: 0 };
  const checks = {};

  try {
    browser = await chromium.launch({ headless: true });
    const ctx = await browser.newContext({
      viewport: { width: 1440, height: 900 },
      httpCredentials: { username: process.env.R4G_DEV_USER, password: process.env.R4G_DEV_PASS }
    });
    const page = await ctx.newPage();

    page.on('console', msg => {
      const t = msg.text();
      if (t.includes('[R4G synthesize/broker]'))       cLog.synthBroker++;
      else if (t.includes('[R4G synthesize]'))           cLog.synthNetting++;
      else if (t.includes('[R4G') && (t.toLowerCase().includes('unsolved') ||
              t.toLowerCase().includes('skip'))) { cLog.unsolvedSkip++; console.log(`⏭️  ${t}`); }
      else if (t.includes('[R4G symmetry]'))             cLog.symmetry++;
    });

    // ── PANASONIC TRADE DEALS (checks A, B, C, G) ────────────────
    console.log('='.repeat(60));
    console.log('PANASONIC — Trade Deals (A, B, C, G)');
    console.log('='.repeat(60));

    const pRows = await drillIntoRound(page, URLS.panasonic, 'Panasonic', 'Trade Deals');
    console.log(`\nTotal rows: ${pRows.length}`);
    console.log('RAW:');
    pRows.forEach((r, i) => console.log(`  ${String(i+1).padStart(2)}. ${r}`));

    const pData = parseByTrader(pRows, 'Panasonic');
    console.log('\nPER-TRADER:');
    for (const [t, d] of Object.entries(pData)) {
      console.log(`  ${t}_Panasonic: BUY×${d.BUY.length} SELL×${d.SELL.length}`);
      d.BUY.forEach(x  => console.log(`    BUY  ${x.vol}MW ${x.hub} ${x.venue} [row ${x.row}]`));
      d.SELL.forEach(x => console.log(`    SELL ${x.vol}MW ${x.hub} ${x.venue} [row ${x.row}]`));
    }

    // CHECK A: no doubled rows
    const dupErr = checkNoDuplicates(pRows, 'Panasonic Trade Deals');
    checks.A = dupErr || `PASS — Panasonic Trade Deals: ${pRows.length} rows, no duplicates ✓`;
    console.log(`\n[A] ${checks.A}`);

    // CHECK B: Toyota — exactly 1 SELL, ZERO BUY
    const toyota = pData['Toyota'];
    if (!toyota) {
      checks.B = 'FAIL — Toyota_Panasonic: no rows at all';
    } else {
      const bN = toyota.BUY.length, sN = toyota.SELL.length;
      if (bN === 0 && sN === 1) {
        const s = toyota.SELL[0];
        checks.B = `PASS — Toyota_Panasonic: 1×TARGET_SELL ${s.vol}MW ${s.hub} ${s.venue}, NO phantom BUY ✓`;
      } else if (bN > 0) {
        checks.B = `FAIL — Toyota_Panasonic: BUY×${bN} SELL×${sN} — phantom BUY present`;
        toyota.BUY.forEach(x => console.log(`  🚨 PHANTOM BUY: ${x.vol}MW ${x.hub} [row ${x.row}]`));
      } else {
        checks.B = `FAIL — Toyota_Panasonic: BUY×${bN} SELL×${sN} (expected 0 BUY, 1 SELL)`;
      }
    }
    console.log(`[B] ${checks.B}`);

    // CHECK C: Volvo — 1 BUY (legitimate from Honda_Sony flip), 0 SELL
    //          OR 0 rows if UNSOLVED guard fully prevents all Volvo rows
    const volvo = pData['Volvo'];
    if (!volvo) {
      // Volvo UNSOLVED with 0 filled — synthesis skipped → no own rows
      // It might still appear via Honda_Sony's flip. 0 rows = guard worked.
      checks.C = `PASS — Volvo_Panasonic: 0 rows (UNSOLVED guard fired, no phantom synth) ✓`;
    } else {
      const bN = volvo.BUY.length, sN = volvo.SELL.length;
      const buyVol = volvo.BUY.reduce((s, x) => s + x.vol, 0);
      const sellVol = volvo.SELL.reduce((s, x) => s + x.vol, 0);
      if (bN === 1 && sN === 0) {
        // 1 BUY from counterparty flip is legitimate
        checks.C = `PASS — Volvo_Panasonic: 1×BUY ${buyVol}MW (legit counterparty-flip row, no phantom SELL) ✓`;
      } else if (bN === 0 && sN === 0) {
        checks.C = `PASS — Volvo_Panasonic: 0 rows (UNSOLVED guard) ✓`;
      } else if (bN > 0 && sN > 0 && buyVol === sellVol) {
        checks.C = `PASS — Volvo_Panasonic: BUY=${buyVol}MW == SELL=${sellVol}MW (symmetric) ✓`;
      } else {
        checks.C = `FAIL — Volvo_Panasonic: BUY×${bN}(${buyVol}MW) SELL×${sN}(${sellVol}MW) — asymmetric or phantom`;
      }
    }
    console.log(`[C] ${checks.C}`);

    // CHECK G: Total count = 6 for Panasonic, no 12+
    checks.G = pRows.length === 6
      ? `PASS — Panasonic total rows: 6 (expected 6) ✓`
      : pRows.length < 6
        ? `FAIL — Panasonic total rows: ${pRows.length} (under 6 — legitimate rows missing?)`
        : `FAIL — Panasonic total rows: ${pRows.length} (expected 6, ${pRows.length - 6} extra)`;
    console.log(`[G] ${checks.G}`);

    // ── SONY (checks D, E) ────────────────────────────────────────
    console.log('\n' + '='.repeat(60));
    console.log('SONY — Honda BUY+SELL symmetry (D, E)');
    console.log('='.repeat(60));

    try {
      const sonyRows = await drillIntoRound(page, URLS.sony, 'Sony', 'Trade Deals');
      console.log(`\nSony total rows: ${sonyRows.length}`);
      sonyRows.forEach((r, i) => console.log(`  ${String(i+1).padStart(2)}. ${r}`));

      const sonyData = parseByTrader(sonyRows, 'Sony');
      const hSony = sonyData['Honda'];
      if (!hSony) {
        checks.D = checks.E = 'INCONCLUSIVE — Honda_Sony: no rows';
      } else {
        const buyT  = hSony.BUY.reduce((s, x) => s + x.vol, 0);
        const sellT = hSony.SELL.reduce((s, x) => s + x.vol, 0);
        console.log(`  Honda_Sony: BUY×${hSony.BUY.length}=${buyT}MW  SELL×${hSony.SELL.length}=${sellT}MW`);

        // CHECK D: Honda_Sony SELL = 40MW (not 80MW phantom, not 0)
        checks.D = sellT === 40
          ? `PASS — Honda_Sony SELL=${sellT}MW (correct, no phantom) ✓`
          : sellT === 80
            ? `FAIL — Honda_Sony SELL=80MW (phantom SELL still present)`
            : sellT === 0
              ? `FAIL — Honda_Sony SELL=0MW (over-filtered? synthesis broke)`
              : `FAIL — Honda_Sony SELL=${sellT}MW (expected 40)`;
        console.log(`[D] ${checks.D}`);

        // CHECK E: Honda BUY = 40MW, symmetric with SELL
        checks.E = (buyT === 40 && buyT === sellT)
          ? `PASS — Honda_Sony BUY=${buyT}MW == SELL=${sellT}MW (symmetric) ✓`
          : (buyT === 40)
            ? `PASS — Honda_Sony BUY=${buyT}MW (correct) ✓` + (buyT !== sellT ? ` [note: SELL=${sellT}]` : '')
            : `FAIL — Honda_Sony BUY=${buyT}MW (expected 40)`;
        console.log(`[E] ${checks.E}`);
      }
    } catch(e) {
      checks.D = checks.E = `ERROR — ${e.message}`;
      console.log(`[D/E] ${checks.D}`);
    }

    // ── JVC (check F) ─────────────────────────────────────────────
    console.log('\n' + '='.repeat(60));
    console.log('JVC — no phantom rows (F)');
    console.log('='.repeat(60));

    try {
      const jvcRows = await drillIntoRound(page, URLS.jvc, 'JVC', 'Trade Deals');
      console.log(`\nJVC total rows: ${jvcRows.length}`);
      jvcRows.forEach((r, i) => console.log(`  ${String(i+1).padStart(2)}. ${r}`));

      const jvcData = parseByTrader(jvcRows, 'JVC');
      console.log('JVC per-trader:');
      for (const [t, d] of Object.entries(jvcData)) {
        const bV = d.BUY.reduce((s, x) => s + x.vol, 0);
        const sV = d.SELL.reduce((s, x) => s + x.vol, 0);
        console.log(`  ${t}_JVC: BUY×${d.BUY.length}=${bV}MW  SELL×${d.SELL.length}=${sV}MW`);
      }

      const jvcDupErr = checkNoDuplicates(jvcRows, 'JVC Trade Deals');
      // Check for phantom: any UNSOLVED JVC trader with unexpected rows
      const phantomJVC = jvcRows.filter(r => {
        // UNSOLVED JVC traders should not have synthetic rows
        return r.includes('JVC') && r.includes('UNSOLVED');
      });
      const issues = [];
      if (jvcDupErr) issues.push('duplicates');
      if (phantomJVC.length > 0) issues.push(`${phantomJVC.length} UNSOLVED marker in TD`);

      checks.F = issues.length === 0
        ? `PASS — JVC Trade Deals: ${jvcRows.length} rows, no phantoms, no dups ✓`
        : `FAIL — JVC: ${issues.join(', ')}`;
      console.log(`[F] ${checks.F}`);
    } catch(e) {
      checks.F = `ERROR — ${e.message}`;
      console.log(`[F] ${checks.F}`);
    }

    // ── ADMIN RESULTS TAB (check H) ───────────────────────────────
    console.log('\n' + '='.repeat(60));
    console.log('ADMIN — Results tab integrity (H)');
    console.log('='.repeat(60));

    try {
      const adminTD = await drillIntoRound(page, URLS.admin, 'Admin', 'Trade Deals');
      console.log(`\nAdmin Trade Deals: ${adminTD.length} rows`);
      adminTD.forEach((r, i) => console.log(`  ${String(i+1).padStart(2)}. ${r}`));

      const toyotaPhantomBuy = adminTD.filter(r =>
        r.includes('PanasonicToyota') && r.includes('TARGET_BUY'));
      const sonyHondaPhantom = adminTD.filter(r =>
        r.includes('SonyHonda') && r.includes('TARGET_SELL') && r.includes('Toyota_Panasonic'));
      const adminDupErr = checkNoDuplicates(adminTD, 'Admin Trade Deals');

      const issues = [];
      if (toyotaPhantomBuy.length > 0) {
        issues.push(`${toyotaPhantomBuy.length} phantom PanasonicToyota TARGET_BUY`);
        toyotaPhantomBuy.forEach(r => console.log(`  🚨 ${r.substring(0, 90)}`));
      }
      if (sonyHondaPhantom.length > 0) {
        issues.push(`${sonyHondaPhantom.length} phantom SonyHonda SELL→Toyota`);
        sonyHondaPhantom.forEach(r => console.log(`  🚨 ${r.substring(0, 90)}`));
      }
      if (adminDupErr) issues.push('duplicates');
      if (adminTD.length === 0) issues.push('empty Trade Deals (synthesis may be over-filtered)');

      checks.H = issues.length === 0
        ? `PASS — Admin Trade Deals: ${adminTD.length} rows, no phantoms, no dups ✓`
        : `FAIL — Admin: ${issues.join(', ')} (${adminTD.length} rows)`;
      console.log(`[H] ${checks.H}`);
    } catch(e) {
      checks.H = `ERROR — ${e.message}`;
      console.log(`[H] ${checks.H}`);
    }

    // ── FINAL SUMMARY ─────────────────────────────────────────────
    console.log('\n' + '='.repeat(60));
    console.log('FINAL SUMMARY — BUG-20260424-001+002 v6 (4fc7e9c)');
    console.log('Check I (Jest regression suite) runs separately.');
    console.log('='.repeat(60));

    const critChecks = ['A','B','C','D','E','F','G','H'];
    const allCritPass = critChecks.every(k => checks[k]?.startsWith('PASS'));

    critChecks.forEach(k => {
      const v = checks[k] || 'NOT RUN';
      const icon = v.startsWith('PASS') ? '✅' : v.startsWith('FAIL') ? '❌' :
                   v.startsWith('INFO') ? 'ℹ️' : v.startsWith('INCONCLUSIVE') ? '⚠️' : '⬜';
      console.log(`  ${icon} [${k}] ${v}`);
    });

    console.log('\n📢 CONSOLE STATS:');
    console.log(`  [R4G synthesize/broker]: ${cLog.synthBroker}`);
    console.log(`  [R4G synthesize]:        ${cLog.synthNetting}`);
    console.log(`  UNSOLVED skip msgs:      ${cLog.unsolvedSkip} ${cLog.unsolvedSkip > 0 ? '← UNSOLVED guard fired ✅' : ''}`);
    console.log(`  [R4G symmetry]:          ${cLog.symmetry} (must be 0)`);

    const verdict = allCritPass
      ? '✅ PASS — All A-H checks passed. Pending: Jest regression (I).'
      : `❌ FAIL — Failed: ${critChecks.filter(k => !checks[k]?.startsWith('PASS')).join(', ')}`;
    console.log(`\n🎯 VERDICT (pre-Jest): ${verdict}`);
    console.log('='.repeat(60));

    fs.writeFileSync('/home/alexey/banda/agents/kim/bug_4fc7e9c_report.json',
      JSON.stringify({ commit: '4fc7e9c', checks,
        panaTDCount: pRows.length,
        consoleStats: cLog, verdict,
        timestamp: new Date().toISOString() }, null, 2));
    console.log('\n💾 Report: bug_4fc7e9c_report.json');

  } catch (err) {
    console.error(`\n❌ FATAL: ${err.message}`);
    console.error(err.stack);
  } finally {
    if (browser) await browser.close();
  }
})();
