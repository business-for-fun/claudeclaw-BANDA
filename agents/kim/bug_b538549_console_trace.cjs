// Console trace — capture ALL R4G console messages to identify guard log prefix
const { chromium } = require('playwright');

(async () => {
  console.log('🔍 CONSOLE TRACE — capturing ALL R4G messages for b538549');
  let browser;
  const allR4G = [];

  try {
    browser = await chromium.launch({ headless: true });
    const ctx = await browser.newContext({
      viewport: { width: 1440, height: 900 },
      httpCredentials: { username: process.env.R4G_DEV_USER, password: process.env.R4G_DEV_PASS }
    });
    const page = await ctx.newPage();

    // Capture ALL console messages
    page.on('console', msg => {
      const t = msg.text();
      if (t.includes('[R4G') || t.toLowerCase().includes('synth') || t.toLowerCase().includes('skip') ||
          t.toLowerCase().includes('toyota') || t.toLowerCase().includes('phantom') ||
          t.toLowerCase().includes('detail') || t.toLowerCase().includes('zero')) {
        allR4G.push(t);
      }
    });

    await page.goto('https://dev.r4g.business-for-fun.com/?broker=Panasonic&share=lzoknmqo',
      { timeout: 60000, waitUntil: 'load' });
    await page.waitForTimeout(5000);

    // Open netting results, click first round, open trade deals
    const nBtn = page.locator('text=Netting Results').first();
    await nBtn.click();
    await page.waitForTimeout(5000);

    const rounds = await page.locator('table tbody tr').all();
    console.log(`Found ${rounds.length} rounds`);
    await rounds[0].click();
    await page.waitForTimeout(4000);

    const tdTab = page.locator('text=Trade Deals').first();
    if (await tdTab.isVisible({ timeout: 3000 }).catch(() => false)) {
      await tdTab.click();
      await page.waitForTimeout(3000);
    }

    console.log('\n📢 ALL R4G/SYNTH/SKIP CONSOLE MESSAGES:');
    console.log(`Total captured: ${allR4G.length}`);
    allR4G.forEach((m, i) => console.log(`  ${String(i+1).padStart(3)}. ${m}`));

    // Count by prefix
    const prefixes = {};
    allR4G.forEach(m => {
      const match = m.match(/\[R4G[^\]]*\]/);
      const prefix = match ? match[0] : 'NO_PREFIX';
      prefixes[prefix] = (prefixes[prefix] || 0) + 1;
    });
    console.log('\n📊 GROUPED BY PREFIX:');
    Object.entries(prefixes).sort(([,a],[,b]) => b-a).forEach(([p, n]) => {
      console.log(`  ${n}× ${p}`);
    });

  } catch (e) {
    console.error(`FATAL: ${e.message}`);
  } finally {
    if (browser) await browser.close();
  }
})();
