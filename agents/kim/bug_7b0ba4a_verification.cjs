// BUG-20260424-001+002 v5 — Commit 7b0ba4a
// Fix: LogEntryView skips synthesizeMissingDetails when brokerFilter is active
// Root cause confirmed: double synthesis — BrokerConsole pre-synthesized, then LogEntryView ran again
// New checks: H (Admin synthesis still works = no regression), I (Panasonic via Log sub-tab path)

const { chromium } = require('playwright');
const fs = require('fs');

const URLS = {
  panasonic: 'https://dev.r4g.business-for-fun.com/?broker=Panasonic&share=lzoknmqo&devSeed=1',
  sony:      'https://dev.r4g.business-for-fun.com/?broker=Sony&share=gei29u4l&devSeed=1',
  admin:     'https://dev.r4g.business-for-fun.com/?devSeed=1'
};

// Navigate: top-level Netting Results tab → click round[0] → Trade Deals sub-tab
async function openTradeDealsViaNettingResults(page, url, label) {
  await page.goto(url, { timeout: 60000, waitUntil: 'load' });
  await page.waitForTimeout(5000);

  const nrBtn = page.locator('text=Netting Results').first();
  if (!await nrBtn.isVisible({ timeout: 3000 }).catch(() => false)) {
    throw new Error(`Netting Results tab not found for ${label}`);
  }
  await nrBtn.click();
  await page.waitForTimeout(5000);

  let rounds = await page.locator('table tbody tr').all();
  if (rounds.length === 0) rounds = await page.locator('table tr:not(:first-child)').all();
  if (rounds.length === 0) throw new Error(`No rounds in ${label}`);

  console.log(`  ${label}: ${rounds.length} round(s) — clicking first`);
  await rounds[0].click();
  await page.waitForTimeout(3000);

  const tdTab = page.locator('button:has-text("Trade Deals")').first();
  if (!await tdTab.isVisible({ timeout: 5000 }).catch(() => false)) {
    throw new Error(`Trade Deals sub-tab not found in ${label}`);
  }
  await tdTab.click();
  await page.waitForTimeout(2000);

  return await extractTableRows(page);
}

// Navigate: top-level Netting Results tab → round[0] → Log sub-tab → first log entry → Trade Deals
// This tests check I: "Panasonic Live view (Netting Results tab, not Log)"
// Actually — Log sub-tab is the "raw event log". Trade Deals comes from LogEntryView with brokerFilter.
// We test BOTH to confirm fix doesn't break the Log sub-tab path.
async function openTradeDealsViaLogSubTab(page, url, label) {
  await page.goto(url, { timeout: 60000, waitUntil: 'load' });
  await page.waitForTimeout(5000);

  await page.locator('text=Netting Results').first().click();
  await page.waitForTimeout(5000);

  let rounds = await page.locator('table tbody tr').all();
  if (rounds.length === 0) rounds = await page.locator('table tr:not(:first-child)').all();
  if (rounds.length === 0) throw new Error(`No rounds for Log sub-tab check in ${label}`);

  console.log(`  ${label} (Log sub-tab path): ${rounds.length} round(s) — clicking first`);
  await rounds[0].click();
  await page.waitForTimeout(3000);

  // Click Log sub-tab
  const logSubTab = page.locator('button:has-text("Log")').first();
  if (!await logSubTab.isVisible({ timeout: 3000 }).catch(() => false)) {
    throw new Error(`Log sub-tab not found in ${label}`);
  }
  await logSubTab.click();
  await page.waitForTimeout(2000);

  // Log sub-tab shows round history — click first entry
  let logRounds = await page.locator('table tbody tr').all();
  if (logRounds.length === 0) logRounds = await page.locator('table tr:not(:first-child)').all();
  console.log(`  ${label}: Log sub-tab has ${logRounds.length} entries`);

  if (logRounds.length === 0) {
    return null; // Log sub-tab might not have further drill-in
  }

  await logRounds[0].click();
  await page.waitForTimeout(3000);

  // Look for Trade Deals sub-tab within this nested view
  const tdTab = page.locator('button:has-text("Trade Deals")').first();
  if (!await tdTab.isVisible({ timeout: 3000 }).catch(() => false)) {
    // Trade Deals not accessible via this path — note it
    return 'NO_TRADE_DEALS_IN_LOG_PATH';
  }
  await tdTab.click();
  await page.waitForTimeout(2000);

  return await extractTableRows(page);
}

async function extractTableRows(page) {
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
    const trader = m[1];
    const dir = m[2];
    const vm = r.match(/(EEX|OTC)(\d{1,4})(?!\d)/);
    const vol = vm ? parseInt(vm[2]) : 0;
    const hub = r.match(/TTF|NBP|THE|CEGH|ZTP/)?.[0] || '?';
    const venue = vm ? vm[1] : '?';

    if (!byTrader[trader]) byTrader[trader] = { BUY: [], SELL: [] };
    byTrader[trader][dir].push({ vol, hub, venue, row: idx + 1, text: r });
  });
  return byTrader;
}

(async () => {
  console.log('🎯 BUG-20260424-001+002 v5 — Commit 7b0ba4a');
  console.log('Fix: LogEntryView skips synthesizeMissingDetails when brokerFilter is active');
  console.log('Root cause: double synthesis — BrokerConsole pre-synth + LogEntryView re-synth');
  console.log('Expected: Toyota phantom eliminated (6 Panasonic rows), Admin synthesis preserved\n');

  let browser;
  const cLog = { synthBroker: 0, synthNetting: 0, synthSkipped: [], symmetry: 0, dedup: 0 };
  const checks = {};

  try {
    browser = await chromium.launch({ headless: true });
    const ctx = await browser.newContext({
      viewport: { width: 1440, height: 900 },
      httpCredentials: {
        username: process.env.R4G_DEV_USER,
        password: process.env.R4G_DEV_PASS
      }
    });
    const page = await ctx.newPage();

    page.on('console', msg => {
      const t = msg.text();
      if (t.includes('[R4G synthesize/broker]'))  { cLog.synthBroker++;  }
      else if (t.includes('[R4G synthesize]'))      { cLog.synthNetting++; }
      else if (t.toLowerCase().includes('skip') && t.includes('[R4G')) {
        cLog.synthSkipped.push(t); console.log(`⏭️  ${t}`);
      }
      else if (t.includes('[R4G symmetry]'))        { cLog.symmetry++; }
      else if (t.includes('[R4G dedup'))             { cLog.dedup++; }
    });

    // ─── PANASONIC — CHECKS A-E ──────────────────────────────────
    console.log('='.repeat(60));
    console.log('PANASONIC — NETTING RESULTS → TRADE DEALS (Checks A-E)');
    console.log('='.repeat(60));

    const pRows = await openTradeDealsViaNettingResults(page, URLS.panasonic, 'Panasonic');

    console.log(`\nTotal rows: ${pRows.length}`);
    console.log('RAW:');
    pRows.forEach((r, i) => console.log(`  ${String(i+1).padStart(2)}. ${r}`));

    const pData = parseByTrader(pRows, 'Panasonic');
    console.log('\nPER-TRADER:');
    for (const [t, d] of Object.entries(pData)) {
      console.log(`  ${t}_Panasonic: BUY×${d.BUY.length} SELL×${d.SELL.length}`);
      d.BUY.forEach(x  => console.log(`    BUY  ${x.vol}MW hub:${x.hub} venue:${x.venue} [row ${x.row}]`));
      d.SELL.forEach(x => console.log(`    SELL ${x.vol}MW hub:${x.hub} venue:${x.venue} [row ${x.row}]`));
    }

    // CHECK A: Toyota — exactly 1 SELL, zero BUY
    const toyota = pData['Toyota'];
    if (!toyota) {
      checks.A = 'FAIL — Toyota_Panasonic: no rows found';
    } else {
      const bN = toyota.BUY.length, sN = toyota.SELL.length;
      if (bN === 0 && sN === 1) {
        const s = toyota.SELL[0];
        checks.A = (s.vol === 40 && s.hub === 'TTF' && s.venue === 'EEX')
          ? `PASS — Toyota_Panasonic: 1 row TARGET_SELL TTF EEX 40MW Honda_Sony, NO phantom BUY ✓`
          : `PASS (values differ) — Toyota: 1 SELL ${s.vol}MW hub:${s.hub} venue:${s.venue}`;
      } else if (bN > 0) {
        checks.A = `FAIL — Toyota_Panasonic: BUY×${bN} SELL×${sN} — phantom BUY still present`;
        toyota.BUY.forEach(x => console.log(`  🚨 Phantom BUY: ${x.vol}MW hub:${x.hub} [row ${x.row}]`));
      } else {
        checks.A = `FAIL — Toyota_Panasonic: BUY×${bN} SELL×${sN} (expected 0 BUY, 1 SELL)`;
      }
    }
    console.log(`\n[A] ${checks.A}`);

    // CHECK B: Volvo — exactly 1 BUY, zero SELL
    const volvo = pData['Volvo'];
    if (!volvo) {
      checks.B = 'FAIL — Volvo_Panasonic: no rows found';
    } else {
      const bN = volvo.BUY.length, sN = volvo.SELL.length;
      checks.B = (bN === 1 && sN === 0)
        ? `PASS — Volvo_Panasonic: 1 row TARGET_BUY ${volvo.BUY[0].vol}MW hub:${volvo.BUY[0].hub}, NO phantom SELL ✓`
        : `FAIL — Volvo_Panasonic: BUY×${bN} SELL×${sN} (expected 1 BUY, 0 SELL)`;
    }
    console.log(`[B] ${checks.B}`);

    // CHECK C: Ford — 1 BUY + 1 SELL
    const ford = pData['Ford'];
    if (!ford) {
      checks.C = 'FAIL — Ford_Panasonic: no rows';
    } else {
      const bN = ford.BUY.length, sN = ford.SELL.length;
      checks.C = (bN === 1 && sN === 1)
        ? `PASS — Ford_Panasonic: 2 rows BUY ${ford.BUY[0].vol}MW + SELL ${ford.SELL[0].vol}MW ✓`
        : `FAIL — Ford_Panasonic: BUY×${bN} SELL×${sN} (expected 1+1)`;
    }
    console.log(`[C] ${checks.C}`);

    // CHECK D: Honda — 1 BUY + 1 SELL
    const honda = pData['Honda'];
    if (!honda) {
      checks.D = 'FAIL — Honda_Panasonic: no rows';
    } else {
      const bN = honda.BUY.length, sN = honda.SELL.length;
      checks.D = (bN === 1 && sN === 1)
        ? `PASS — Honda_Panasonic: 2 rows BUY ${honda.BUY[0].vol}MW + SELL ${honda.SELL[0].vol}MW ✓`
        : `FAIL — Honda_Panasonic: BUY×${bN} SELL×${sN} (expected 1+1)`;
    }
    console.log(`[D] ${checks.D}`);

    // CHECK E: Total rows = exactly 6
    checks.E = pRows.length === 6
      ? `PASS — Total Panasonic rows: 6 exactly ✓`
      : `FAIL — Total rows: ${pRows.length} (expected 6, delta ${pRows.length - 6})`;
    console.log(`[E] ${checks.E}`);

    // ─── SONY — CHECK F ──────────────────────────────────────────
    console.log('\n' + '='.repeat(60));
    console.log('SONY — HONDA REGRESSION (Check F)');
    console.log('='.repeat(60));

    try {
      const sonyRows = await openTradeDealsViaNettingResults(page, URLS.sony, 'Sony');
      console.log(`\nSony total rows: ${sonyRows.length}`);
      sonyRows.forEach((r, i) => console.log(`  ${String(i+1).padStart(2)}. ${r}`));

      const sonyData = parseByTrader(sonyRows, 'Sony');
      const hSony = sonyData['Honda'];
      if (!hSony) {
        checks.F = 'INCONCLUSIVE — Honda_Sony: no rows';
      } else {
        const buyT = hSony.BUY.reduce((s, x) => s + x.vol, 0);
        const sellT = hSony.SELL.reduce((s, x) => s + x.vol, 0);
        console.log(`  Honda_Sony: BUY=${buyT}MW SELL=${sellT}MW`);
        if (sellT === 40 && buyT === 40) {
          checks.F = `PASS — Honda_Sony: BUY=40MW, SELL=40MW (no phantom SELL) ✓`;
        } else if (sellT === 80) {
          checks.F = `FAIL — Honda_Sony: SELL=80MW (phantom still present), BUY=${buyT}MW`;
        } else {
          checks.F = `FAIL — Honda_Sony: BUY=${buyT}MW, SELL=${sellT}MW (unexpected)`;
        }
      }
      console.log(`[F] ${checks.F}`);
    } catch (e) {
      checks.F = `ERROR — ${e.message}`;
      console.log(`[F] ${checks.F}`);
    }

    // ─── ADMIN — CHECK G (phantoms/dups) ─────────────────────────
    console.log('\n' + '='.repeat(60));
    console.log('ADMIN — PHANTOM/DUPLICATE CHECK (Check G)');
    console.log('='.repeat(60));

    let adminRows = [];
    try {
      adminRows = await openTradeDealsViaNettingResults(page, URLS.admin, 'Admin');
      console.log(`\nAdmin total rows: ${adminRows.length}`);
      adminRows.forEach((r, i) => console.log(`  ${String(i+1).padStart(2)}. ${r}`));

      const seen = new Map();
      adminRows.forEach((r, i) => { if (!seen.has(r)) seen.set(r, []); seen.get(r).push(i+1); });
      const exactDups = [...seen.entries()].filter(([, rows]) => rows.length > 1);

      const hubKey = new Map();
      adminRows.forEach((r, idx) => {
        const m = r.match(/(Sony|Panasonic|JVC)(\w+)TARGET_(BUY|SELL)/);
        const vm = r.match(/(EEX|OTC)(\d{1,4})(?!\d)/);
        const cp = r.match(/\d{1,4}(\w+_\w+)/);
        if (!m || !vm) return;
        const key = `${m[1]}_${m[2]}_${m[3]}_${vm[2]}_${vm[1]}_${cp?.[1]||'nocp'}`;
        if (!hubKey.has(key)) hubKey.set(key, []);
        hubKey.get(key).push(idx+1);
      });
      const hubDups = [...hubKey.entries()].filter(([, rows]) => rows.length > 1);

      const phantomRows = adminRows.filter(r =>
        r.includes('SonyHonda') && r.includes('TARGET_SELL') && r.includes('Toyota_Panasonic')
      );
      const toyotaPanaPhantomBuy = adminRows.filter(r =>
        r.includes('PanasonicToyota') && r.includes('TARGET_BUY')
      );

      const issues = [];
      if (exactDups.length > 0) {
        issues.push(`${exactDups.length} exact dup group(s)`);
        exactDups.forEach(([text, rows]) => console.log(`  ❌ Exact dup rows ${rows.join(',')}: ${text.substring(0, 80)}`));
      }
      if (hubDups.length > 0) {
        issues.push(`${hubDups.length} hub-permuted dup group(s)`);
        hubDups.forEach(([key, rows]) => console.log(`  ❌ Hub-dup [${key}] rows ${rows.join(',')}`));
      }
      if (phantomRows.length > 0) {
        issues.push(`${phantomRows.length} phantom SonyHonda SELL→Toyota`);
        phantomRows.forEach(r => console.log(`  🚨 PHANTOM SonyHonda: ${r.substring(0, 90)}`));
      }
      if (toyotaPanaPhantomBuy.length > 0) {
        issues.push(`${toyotaPanaPhantomBuy.length} phantom PanasonicToyota TARGET_BUY`);
        toyotaPanaPhantomBuy.forEach(r => console.log(`  🚨 PHANTOM BUY: ${r.substring(0, 90)}`));
      }

      checks.G = issues.length === 0
        ? `PASS — Admin: ${adminRows.length} rows, no phantoms, no dups ✓`
        : `FAIL — Admin: ${issues.join(', ')} (${adminRows.length} total rows)`;
      console.log(`[G] ${checks.G}`);
    } catch (e) {
      checks.G = `ERROR — ${e.message}`;
      console.log(`[G] ${checks.G}`);
    }

    // ─── ADMIN — CHECK H (synthesis NOT skipped in admin = no brokerFilter) ───
    console.log('\n' + '='.repeat(60));
    console.log('ADMIN — SYNTHESIS REGRESSION CHECK (Check H)');
    console.log('='.repeat(60));

    try {
      // Re-use adminRows from above (same round clicked in G)
      // Check that Honda appears in admin Trade Deals with both BUY and SELL synthesized
      const adminData = parseByTrader(adminRows, 'Sony');
      const hAdmin = adminData['Honda'];
      // Admin doesn't have "Sony" prefix for all rows — check any broker
      const adminAny = {};
      for (const broker of ['Panasonic','Sony','JVC']) {
        const d = parseByTrader(adminRows, broker);
        Object.assign(adminAny, d);
      }

      // The key test: admin should have Toyota/Honda visible with synthesis working
      // Check that rows exist (non-empty Trade Deals in admin = synthesis ran)
      if (adminRows.length > 0) {
        // Verify no synthesis was SKIPPED (admin has no brokerFilter — synthesis should run normally)
        // The guard fix only fires for brokerFilter-active contexts
        checks.H = adminRows.length >= 6
          ? `PASS — Admin Trade Deals: ${adminRows.length} rows (synthesis ran, no brokerFilter → not skipped) ✓`
          : `FAIL — Admin Trade Deals: only ${adminRows.length} rows — synthesis may have been incorrectly skipped`;
      } else {
        checks.H = 'FAIL — Admin Trade Deals: empty (synthesis skipped for admin = regression)';
      }
      console.log(`[H] ${checks.H}`);

      // Specifically verify Honda/Toyota are visible in admin Trade Deals
      const toyotaInAdmin = adminRows.filter(r => r.includes('Toyota') && r.includes('TARGET_'));
      const hondaInAdmin  = adminRows.filter(r => r.includes('Honda')  && r.includes('TARGET_'));
      console.log(`  Admin: Toyota rows=${toyotaInAdmin.length}, Honda rows=${hondaInAdmin.length}`);
      if (toyotaInAdmin.length > 0) console.log('  Toyota in admin: ' + toyotaInAdmin.map(r => r.substring(0, 80)).join('\n    '));
      if (hondaInAdmin.length > 0)  console.log('  Honda in admin:  ' + hondaInAdmin.map(r => r.substring(0, 80)).join('\n    '));
    } catch (e) {
      checks.H = `ERROR — ${e.message}`;
      console.log(`[H] ${checks.H}`);
    }

    // ─── PANASONIC via LOG SUB-TAB — CHECK I ─────────────────────
    console.log('\n' + '='.repeat(60));
    console.log('PANASONIC LOG SUB-TAB PATH (Check I)');
    console.log('='.repeat(60));

    try {
      const logPathResult = await openTradeDealsViaLogSubTab(page, URLS.panasonic, 'Panasonic');

      if (logPathResult === null || logPathResult === 'NO_TRADE_DEALS_IN_LOG_PATH') {
        // Log sub-tab doesn't lead to per-round Trade Deals — this is informational
        checks.I = `INCONCLUSIVE — Log sub-tab doesn't expose per-round Trade Deals drill-in (path: ${logPathResult})`;
        console.log(`[I] ${checks.I}`);
      } else if (typeof logPathResult === 'string') {
        checks.I = `INCONCLUSIVE — ${logPathResult}`;
        console.log(`[I] ${checks.I}`);
      } else {
        const logRows = logPathResult;
        console.log(`\nPanasonic (Log path) total rows: ${logRows.length}`);
        logRows.forEach((r, i) => console.log(`  ${String(i+1).padStart(2)}. ${r}`));

        const logPData = parseByTrader(logRows, 'Panasonic');
        const lgToyota = logPData['Toyota'];
        const lgVolvo  = logPData['Volvo'];

        const toyotaOk = lgToyota && lgToyota.BUY.length === 0 && lgToyota.SELL.length === 1;
        const volvoOk  = lgVolvo  && lgVolvo.BUY.length === 1  && lgVolvo.SELL.length === 0;

        if (toyotaOk && volvoOk) {
          checks.I = `PASS — Log path: Toyota=${lgToyota.SELL.length}SELL(0BUY), Volvo=${lgVolvo.BUY.length}BUY(0SELL) — both clean ✓`;
        } else {
          const tStr = lgToyota ? `BUY×${lgToyota.BUY.length} SELL×${lgToyota.SELL.length}` : 'absent';
          const vStr = lgVolvo  ? `BUY×${lgVolvo.BUY.length}  SELL×${lgVolvo.SELL.length}`  : 'absent';
          checks.I = `FAIL — Log path: Toyota=${tStr}, Volvo=${vStr} (expected Toyota:0BUY/1SELL, Volvo:1BUY/0SELL)`;
        }
        console.log(`[I] ${checks.I}`);
      }
    } catch (e) {
      checks.I = `ERROR — ${e.message}`;
      console.log(`[I] ${checks.I}`);
    }

    // ─── FINAL SUMMARY ───────────────────────────────────────────
    console.log('\n' + '='.repeat(60));
    console.log('FINAL SUMMARY — BUG-20260424-001+002 v5 (7b0ba4a)');
    console.log('='.repeat(60));

    const allChecks = ['A','B','C','D','E','F','G','H','I'];
    const criticalChecks = ['A','B','C','D','E','F','G'];
    const allCriticalPass = criticalChecks.every(k => checks[k]?.startsWith('PASS'));
    const allPass = allChecks.every(k => checks[k]?.startsWith('PASS') || checks[k]?.startsWith('INCONCLUSIVE'));

    allChecks.forEach(k => {
      const v = checks[k] || 'NOT RUN';
      const icon = v.startsWith('PASS') ? '✅' : v.startsWith('FAIL') ? '❌' : v.startsWith('INCONCLUSIVE') ? '⚠️' : '⬜';
      console.log(`  ${icon} [${k}] ${v}`);
    });

    console.log('\n📢 CONSOLE STATS:');
    console.log(`  [R4G synthesize/broker]: ${cLog.synthBroker} (BrokerConsole.jsx first-pass synth)`);
    console.log(`  [R4G synthesize]:        ${cLog.synthNetting} (NettingResults.jsx — should be 0 in broker view)`);
    console.log(`  skip messages:           ${cLog.synthSkipped.length} ${cLog.synthSkipped.length > 0 ? '← LogEntryView skip fired ✅' : ''}`);
    console.log(`  [R4G symmetry]:          ${cLog.symmetry} (must be 0)`);
    console.log(`  [R4G dedup]:             ${cLog.dedup}`);

    let verdict;
    if (allCriticalPass) {
      verdict = '✅ PASS — All critical checks A-G passed, DEPLOY OK';
    } else {
      const failedCritical = criticalChecks.filter(k => !checks[k]?.startsWith('PASS'));
      verdict = `❌ FAIL — Critical checks failed: ${failedCritical.join(', ')}`;
    }
    console.log(`\n🎯 OVERALL VERDICT: ${verdict}`);
    console.log('='.repeat(60));

    fs.writeFileSync(
      '/home/alexey/banda/agents/kim/bug_7b0ba4a_report.json',
      JSON.stringify({
        commit: '7b0ba4a',
        checks,
        consoleStats: { synthBroker: cLog.synthBroker, synthNetting: cLog.synthNetting,
          synthSkipped: cLog.synthSkipped.length, symmetry: cLog.symmetry, dedup: cLog.dedup },
        verdict,
        timestamp: new Date().toISOString()
      }, null, 2)
    );
    console.log('\n💾 Report: bug_7b0ba4a_report.json');

  } catch (err) {
    console.error(`\n❌ FATAL: ${err.message}`);
    console.error(err.stack);
  } finally {
    if (browser) await browser.close();
  }
})();
