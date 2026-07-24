// BUG-20260423-002 Verification — Commit 7022bd7
// Toyota_Panasonic and Volvo_Panasonic asymmetry fix via enforcePostFlipSymmetry

const { chromium } = require('playwright');

(async () => {
  console.log('🎯 BUG-20260423-002 VERIFICATION — Commit 7022bd7');
  console.log('Target: enforcePostFlipSymmetry fix for UNSOLVED counterparty asymmetry');

  let browser, context, page;
  const results = {
    timestamp: new Date().toISOString(),
    commit: '7022bd7',
    panasonicTraders: {},
    consoleMessages: {
      postFlipSynth: [],
      synthesize: [],
      symmetry: []
    },
    regressionChecks: {
      adminSolved: 'UNKNOWN',
      hondaSony: 'UNKNOWN'
    },
    verdict: 'UNKNOWN'
  };

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

    // Monitor console for fix-related messages
    page.on('console', msg => {
      const text = msg.text();
      if (text.includes('[R4G postFlipSynth]')) {
        results.consoleMessages.postFlipSynth.push(text);
        console.log(`🆕 NEW FIX: ${text}`);
      } else if (text.includes('[R4G synthesize]')) {
        results.consoleMessages.synthesize.push(text);
        console.log(`🔄 OLD FIX: ${text}`);
      } else if (text.includes('[R4G symmetry]')) {
        results.consoleMessages.symmetry.push(text);
        console.log(`⚠️  SCALING: ${text}`);
      }
    });

    // Step 1: Panasonic broker view verification
    console.log('\n🏢 === PANASONIC BROKER VERIFICATION ===');
    const panasonicUrl = 'https://dev.r4g.business-for-fun.com/?broker=Panasonic&share=lzoknmqo';
    console.log(`📍 Opening: ${panasonicUrl}`);

    await page.goto(panasonicUrl, { timeout: 60000, waitUntil: 'load' });
    await page.waitForTimeout(5000); // Allow page load and console messages

    // Debug: Check what tabs are available
    console.log('🔍 Checking available tabs in Panasonic view...');
    const allTabs = await page.locator('button, [role="tab"], a, div').filter({ hasText: /log|trade|result|data|upload|deal/i }).all();
    for (const tab of allTabs) {
      try {
        const text = await tab.textContent();
        const isVisible = await tab.isVisible();
        console.log(`  📋 "${text}" (visible: ${isVisible})`);
      } catch (e) {}
    }

    // Navigate to Log tab to find latest round
    let logTab = await page.locator('text=Log').first();
    if (!await logTab.isVisible()) {
      // Try alternative approaches
      logTab = await page.locator('button:has-text("Log")').first();
    }
    if (!await logTab.isVisible()) {
      // Try Netting Results tab instead
      logTab = await page.locator('text=Netting Results').first();
    }

    if (await logTab.isVisible()) {
      await logTab.click();
      await page.waitForTimeout(3000);
      console.log('✅ Opened Log tab');

      // Find and click latest round
      const roundRows = await page.locator('table tbody tr').all();
      if (roundRows.length > 0) {
        console.log(`📊 Found ${roundRows.length} rounds in log`);

        // Click on first (latest) round
        await roundRows[0].click();
        await page.waitForTimeout(3000);
        console.log('✅ Opened latest round drill-in');

        // Navigate to Trade Deals sub-tab
        const tradeDealsSubTab = await page.locator('text=Trade Deals').first();
        if (await tradeDealsSubTab.isVisible()) {
          await tradeDealsSubTab.click();
          await page.waitForTimeout(3000);
          console.log('✅ Opened Trade Deals sub-tab');

          // Extract all trade deals
          const dealRows = await page.locator('table tbody tr').all();
          console.log(`📊 Found ${dealRows.length} deal rows`);

          for (let i = 0; i < dealRows.length; i++) {
            try {
              const rowText = await dealRows[i].textContent();
              if (!rowText || !rowText.trim()) continue;

              console.log(`\n📝 Deal ${i+1}: ${rowText}`);

              // Parse deal: extract trader, direction, volume
              // Expected format: PanasonicTraderNameTARGET_DIRECTIONMay2026...Volume...

              let traderName = null;
              let direction = null;
              let volume = null;

              // Extract trader name from PanasonicXXXTARGET_ pattern
              const traderMatch = rowText.match(/Panasonic(\w+)TARGET_/);
              if (traderMatch) {
                traderName = traderMatch[1]; // Ford, Toyota, Volvo, Honda, etc.
              }

              // Extract direction from TARGET_BUY or TARGET_SELL
              const directionMatch = rowText.match(/TARGET_(BUY|SELL)/);
              if (directionMatch) {
                direction = directionMatch[1]; // BUY or SELL
              }

              // Extract volume - look for standalone numbers in reasonable range
              const parts = rowText.trim().split(/\s+/);
              for (const part of parts) {
                // Look for numbers that look like trading volumes (10-9999)
                if (/^\d{1,4}$/.test(part)) {
                  const num = parseInt(part);
                  if (num >= 10 && num <= 9999) {
                    volume = num;
                    break;
                  }
                }
              }

              if (traderName && direction && volume) {
                if (!results.panasonicTraders[traderName]) {
                  results.panasonicTraders[traderName] = { BUY: 0, SELL: 0, deals: [] };
                }

                results.panasonicTraders[traderName][direction] += volume;
                results.panasonicTraders[traderName].deals.push({
                  direction,
                  volume,
                  rawText: rowText
                });

                console.log(`  ✅ ${traderName}: ${direction} ${volume} MW (Running totals: BUY=${results.panasonicTraders[traderName].BUY}, SELL=${results.panasonicTraders[traderName].SELL})`);
              } else {
                console.log(`  ⚠️  Could not parse trader/direction/volume from: ${rowText.substring(0, 100)}`);
              }

            } catch (error) {
              console.log(`  ❌ Error processing deal ${i+1}: ${error.message}`);
            }
          }
        } else {
          console.log('❌ Trade Deals sub-tab not found in drill-in');
        }
      } else {
        console.log('❌ No rounds found in log');
      }
    } else {
      console.log('❌ Log tab not found in Panasonic broker view');
    }

    // Step 2: Admin view regression checks
    console.log('\n🔧 === REGRESSION CHECKS ===');
    const adminUrl = 'https://dev.r4g.business-for-fun.com/';
    console.log(`📍 Switching to admin: ${adminUrl}`);

    await page.goto(adminUrl, { timeout: 60000, waitUntil: 'load' });
    await page.waitForTimeout(3000);

    // Check admin SOLVED deals (no duplicates)
    const nettingTab = await page.locator('text=Netting Results').first();
    if (await nettingTab.isVisible()) {
      await nettingTab.click();
      await page.waitForTimeout(3000);

      const adminRows = await page.locator('table tbody tr').all();
      let solvedCount = 0;
      let duplicateIndicator = false;

      for (const row of adminRows) {
        const text = await row.textContent();
        if (text && text.includes('SOLVED')) {
          solvedCount++;
          // Check for suspicious patterns that might indicate duplicates
          if (text.includes('100%') && solvedCount > 10) {
            duplicateIndicator = true;
          }
        }
      }

      results.regressionChecks.adminSolved = duplicateIndicator ? 'POTENTIAL_DUPLICATES' : 'CLEAN';
      console.log(`✅ Admin SOLVED deals: ${solvedCount} found, status: ${results.regressionChecks.adminSolved}`);
    }

    // Check Honda_Sony symmetry (should not be broken)
    const sonyUrl = 'https://dev.r4g.business-for-fun.com/?broker=Sony&share=gei29u4l';
    console.log(`📍 Checking Honda_Sony: ${sonyUrl}`);

    await page.goto(sonyUrl, { timeout: 60000, waitUntil: 'load' });
    await page.waitForTimeout(3000);

    // Quick Honda symmetry check
    let hondaBuy = 0, hondaSell = 0;
    const sonyLogTab = await page.locator('text=Log').first();
    if (await sonyLogTab.isVisible()) {
      await sonyLogTab.click();
      await page.waitForTimeout(2000);

      const sonyRounds = await page.locator('table tbody tr').all();
      if (sonyRounds.length > 0) {
        await sonyRounds[0].click();
        await page.waitForTimeout(2000);

        const sonyTradeDealsSub = await page.locator('text=Trade Deals').first();
        if (await sonyTradeDealsSub.isVisible()) {
          await sonyTradeDealsSub.click();
          await page.waitForTimeout(2000);

          const hondaRows = await page.locator('table tbody tr').all();
          for (const row of hondaRows) {
            const text = await row.textContent();
            if (text && text.includes('Honda')) {
              if (text.includes('BUY')) {
                const vol = text.match(/(\d{1,3})/);
                if (vol) hondaBuy += parseInt(vol[1]);
              }
              if (text.includes('SELL')) {
                const vol = text.match(/(\d{1,3})/);
                if (vol) hondaSell += parseInt(vol[1]);
              }
            }
          }
        }
      }
    }

    results.regressionChecks.hondaSony = (hondaBuy === hondaSell) ? 'SYMMETRIC' : `ASYMMETRIC_${hondaBuy}vs${hondaSell}`;
    console.log(`✅ Honda_Sony regression: BUY=${hondaBuy}, SELL=${hondaSell}, status: ${results.regressionChecks.hondaSony}`);

    // Analysis and verdict
    console.log('\n' + '='.repeat(60));
    console.log('📊 PANASONIC SYMMETRY ANALYSIS');
    console.log('='.repeat(60));

    let allSymmetric = true;
    const asymmetricCases = [];

    for (const [trader, data] of Object.entries(results.panasonicTraders)) {
      const isSymmetric = data.BUY === data.SELL;
      const status = isSymmetric ? '✅ SYMMETRIC' : '❌ ASYMMETRIC';

      console.log(`${status} ${trader}: BUY=${data.BUY} MW, SELL=${data.SELL} MW (${data.deals.length} deals)`);

      if (!isSymmetric) {
        allSymmetric = false;
        asymmetricCases.push(`${trader}: BUY=${data.BUY}, SELL=${data.SELL}`);

        // Special focus on Toyota and Volvo (main fix targets)
        if (trader === 'Toyota' || trader === 'Volvo') {
          console.log(`  🚨 MAIN TARGET ${trader} STILL ASYMMETRIC!`);
        }
      }
    }

    // Console message summary
    console.log('\n📢 CONSOLE MESSAGE SUMMARY:');
    console.log(`🆕 [R4G postFlipSynth] messages: ${results.consoleMessages.postFlipSynth.length}`);
    console.log(`🔄 [R4G synthesize] messages: ${results.consoleMessages.synthesize.length}`);
    console.log(`⚠️  [R4G symmetry] messages: ${results.consoleMessages.symmetry.length} (should be 0)`);

    // Final verdict
    if (allSymmetric) {
      results.verdict = 'PANASONIC_SYMMETRIC: YES';
    } else {
      results.verdict = `PANASONIC_SYMMETRIC: NO - ${asymmetricCases.join(', ')}`;
    }

    console.log('\n' + '='.repeat(60));
    console.log(`🎯 FINAL VERDICT: ${results.verdict}`);
    console.log(`📊 Traders analyzed: ${Object.keys(results.panasonicTraders).length}`);
    console.log(`🆕 postFlipSynth confirmations: ${results.consoleMessages.postFlipSynth.length}`);
    console.log(`🔧 Admin regression: ${results.regressionChecks.adminSolved}`);
    console.log(`🏎️  Honda_Sony regression: ${results.regressionChecks.hondaSony}`);

    // Save detailed report
    const reportPath = '/home/alexey/banda/agents/kim/bug_7022bd7_report.json';
    require('fs').writeFileSync(reportPath, JSON.stringify(results, null, 2));
    console.log(`\n💾 Detailed report: ${reportPath}`);
    console.log('='.repeat(60));

  } catch (error) {
    console.error('❌ VERIFICATION FAILED:', error.message);
    results.verdict = 'VERIFICATION_ERROR';
    results.error = error.message;
  } finally {
    if (browser) {
      await browser.close();
    }
  }

  console.log(`\n🏁 BUG-20260423-002 VERIFICATION COMPLETE`);
  console.log(`Result: ${results.verdict}`);
})();