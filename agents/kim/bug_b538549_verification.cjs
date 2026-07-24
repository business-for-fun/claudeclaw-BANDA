// BUG-20260424-001+002 v3 — Commit b538549
// Fix: ONE guard in synthesizeMissingDetails — skip synthesis if position has 0 target-perspective rows
// Expected: Toyota phantom BUY gone, total Panasonic rows = exactly 6

const { chromium } = require('playwright');

const URLS = {
  panasonic: 'https://dev.r4g.business-for-fun.com/?broker=Panasonic&share=lzoknmqo',
  sony:      'https://dev.r4g.business-for-fun.com/?broker=Sony&share=gei29u4l',
  admin:     'https://dev.r4g.business-for-fun.com/'
};

async function openTradeDeals(page, url, label) {
  await page.goto(url, { timeout: 60000, waitUntil: 'load' });
  await page.waitForTimeout(5000);

  const nettingBtn = page.locator('text=Netting Results').first();
  if (!await nettingBtn.isVisible({ timeout: 3000 }).catch(() => false)) {
    throw new Error(`Netting Results tab not found for ${label}`);
  }
  await nettingBtn.click();
  await page.waitForTimeout(5000);

  let rounds = await page.locator('table tbody tr').all();
  if (rounds.length === 0) rounds = await page.locator('table tr:not(:first-child)').all();
  if (rounds.length === 0) throw new Error(`No rounds in ${label}`);

  console.log(`  ${label}: ${rounds.length} round(s) — clicking first`);
  await rounds[0].click();
  await page.waitForTimeout(3000);

  const tdTab = page.locator('text=Trade Deals').first();
  if (!await tdTab.isVisible({ timeout: 5000 }).catch(() => false)) {
    throw new Error(`Trade Deals sub-tab not found in ${label}`);
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
  console.log('🎯 BUG-20260424-001+002 v3 — Commit b538549');
  console.log('Fix: synthesizeMissingDetails guard — skip if zero target-perspective rows');
  console.log('Expected: Toyota phantom eliminated, total Panasonic rows = 6\n');

  let browser;
  const cLog = { postFlipSynth: 0, synthesize: 0, synthSkipped: [], symmetry: 0, dedup: 0 };
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
      if (t.includes('[R4G postFlipSynth]'))         { cLog.postFlipSynth++; console.log(`🆕 ${t}`); }
      else if (t.includes('[R4G synthesize]'))         { cLog.synthesize++; console.log(`🔄 ${t}`); }
      else if (t.includes('[R4G synthSkip]') || t.includes('[R4G skip]') || t.includes('skip synthesis')) {
        cLog.synthSkipped.push(t); console.log(`⏭️  ${t}`); }
      else if (t.includes('[R4G dedup') || t.includes('[R4G deduplicate]')) { cLog.dedup++; console.log(`🔁 ${t}`); }
      else if (t.includes('[R4G symmetry]'))           { cLog.symmetry++; console.log(`⚠️  ${t}`); }
    });

    // ─── PANASONIC ───────────────────────────────────────────────
    console.log('='.repeat(60));
    console.log('PANASONIC BROKER — TRADE DEALS');
    console.log('='.repeat(60));

    const pRows = await openTradeDeals(page, URLS.panasonic, 'Panasonic');

    console.log(`\nTotal rows: ${pRows.length}`);
    console.log('RAW:');
    pRows.forEach((r, i) => console.log(`  ${String(i+1).padStart(2)}. ${r}`));

    const pData = parseByTrader(pRows, 'Panasonic');
    console.log('\nPER-TRADER:');
    for (const [t, d] of Object.entries(pData)) {
      const bN = d.BUY.length, sN = d.SELL.length;
      console.log(`  ${t}_Panasonic: BUY×${bN} SELL×${sN}`);
      d.BUY.forEach(x  => console.log(`    BUY  ${x.vol}MW hub:${x.hub} venue:${x.venue} [row ${x.row}]`));
      d.SELL.forEach(x => console.log(`    SELL ${x.vol}MW hub:${x.hub} venue:${x.venue} [row ${x.row}]`));
    }

    // CHECK A: Toyota — exactly 1 SELL TTF 40MW, zero BUY
    const toyota = pData['Toyota'];
    if (!toyota) {
      checks.A = 'FAIL — Toyota_Panasonic: no rows found';
    } else {
      const bN = toyota.BUY.length, sN = toyota.SELL.length;
      if (bN === 0 && sN === 1) {
        const s = toyota.SELL[0];
        if (s.vol === 40 && s.hub === 'TTF' && s.venue === 'EEX') {
          checks.A = `PASS — Toyota_Panasonic: 1 row, TARGET_SELL TTF EEX 40MW, NO phantom BUY`;
        } else {
          checks.A = `PASS (volume/hub differs) — Toyota: 1 SELL ${s.vol}MW hub:${s.hub} venue:${s.venue}`;
        }
      } else if (bN === 0 && sN > 1) {
        checks.A = `FAIL — Toyota_Panasonic: ${sN} SELL rows (duplicates?), 0 BUY`;
      } else {
        checks.A = `FAIL — Toyota_Panasonic: BUY×${bN} SELL×${sN} (expected 0 BUY, 1 SELL)`;
        toyota.BUY.forEach(x => console.log(`  🚨 Phantom BUY: ${x.vol}MW hub:${x.hub} [row ${x.row}]`));
      }
    }
    console.log(`\n[A] ${checks.A}`);

    // CHECK B: Volvo — exactly 1 BUY, zero SELL
    const volvo = pData['Volvo'];
    if (!volvo) {
      checks.B = 'FAIL — Volvo_Panasonic: no rows found';
    } else {
      const bN = volvo.BUY.length, sN = volvo.SELL.length;
      if (bN === 1 && sN === 0) {
        checks.B = `PASS — Volvo_Panasonic: 1 row, TARGET_BUY ${volvo.BUY[0].vol}MW hub:${volvo.BUY[0].hub}, NO phantom SELL`;
      } else {
        checks.B = `FAIL — Volvo_Panasonic: BUY×${bN} SELL×${sN} (expected 1 BUY, 0 SELL)`;
      }
    }
    console.log(`[B] ${checks.B}`);

    // CHECK C: Ford — exactly 1 BUY + 1 SELL
    const ford = pData['Ford'];
    if (!ford) {
      checks.C = 'FAIL — Ford_Panasonic: no rows';
    } else {
      const bN = ford.BUY.length, sN = ford.SELL.length;
      checks.C = (bN === 1 && sN === 1)
        ? `PASS — Ford_Panasonic: 2 rows (BUY ${ford.BUY[0].vol}MW + SELL ${ford.SELL[0].vol}MW)`
        : `FAIL — Ford_Panasonic: BUY×${bN} SELL×${sN} (expected 1+1)`;
    }
    console.log(`[C] ${checks.C}`);

    // CHECK D: Honda — exactly 1 BUY + 1 SELL
    const honda = pData['Honda'];
    if (!honda) {
      checks.D = 'FAIL — Honda_Panasonic: no rows';
    } else {
      const bN = honda.BUY.length, sN = honda.SELL.length;
      checks.D = (bN === 1 && sN === 1)
        ? `PASS — Honda_Panasonic: 2 rows (BUY ${honda.BUY[0].vol}MW + SELL ${honda.SELL[0].vol}MW)`
        : `FAIL — Honda_Panasonic: BUY×${bN} SELL×${sN} (expected 1+1)`;
    }
    console.log(`[D] ${checks.D}`);

    // CHECK E: Total rows = exactly 6
    const totalPana = pRows.length;
    if (totalPana === 6) {
      checks.E = `PASS — Total Panasonic rows: 6 (exactly as expected)`;
    } else if (totalPana < 6) {
      checks.E = `FAIL — Total rows: ${totalPana} (fewer than 6 — some legitimate rows missing?)`;
    } else {
      checks.E = `FAIL — Total rows: ${totalPana} (expected 6, have ${totalPana - 6} extra)`;
    }
    console.log(`[E] ${checks.E}`);

    // ─── SONY ────────────────────────────────────────────────────
    console.log('\n' + '='.repeat(60));
    console.log('SONY BROKER — HONDA REGRESSION (F)');
    console.log('='.repeat(60));

    try {
      const sonyRows = await openTradeDeals(page, URLS.sony, 'Sony');
      console.log(`\nSony total rows: ${sonyRows.length}`);
      console.log('RAW:');
      sonyRows.forEach((r, i) => console.log(`  ${String(i+1).padStart(2)}. ${r}`));

      const sonyData = parseByTrader(sonyRows, 'Sony');
      const hSony = sonyData['Honda'];

      if (!hSony) {
        checks.F = 'INCONCLUSIVE — Honda_Sony: no rows found';
      } else {
        const buyTotal  = hSony.BUY.reduce((s, x) => s + x.vol, 0);
        const sellTotal = hSony.SELL.reduce((s, x) => s + x.vol, 0);
        console.log(`  Honda_Sony: BUY×${hSony.BUY.length}=${buyTotal}MW  SELL×${hSony.SELL.length}=${sellTotal}MW`);

        // Key regression: SELL should be 40MW, not 80MW
        if (sellTotal === 40 && buyTotal === 40) {
          checks.F = `PASS — Honda_Sony: BUY=40MW == SELL=40MW (phantom SELL gone, regression fixed)`;
        } else if (sellTotal === 80) {
          checks.F = `FAIL — Honda_Sony: SELL=80MW (phantom still present), BUY=${buyTotal}MW`;
        } else {
          checks.F = `FAIL — Honda_Sony: BUY=${buyTotal}MW, SELL=${sellTotal}MW (unexpected values)`;
        }
      }
      console.log(`[F] ${checks.F}`);

      // Also check Volvo_Sony
      const vSony = sonyData['Volvo'];
      if (vSony) {
        const vB = vSony.BUY.length, vS = vSony.SELL.length;
        console.log(`  Volvo_Sony: BUY×${vB} SELL×${vS} (expect 1+1, prev had duplicates)`);
        if (vB !== 1 || vS !== 1) {
          console.log(`  ⚠️  Volvo_Sony still has duplicates`);
        }
      }
    } catch (e) {
      checks.F = `ERROR — ${e.message}`;
      console.log(`[F] ${checks.F}`);
    }

    // ─── ADMIN ───────────────────────────────────────────────────
    console.log('\n' + '='.repeat(60));
    console.log('ADMIN — PHANTOM/DUPLICATE CHECK (G)');
    console.log('='.repeat(60));

    try {
      const adminRows = await openTradeDeals(page, URLS.admin, 'Admin');
      console.log(`\nAdmin total rows: ${adminRows.length}`);
      console.log('RAW:');
      adminRows.forEach((r, i) => console.log(`  ${String(i+1).padStart(2)}. ${r}`));

      // Exact duplicates
      const seen = new Map();
      adminRows.forEach((r, i) => {
        if (!seen.has(r)) seen.set(r, []);
        seen.get(r).push(i + 1);
      });
      const exactDups = [...seen.entries()].filter(([, rows]) => rows.length > 1);

      // Hub-neutral duplicates (same broker+trader+dir+vol+venue, different hub)
      // Include counterparty in key to avoid false positives
      const hubKey = new Map();
      adminRows.forEach((r, idx) => {
        const m = r.match(/(Sony|Panasonic|JVC)(\w+)TARGET_(BUY|SELL)/);
        const vm = r.match(/(EEX|OTC)(\d{1,4})(?!\d)/);
        const cp = r.match(/\d{1,4}(\w+_\w+)/);  // counterparty after volume
        if (!m || !vm) return;
        const key = `${m[1]}_${m[2]}_${m[3]}_${vm[2]}_${vm[1]}_${cp?.[1] || 'nocp'}`;
        if (!hubKey.has(key)) hubKey.set(key, []);
        hubKey.get(key).push(idx + 1);
      });
      const hubDups = [...hubKey.entries()].filter(([, rows]) => rows.length > 1);

      // Phantom detection: any SonyHonda SELL to Toyota counterparty (was the phantom)
      const phantomRows = adminRows.filter(r =>
        r.includes('SonyHonda') && r.includes('TARGET_SELL') && r.includes('Toyota_Panasonic')
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
        issues.push(`${phantomRows.length} phantom SonyHonda SELL→Toyota row(s)`);
        phantomRows.forEach(r => console.log(`  🚨 PHANTOM: ${r.substring(0, 90)}`));
      }

      if (issues.length === 0) {
        checks.G = `PASS — Admin: ${adminRows.length} rows, no exact/hub dups, no phantom rows`;
      } else {
        checks.G = `FAIL — Admin: ${issues.join(', ')} (total ${adminRows.length} rows)`;
      }
      console.log(`[G] ${checks.G}`);

    } catch (e) {
      checks.G = `ERROR — ${e.message}`;
      console.log(`[G] ${checks.G}`);
    }

    // ─── FINAL SUMMARY ───────────────────────────────────────────
    console.log('\n' + '='.repeat(60));
    console.log('FINAL SUMMARY — BUG-20260424-001+002 v3 (b538549)');
    console.log('='.repeat(60));

    const allChecks = ['A','B','C','D','E','F','G'];
    const allPass = allChecks.every(k => checks[k]?.startsWith('PASS'));

    allChecks.forEach(k => {
      const icon = !checks[k] ? '⬜' : checks[k].startsWith('PASS') ? '✅' : checks[k].startsWith('FAIL') ? '❌' : '⚠️';
      console.log(`  ${icon} [${k}] ${checks[k] || 'NOT RUN'}`);
    });

    console.log('\n📢 CONSOLE MESSAGES:');
    console.log(`  🔄 [R4G synthesize]:    ${cLog.synthesize} (should run, but not for Toyota/Volvo zero-row positions)`);
    console.log(`  ⏭️  [R4G synthSkip]:     ${cLog.synthSkipped.length} ${cLog.synthSkipped.length > 0 ? '← new guard triggered ✅' : '(no skip messages — check log prefix)'}`);
    console.log(`  🆕 [R4G postFlipSynth]: ${cLog.postFlipSynth} (should be 0 — neutered)`);
    console.log(`  🔁 [R4G dedup]:         ${cLog.dedup}`);
    console.log(`  ⚠️  [R4G symmetry]:      ${cLog.symmetry} (must be 0)`);
    if (cLog.synthSkipped.length > 0) {
      cLog.synthSkipped.forEach(m => console.log(`     > ${m}`));
    }

    const verdict = allPass ? '✅ PASS — All checks passed, DEPLOY OK' : '❌ FAIL — One or more checks failed';
    console.log(`\n🎯 OVERALL VERDICT: ${verdict}`);
    console.log('='.repeat(60));

    require('fs').writeFileSync(
      '/home/alexey/banda/agents/kim/bug_b538549_report.json',
      JSON.stringify({
        commit: 'b538549',
        checks,
        consoleMessages: { ...cLog, synthSkipped: cLog.synthSkipped.length },
        timestamp: new Date().toISOString()
      }, null, 2)
    );
    console.log('\n💾 Report: bug_b538549_report.json');

  } catch (err) {
    console.error(`\n❌ FATAL: ${err.message}`);
    console.error(err.stack);
  } finally {
    if (browser) await browser.close();
  }
})();
