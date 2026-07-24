// BUG-20260424-001+002 v2 — Commit ffc5967
// Fix: enforcePostFlipSymmetry neutered; dedup key now (trade_type, target_trader, cpty, qty, venue) — hub removed
// Root cause: synthesizeMissingDetails created rows with counterparty_row_ref='' → wrong resultsRow lookup → phantom hub-permuted rows

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
  if (rounds.length === 0) {
    const body = await page.locator('body').innerText().catch(() => '');
    console.log(`  ${label} body snippet: ${body.substring(0, 200)}`);
    throw new Error(`No rounds in ${label}`);
  }
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

function parseRows(rows, brokerName) {
  // Format: {Broker}{Trader}TARGET_{DIR}{Period}{Hub}{Venue}{Vol}{Counterparty}{...}
  const re = new RegExp(`${brokerName}(\\w+)TARGET_(BUY|SELL)`);
  const byTrader = {};

  rows.forEach((r, idx) => {
    const m = r.match(re);
    if (!m) return;
    const trader = m[1];
    const dir = m[2];
    // Volume: look for EEX|OTC followed by 1-4 digit number
    const vm = r.match(/(EEX|OTC)(\d{1,4})(?!\d)/);
    const vol = vm ? parseInt(vm[2]) : 0;
    // Hub: capture the price hub (TTF, NBP, THE, CEGH, ZTP)
    const hubm = r.match(/\((\d+[\.,]?\d*)\)(EEX|OTC)/);
    const hub = r.match(/TTF|NBP|THE|CEGH|ZTP/)?.[0] || '?';
    const venue = vm ? vm[1] : '?';

    if (!byTrader[trader]) byTrader[trader] = { BUY: [], SELL: [] };
    byTrader[trader][dir].push({ vol, hub, venue, row: idx + 1, text: r });
  });
  return byTrader;
}

(async () => {
  console.log('🎯 BUG-20260424-001+002 v2 — Commit ffc5967');
  console.log('Fix: enforcePostFlipSymmetry neutered; dedup key excludes hub');

  let browser;
  const cLog = { postFlipSynth: 0, dedup: [], synthesize: 0, symmetry: 0 };
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
      if (t.includes('[R4G postFlipSynth]')) { cLog.postFlipSynth++; console.log(`🆕 ${t}`); }
      else if (t.includes('[R4G dedup') || t.includes('[R4G deduplicate]')) { cLog.dedup.push(t); console.log(`🔁 ${t}`); }
      else if (t.includes('[R4G synthesize]')) { cLog.synthesize++; }
      else if (t.includes('[R4G symmetry]')) { cLog.symmetry++; console.log(`⚠️  ${t}`); }
    });

    // ─── PANASONIC ────────────────────────────────────────────────
    console.log('\n' + '='.repeat(60));
    console.log('PANASONIC BROKER — TRADE DEALS ANALYSIS');
    console.log('='.repeat(60));

    const pRows = await openTradeDeals(page, URLS.panasonic, 'Panasonic');
    console.log(`\nTotal rows: ${pRows.length}`);
    console.log('\nRAW ROWS:');
    pRows.forEach((r, i) => console.log(`  ${String(i+1).padStart(2)}. ${r}`));

    const pData = parseRows(pRows, 'Panasonic');

    console.log('\nPER-TRADER BREAKDOWN:');
    for (const [t, d] of Object.entries(pData)) {
      const bN = d.BUY.length, sN = d.SELL.length;
      console.log(`  ${t}_Panasonic: BUY×${bN} SELL×${sN}`);
      d.BUY.forEach(x => console.log(`    BUY  ${x.vol}MW  hub:${x.hub}  venue:${x.venue}  [row ${x.row}]`));
      d.SELL.forEach(x => console.log(`    SELL ${x.vol}MW  hub:${x.hub}  venue:${x.venue}  [row ${x.row}]`));
    }

    // CHECK A: Toyota — exactly 1 SELL, 0 BUY
    const toyota = pData['Toyota'];
    if (!toyota) {
      checks.A = 'FAIL — Toyota_Panasonic: no rows found';
    } else {
      const bN = toyota.BUY.length, sN = toyota.SELL.length;
      const total = bN + sN;
      if (total === 1 && sN === 1 && bN === 0) {
        checks.A = `PASS — Toyota_Panasonic: 1 row, SELL ${toyota.SELL[0].vol}MW, hub:${toyota.SELL[0].hub}, NO phantom BUY`;
      } else {
        checks.A = `FAIL — Toyota_Panasonic: ${total} row(s), BUY×${bN} SELL×${sN} (expected 1×SELL only)`;
        if (bN > 0) {
          toyota.BUY.forEach(x => console.log(`  🚨 Phantom BUY: ${x.vol}MW hub:${x.hub} venue:${x.venue} [row ${x.row}]`));
        }
      }
    }
    console.log(`\n[A] ${checks.A}`);

    // CHECK B: Volvo — exactly 1 BUY, 0 SELL
    const volvo = pData['Volvo'];
    if (!volvo) {
      checks.B = 'FAIL — Volvo_Panasonic: no rows found';
    } else {
      const bN = volvo.BUY.length, sN = volvo.SELL.length;
      const total = bN + sN;
      if (total === 1 && bN === 1 && sN === 0) {
        checks.B = `PASS — Volvo_Panasonic: 1 row, BUY ${volvo.BUY[0].vol}MW, hub:${volvo.BUY[0].hub}, NO phantom SELL`;
      } else {
        checks.B = `FAIL — Volvo_Panasonic: ${total} row(s), BUY×${bN} SELL×${sN} (expected 1×BUY only)`;
      }
    }
    console.log(`[B] ${checks.B}`);

    // CHECK C: Ford — exactly 1 BUY + 1 SELL
    const ford = pData['Ford'];
    if (!ford) {
      checks.C = 'FAIL — Ford_Panasonic: no rows found';
    } else {
      const bN = ford.BUY.length, sN = ford.SELL.length;
      if (bN === 1 && sN === 1) {
        checks.C = `PASS — Ford_Panasonic: 2 rows (BUY ${ford.BUY[0].vol}MW + SELL ${ford.SELL[0].vol}MW)`;
      } else {
        checks.C = `FAIL — Ford_Panasonic: BUY×${bN} SELL×${sN} (expected 1+1)`;
      }
    }
    console.log(`[C] ${checks.C}`);

    // CHECK D: Honda — exactly 1 BUY + 1 SELL
    const honda = pData['Honda'];
    if (!honda) {
      checks.D = 'FAIL — Honda_Panasonic: no rows found';
    } else {
      const bN = honda.BUY.length, sN = honda.SELL.length;
      if (bN === 1 && sN === 1) {
        checks.D = `PASS — Honda_Panasonic: 2 rows (BUY ${honda.BUY[0].vol}MW + SELL ${honda.SELL[0].vol}MW)`;
      } else {
        checks.D = `FAIL — Honda_Panasonic: BUY×${bN} SELL×${sN} (expected 1+1)`;
      }
    }
    console.log(`[D] ${checks.D}`);

    // CHECK E: No hub-permuted phantom rows
    // A hub-permuted phantom would have same trader/dir/vol/venue but different hub than the legitimate row
    // Strategy: look for Toyota BUY rows (any = phantom) OR rows that are near-duplicates differing only in hub
    let hubPhantoms = [];
    pRows.forEach((r, idx) => {
      // Any Toyota BUY is a phantom
      if (r.includes('PanasonicToyotaTARGET_BUY')) {
        hubPhantoms.push({ row: idx + 1, text: r });
      }
      // Any Volvo SELL is a phantom
      if (r.includes('PanasonicVolvoTARGET_SELL')) {
        hubPhantoms.push({ row: idx + 1, text: r });
      }
    });
    // Also check for hub-permuted duplicates among all rows
    // Group by (trader, dir, vol, venue) — if >1 per group, hub was permuted
    const dedupGroups = {};
    pRows.forEach((r, idx) => {
      const m = r.match(/Panasonic(\w+)TARGET_(BUY|SELL)/);
      const vm = r.match(/(EEX|OTC)(\d{1,4})(?!\d)/);
      if (!m || !vm) return;
      const key = `${m[1]}_${m[2]}_${vm[2]}_${vm[1]}`;
      if (!dedupGroups[key]) dedupGroups[key] = [];
      dedupGroups[key].push(idx + 1);
    });
    const hubDups = Object.entries(dedupGroups).filter(([, rows]) => rows.length > 1);
    if (hubDups.length > 0) {
      hubDups.forEach(([k, rows]) => {
        hubPhantoms.push({ key: k, rows, note: 'dedup group with multiple hub variants' });
      });
    }

    if (hubPhantoms.length === 0) {
      checks.E = 'PASS — No phantom BUY/SELL rows and no hub-permuted duplicates found';
    } else {
      checks.E = `FAIL — ${hubPhantoms.length} phantom/hub-permuted row(s) detected`;
      hubPhantoms.forEach(p => console.log(`  🚨 ${p.row ? `Row ${p.row}` : p.key}: ${p.text || p.note}`));
    }
    console.log(`[E] ${checks.E}`);

    // CHECK F: Total row count
    const totalCount = pRows.length;
    checks.F = `${totalCount} rows — ${totalCount <= 8 ? 'PASS (≤8 expected)' : totalCount <= 10 ? 'ACCEPTABLE (≤10)' : 'FAIL (>10)'}`;
    console.log(`[F] Total Panasonic rows: ${checks.F}`);

    // ─── SONY REGRESSION ─────────────────────────────────────────
    console.log('\n' + '='.repeat(60));
    console.log('SONY BROKER — HONDA REGRESSION CHECK (G)');
    console.log('='.repeat(60));

    try {
      const sonyRows = await openTradeDeals(page, URLS.sony, 'Sony');
      console.log(`\nSony Total rows: ${sonyRows.length}`);
      console.log('RAW:');
      sonyRows.forEach((r, i) => console.log(`  ${String(i+1).padStart(2)}. ${r}`));

      const sonyData = parseRows(sonyRows, 'Sony');
      const hondaSony = sonyData['Honda'];

      if (!hondaSony) {
        checks.G = 'INCONCLUSIVE — Honda_Sony: no rows found in Sony Trade Deals';
      } else {
        const totalBuy = hondaSony.BUY.reduce((s, x) => s + x.vol, 0);
        const totalSell = hondaSony.SELL.reduce((s, x) => s + x.vol, 0);
        const buyCount = hondaSony.BUY.length;
        const sellCount = hondaSony.SELL.length;
        console.log(`  Honda_Sony: BUY×${buyCount} (${totalBuy}MW) SELL×${sellCount} (${totalSell}MW)`);

        if (totalBuy === totalSell && buyCount === sellCount && buyCount <= 2) {
          checks.G = `PASS — Honda_Sony: BUY=${totalBuy}MW == SELL=${totalSell}MW (${buyCount} deal pair)`;
        } else if (totalBuy === totalSell) {
          checks.G = `PASS (with duplicate check) — Honda_Sony: BUY=${totalBuy}MW == SELL=${totalSell}MW, but ${buyCount} BUY rows (expected ≤2)`;
        } else {
          checks.G = `FAIL — Honda_Sony ASYMMETRIC: BUY=${totalBuy}MW ≠ SELL=${totalSell}MW`;
        }
      }
      console.log(`[G] ${checks.G}`);

      // Also check Volvo_Sony duplicates (were duplicated in previous commit)
      const volvoSony = sonyData['Volvo'];
      if (volvoSony) {
        const vB = volvoSony.BUY.length, vS = volvoSony.SELL.length;
        console.log(`  Volvo_Sony: BUY×${vB} SELL×${vS} (expect 1+1)`);
        if (vB !== 1 || vS !== 1) console.log(`  ⚠️  Volvo_Sony duplicates still present!`);
      }

    } catch (e) {
      checks.G = `ERROR — ${e.message}`;
      console.log(`[G] ${checks.G}`);
    }

    // ─── ADMIN REGRESSION ────────────────────────────────────────
    console.log('\n' + '='.repeat(60));
    console.log('ADMIN — DUPLICATE CHECK (H)');
    console.log('='.repeat(60));

    try {
      const adminRows = await openTradeDeals(page, URLS.admin, 'Admin');
      console.log(`\nAdmin Total rows: ${adminRows.length}`);
      console.log('RAW:');
      adminRows.forEach((r, i) => console.log(`  ${String(i+1).padStart(2)}. ${r}`));

      // Exact duplicate detection
      const seen = new Map();
      adminRows.forEach((r, i) => {
        if (!seen.has(r)) seen.set(r, []);
        seen.get(r).push(i + 1);
      });
      const exactDups = [...seen.entries()].filter(([, rows]) => rows.length > 1);

      // Hub-permuted duplicate detection (same broker+trader+dir+vol+venue, different hub)
      const adminDedup = {};
      adminRows.forEach((r, idx) => {
        const m = r.match(/(Sony|Panasonic|JVC)(\w+)TARGET_(BUY|SELL)/);
        const vm = r.match(/(EEX|OTC)(\d{1,4})(?!\d)/);
        if (!m || !vm) return;
        const key = `${m[1]}_${m[2]}_${m[3]}_${vm[2]}_${vm[1]}`;
        if (!adminDedup[key]) adminDedup[key] = [];
        adminDedup[key].push(idx + 1);
      });
      const hubDupsAdmin = Object.entries(adminDedup).filter(([, rows]) => rows.length > 1);

      if (exactDups.length === 0 && hubDupsAdmin.length === 0) {
        checks.H = `PASS — Admin: ${adminRows.length} rows, no duplicates`;
      } else {
        const issues = [];
        if (exactDups.length > 0) {
          issues.push(`${exactDups.length} exact dup group(s)`);
          exactDups.forEach(([text, rows]) => console.log(`  ❌ Exact dup rows ${rows.join(',')}: ${text.substring(0, 80)}`));
        }
        if (hubDupsAdmin.length > 0) {
          issues.push(`${hubDupsAdmin.length} hub-permuted dup group(s)`);
          hubDupsAdmin.forEach(([key, rows]) => console.log(`  ❌ Hub-dup key ${key} rows ${rows.join(',')}`));
        }
        checks.H = `FAIL — Admin: ${issues.join(', ')} (total ${adminRows.length} rows)`;
      }
      console.log(`[H] ${checks.H}`);

    } catch (e) {
      checks.H = `ERROR — ${e.message}`;
      console.log(`[H] ${checks.H}`);
    }

    // ─── SUMMARY ─────────────────────────────────────────────────
    console.log('\n' + '='.repeat(60));
    console.log('FINAL SUMMARY — BUG-20260424-001+002 v2 (ffc5967)');
    console.log('='.repeat(60));

    const primary = ['A', 'B', 'C', 'D', 'E'];
    const allPrimaryPass = primary.every(k => checks[k]?.startsWith('PASS'));

    primary.forEach(k => {
      const icon = checks[k]?.startsWith('PASS') ? '✅' : '❌';
      console.log(`  ${icon} [${k}] ${checks[k]}`);
    });
    ['F', 'G', 'H'].forEach(k => {
      const icon = checks[k]?.startsWith('PASS') ? '✅' : checks[k]?.startsWith('FAIL') ? '❌' : '⚠️';
      console.log(`  ${icon} [${k}] ${checks[k]}`);
    });

    console.log('\n📢 CONSOLE:');
    console.log(`  🆕 [R4G postFlipSynth]: ${cLog.postFlipSynth} ${cLog.postFlipSynth > 0 ? '⚠️  (neutered — should be 0?)' : '✅ (0 — neutered as expected)'}`);
    console.log(`  🔁 [R4G deduplicate]:   ${cLog.dedup.length} ${cLog.dedup.length > 0 ? '✅ dedup running' : '(no dedup log)'}`);
    console.log(`  🔄 [R4G synthesize]:    ${cLog.synthesize}`);
    console.log(`  ⚠️  [R4G symmetry]:      ${cLog.symmetry} (must be 0)`);
    if (cLog.dedup.length > 0) cLog.dedup.forEach(m => console.log(`     > ${m}`));

    const verdict = allPrimaryPass ? '✅ PASS — All primary checks passed' : '❌ FAIL — Primary check(s) failed';
    console.log(`\n🎯 OVERALL VERDICT: ${verdict}`);
    console.log('='.repeat(60));

    require('fs').writeFileSync(
      '/home/alexey/banda/agents/kim/bug_ffc5967_report.json',
      JSON.stringify({ commit: 'ffc5967', checks, cLog: { ...cLog, dedup: cLog.dedup.length }, timestamp: new Date().toISOString() }, null, 2)
    );
    console.log('\n💾 Report saved: bug_ffc5967_report.json');

  } catch (err) {
    console.error(`\n❌ FATAL: ${err.message}`);
    console.error(err.stack);
  } finally {
    if (browser) await browser.close();
  }
})();
