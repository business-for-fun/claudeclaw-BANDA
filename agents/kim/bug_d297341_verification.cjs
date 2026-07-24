// BUG-20260424-001+002 Verification — Commit d297341
// BUG-001: Duplicate rows in Trade Deals — fixed by deduplicateTradeDeals()
// BUG-002: Phantom opposite-side rows for UNSOLVED traders — fixed by UNSOLVED guard in enforcePostFlipSymmetry

const { chromium } = require('playwright');

const URLS = {
  admin:    'https://dev.r4g.business-for-fun.com/',
  panasonic:'https://dev.r4g.business-for-fun.com/?broker=Panasonic&share=lzoknmqo',
  sony:     'https://dev.r4g.business-for-fun.com/?broker=Sony&share=gei29u4l',
  jvc:      'https://dev.r4g.business-for-fun.com/?broker=JVC&share=wgdqmspa'
};

const log = (msg) => console.log(msg);
const sep = () => console.log('-'.repeat(60));

async function openBrokerTradeDeals(page, url, label) {
  log(`\n📍 Opening ${label}: ${url}`);
  await page.goto(url, { timeout: 60000, waitUntil: 'load' });
  await page.waitForTimeout(5000);

  // Find Log tab or Netting Results fallback
  let entryTab = page.locator('text=Log').first();
  if (!await entryTab.isVisible({ timeout: 2000 }).catch(() => false)) {
    entryTab = page.locator('text=Netting Results').first();
  }
  if (!await entryTab.isVisible({ timeout: 3000 }).catch(() => false)) {
    throw new Error(`No Log or Netting Results tab found for ${label}`);
  }
  await entryTab.click();
  await page.waitForTimeout(2000);
  log(`✅ ${label}: opened entry tab`);

  // Click latest round row (first tr in table)
  const roundRows = await page.locator('table tbody tr').all();
  if (roundRows.length === 0) throw new Error(`No rounds found in ${label} log`);
  log(`  📋 ${roundRows.length} round(s) found — clicking latest`);
  await roundRows[0].click();
  await page.waitForTimeout(3000);

  // Open Trade Deals sub-tab
  const tradeDealsSub = page.locator('text=Trade Deals').first();
  if (!await tradeDealsSub.isVisible({ timeout: 5000 }).catch(() => false)) {
    throw new Error(`Trade Deals sub-tab not found for ${label} after drill-in`);
  }
  await tradeDealsSub.click();
  await page.waitForTimeout(2000);
  log(`✅ ${label}: opened Trade Deals sub-tab`);

  // Collect all rows
  const rows = await page.locator('table tbody tr').all();
  const rowTexts = [];
  for (const row of rows) {
    try {
      const text = await row.textContent();
      if (text && text.trim()) rowTexts.push(text.trim());
    } catch (e) {}
  }
  log(`  📊 ${label} Trade Deals: ${rowTexts.length} rows total`);
  return rowTexts;
}

function parseTradeRow(rowText) {
  const traderMatch = rowText.match(/(\w+)(\w+)TARGET_(BUY|SELL)/);
  // Format: PanasonicFordTARGET_SELL or SonyHondaTARGET_BUY
  const brokerTraderMatch = rowText.match(/Panasonic(\w+)TARGET_(BUY|SELL)|Sony(\w+)TARGET_(BUY|SELL)|JVC(\w+)TARGET_(BUY|SELL)/);

  let trader = null, direction = null;

  if (brokerTraderMatch) {
    if (brokerTraderMatch[1]) { trader = `${brokerTraderMatch[1]}_Panasonic`; direction = brokerTraderMatch[2]; }
    else if (brokerTraderMatch[3]) { trader = `${brokerTraderMatch[3]}_Sony`; direction = brokerTraderMatch[4]; }
    else if (brokerTraderMatch[5]) { trader = `${brokerTraderMatch[5]}_JVC`; direction = brokerTraderMatch[6]; }
  }

  // Volume: look for EEX or OTC followed by bare number
  const volumeMatch = rowText.match(/(EEX|OTC)(\d{1,4})(?!\d)/);
  const volume = volumeMatch ? parseInt(volumeMatch[2]) : null;

  // Counterparty: last _BrokerName segment
  const cpMatch = rowText.match(/(?:EEX|OTC)\d+(\w+_\w+)/);
  const counterparty = cpMatch ? cpMatch[1] : null;

  return { trader, direction, volume, counterparty, rawText: rowText };
}

(async () => {
  log('🎯 BUG-20260424-001+002 VERIFICATION — Commit d297341');
  log('BUG-001: deduplicateTradeDeals() | BUG-002: UNSOLVED guard in enforcePostFlipSymmetry');

  let browser, context, page;
  const checks = { A: null, B: null, C: null, D: null, E: null, F: null, G: null, H: null };
  const consoleLog = { postFlipSynth: 0, deduplicate: 0, synthesize: 0, symmetry: 0 };

  try {
    browser = await chromium.launch({ headless: true });
    context = await browser.newContext({
      viewport: { width: 1440, height: 900 },
      httpCredentials: {
        username: process.env.R4G_DEV_USER,
        password: process.env.R4G_DEV_PASS
      }
    });

    page = await context.newPage();
    page.on('console', msg => {
      const t = msg.text();
      if (t.includes('[R4G postFlipSynth]')) { consoleLog.postFlipSynth++; log(`🆕 ${t}`); }
      else if (t.includes('[R4G deduplicate]') || t.includes('[R4G dedup')) { consoleLog.deduplicate++; log(`🔁 ${t}`); }
      else if (t.includes('[R4G synthesize]')) { consoleLog.synthesize++; }
      else if (t.includes('[R4G symmetry]')) { consoleLog.symmetry++; log(`⚠️  ${t}`); }
    });

    // ============================================================
    // STEP 1: PANASONIC BROKER TRADE DEALS
    // ============================================================
    log('\n' + '='.repeat(60));
    log('STEP 1: PANASONIC BROKER TRADE DEALS ANALYSIS');
    log('='.repeat(60));

    const panasonicRows = await openBrokerTradeDeals(page, URLS.panasonic, 'Panasonic');

    // Parse all rows
    const parsed = panasonicRows.map(r => parseTradeRow(r));
    log('\n📋 All rows parsed:');
    parsed.forEach((p, i) => {
      log(`  ${i+1}. ${p.trader || '?'} | ${p.direction || '?'} | ${p.volume || '?'} MW | cp: ${p.counterparty || '?'}`);
    });

    // Build per-trader summary
    const traderSummary = {};
    parsed.forEach(p => {
      if (!p.trader) return;
      if (!traderSummary[p.trader]) traderSummary[p.trader] = { rows: [], BUY: 0, SELL: 0 };
      traderSummary[p.trader].rows.push(p);
      if (p.direction) traderSummary[p.trader][p.direction] += (p.volume || 0);
    });

    sep();
    log('INDIVIDUAL CHECKS:');
    sep();

    // CHECK A: Toyota_Panasonic — 1 row, TARGET_SELL, no phantom BUY
    const toyota = traderSummary['Toyota_Panasonic'];
    if (!toyota) {
      checks.A = 'FAIL — no Toyota_Panasonic rows found';
    } else {
      const toyotaCount = toyota.rows.length;
      const hasSell = toyota.rows.some(r => r.direction === 'SELL');
      const hasBuy  = toyota.rows.some(r => r.direction === 'BUY');
      if (toyotaCount === 1 && hasSell && !hasBuy) {
        checks.A = `PASS — Toyota_Panasonic: 1 row, TARGET_SELL (${toyota.SELL}MW), NO phantom BUY`;
      } else {
        checks.A = `FAIL — Toyota_Panasonic: ${toyotaCount} row(s), BUY=${toyota.BUY}, SELL=${toyota.SELL} (expected 1×SELL only)`;
      }
    }
    log(`CHECK A: ${checks.A}`);

    // CHECK B: Volvo_Panasonic — 1 row, TARGET_BUY, no phantom SELL
    const volvo = traderSummary['Volvo_Panasonic'];
    if (!volvo) {
      checks.B = 'FAIL — no Volvo_Panasonic rows found';
    } else {
      const volvoCount = volvo.rows.length;
      const hasBuy  = volvo.rows.some(r => r.direction === 'BUY');
      const hasSell = volvo.rows.some(r => r.direction === 'SELL');
      if (volvoCount === 1 && hasBuy && !hasSell) {
        checks.B = `PASS — Volvo_Panasonic: 1 row, TARGET_BUY (${volvo.BUY}MW), NO phantom SELL`;
      } else {
        checks.B = `FAIL — Volvo_Panasonic: ${volvoCount} row(s), BUY=${volvo.BUY}, SELL=${volvo.SELL} (expected 1×BUY only)`;
      }
    }
    log(`CHECK B: ${checks.B}`);

    // CHECK C: Ford_Panasonic — exactly 2 rows (1 BUY + 1 SELL)
    const ford = traderSummary['Ford_Panasonic'];
    if (!ford) {
      checks.C = 'FAIL — no Ford_Panasonic rows found';
    } else {
      const fordCount = ford.rows.length;
      const buyCount  = ford.rows.filter(r => r.direction === 'BUY').length;
      const sellCount = ford.rows.filter(r => r.direction === 'SELL').length;
      if (fordCount === 2 && buyCount === 1 && sellCount === 1) {
        checks.C = `PASS — Ford_Panasonic: 2 rows (1×BUY ${ford.BUY}MW + 1×SELL ${ford.SELL}MW), no duplicates`;
      } else {
        checks.C = `FAIL — Ford_Panasonic: ${fordCount} row(s), BUY×${buyCount} SELL×${sellCount} (expected 2 total: 1+1)`;
      }
    }
    log(`CHECK C: ${checks.C}`);

    // CHECK D: Honda_Panasonic — exactly 2 rows (1 BUY + 1 SELL)
    const honda = traderSummary['Honda_Panasonic'];
    if (!honda) {
      checks.D = 'FAIL — no Honda_Panasonic rows found';
    } else {
      const hondaCount = honda.rows.length;
      const buyCount   = honda.rows.filter(r => r.direction === 'BUY').length;
      const sellCount  = honda.rows.filter(r => r.direction === 'SELL').length;
      if (hondaCount === 2 && buyCount === 1 && sellCount === 1) {
        checks.D = `PASS — Honda_Panasonic: 2 rows (1×BUY ${honda.BUY}MW + 1×SELL ${honda.SELL}MW), no duplicates`;
      } else {
        checks.D = `FAIL — Honda_Panasonic: ${hondaCount} row(s), BUY×${buyCount} SELL×${sellCount} (expected 2 total: 1+1)`;
      }
    }
    log(`CHECK D: ${checks.D}`);

    // CHECK E: Total row count
    const totalPanasonicRows = panasonicRows.length;
    if (totalPanasonicRows >= 6 && totalPanasonicRows <= 10) {
      checks.E = `PASS — Total Panasonic Trade Deals rows: ${totalPanasonicRows} (within expected range 6-10)`;
    } else if (totalPanasonicRows > 10) {
      checks.E = `FAIL — Total rows: ${totalPanasonicRows} (too many — duplicates still present?)`;
    } else {
      checks.E = `INCONCLUSIVE — Total rows: ${totalPanasonicRows} (fewer than expected minimum 6)`;
    }
    log(`CHECK E: ${checks.E}`);

    // CHECK H: Volume symmetry
    log('\nCHECK H: PANASONIC VOLUME SYMMETRY:');
    let allSymmetric = true;
    const hSymmetryDetails = [];
    for (const [trader, data] of Object.entries(traderSummary)) {
      const sym = data.BUY === data.SELL ? '✅' : '❌';
      const detail = `${sym} ${trader}: BUY=${data.BUY} SELL=${data.SELL}`;
      hSymmetryDetails.push(detail);
      log(`  ${detail}`);
      if (data.BUY !== data.SELL) allSymmetric = false;
    }

    // Toyota and Volvo expected to be non-zero one-side only (UNSOLVED = they have one side)
    // Symmetry check: for UNSOLVED traders, BUY != SELL is expected, but they shouldn't have phantom other side
    // So actual symmetry verdict should focus on SOLVED traders (Ford, Honda)
    const fordSymm  = ford  ? ford.BUY === ford.SELL   : null;
    const hondaSymm = honda ? honda.BUY === honda.SELL  : null;
    const solvedSymmetric = fordSymm && hondaSymm;

    checks.H = solvedSymmetric
      ? `PASS — SOLVED traders symmetric: Ford(${ford.BUY}/${ford.SELL}), Honda(${honda.BUY}/${honda.SELL}). UNSOLVED traders Toyota/Volvo have 1-sided rows (expected).`
      : `FAIL — Volume asymmetry in SOLVED traders: ${JSON.stringify({ford: fordSymm, honda: hondaSymm})}`;
    log(`CHECK H: ${checks.H}`);

    // ============================================================
    // STEP 2: ADMIN REGRESSION — no duplicate rows
    // ============================================================
    log('\n' + '='.repeat(60));
    log('STEP 2: ADMIN REGRESSION CHECK (F)');
    log('='.repeat(60));

    try {
      const adminRows = await openBrokerTradeDeals(page, URLS.admin, 'Admin');

      // Look for duplicates: same trader+direction+volume appearing more than once
      const seen = new Map();
      let duplicates = 0;
      adminRows.forEach(r => {
        const key = r.substring(0, 60); // Use first 60 chars as dedup key
        seen.set(key, (seen.get(key) || 0) + 1);
        if (seen.get(key) > 1) duplicates++;
      });

      checks.F = duplicates === 0
        ? `PASS — Admin Trade Deals: ${adminRows.length} rows, no duplicates detected`
        : `FAIL — Admin Trade Deals: ${duplicates} apparent duplicate row(s) found (total: ${adminRows.length})`;
      log(`CHECK F: ${checks.F}`);
      log(`  Admin row count: ${adminRows.length}`);
    } catch (e) {
      checks.F = `ERROR — ${e.message}`;
      log(`CHECK F: ${checks.F}`);
    }

    // ============================================================
    // STEP 3: SONY REGRESSION — Honda BUY==SELL
    // ============================================================
    log('\n' + '='.repeat(60));
    log('STEP 3: SONY REGRESSION CHECK (G) — Honda BUY==SELL');
    log('='.repeat(60));

    try {
      const sonyRows = await openBrokerTradeDeals(page, URLS.sony, 'Sony');

      let hondaSonyBuy = 0, hondaSonySell = 0;
      sonyRows.forEach(r => {
        const isHonda = r.includes('Honda');
        const dirMatch = r.match(/TARGET_(BUY|SELL)/);
        const volMatch = r.match(/(EEX|OTC)(\d{1,4})(?!\d)/);
        if (isHonda && dirMatch && volMatch) {
          const vol = parseInt(volMatch[2]);
          if (dirMatch[1] === 'BUY') hondaSonyBuy += vol;
          else hondaSonySell += vol;
        }
      });

      log(`  Sony Honda_Sony: BUY=${hondaSonyBuy} MW, SELL=${hondaSonySell} MW`);
      checks.G = hondaSonyBuy === hondaSonySell
        ? `PASS — Honda_Sony symmetric: BUY=${hondaSonyBuy}MW == SELL=${hondaSonySell}MW`
        : `FAIL — Honda_Sony ASYMMETRIC: BUY=${hondaSonyBuy} != SELL=${hondaSonySell}`;
      log(`CHECK G: ${checks.G}`);
    } catch (e) {
      checks.G = `ERROR — ${e.message}`;
      log(`CHECK G: ${checks.G}`);
    }

    // ============================================================
    // FINAL SUMMARY
    // ============================================================
    log('\n' + '='.repeat(60));
    log('FINAL VERIFICATION SUMMARY — BUG-20260424-001+002');
    log('='.repeat(60));

    const primaryChecks = ['A', 'B', 'C', 'D'];
    const allPrimaryPass = primaryChecks.every(k => checks[k] && checks[k].startsWith('PASS'));

    log('\n📊 CHECK RESULTS:');
    Object.entries(checks).forEach(([k, v]) => {
      const icon = !v ? '⬜' : v.startsWith('PASS') ? '✅' : v.startsWith('FAIL') ? '❌' : '⚠️';
      log(`  ${icon} [${k}] ${v || 'NOT RUN'}`);
    });

    log('\n📢 CONSOLE MESSAGES:');
    log(`  🆕 [R4G postFlipSynth]: ${consoleLog.postFlipSynth}`);
    log(`  🔁 [R4G deduplicate]:   ${consoleLog.deduplicate}`);
    log(`  🔄 [R4G synthesize]:    ${consoleLog.synthesize}`);
    log(`  ⚠️  [R4G symmetry]:      ${consoleLog.symmetry} (should be 0)`);

    const overallVerdict = allPrimaryPass ? '✅ PASS' : '❌ FAIL';
    log(`\n🎯 OVERALL VERDICT: ${overallVerdict}`);
    if (!allPrimaryPass) {
      primaryChecks.filter(k => !checks[k]?.startsWith('PASS')).forEach(k => {
        log(`  ❌ [${k}] ${checks[k]}`);
      });
    }
    log('='.repeat(60));

    // Save report
    const report = { commit: 'd297341', checks, consoleLog, timestamp: new Date().toISOString() };
    require('fs').writeFileSync('/home/alexey/banda/agents/kim/bug_d297341_report.json', JSON.stringify(report, null, 2));
    log('\n💾 Report: /home/alexey/banda/agents/kim/bug_d297341_report.json');

  } catch (error) {
    log(`\n❌ FATAL ERROR: ${error.message}`);
    log(error.stack);
  } finally {
    if (browser) await browser.close();
  }
})();
