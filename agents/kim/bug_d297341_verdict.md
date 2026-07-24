# BUG-20260424-001+002 — Verification Report
**Commit:** d297341  
**Date:** 2026-04-24  
**Tester:** Kim Wexler

## CHECK RESULTS

### [A] Toyota_Panasonic — ❌ FAIL
Expected: 1 row, TARGET_SELL only (UNSOLVED = no phantom BUY)  
Actual: **6 rows** (3×BUY + 3×SELL)

Breakdown:
- Row 1:  TARGET_BUY  NBP(31.75) EEX 40MW  ← PHANTOM (should not exist)
- Row 2:  TARGET_SELL TTF(32)    EEX 40MW  ← legitimate SELL
- Row 8:  TARGET_SELL TTF(32)    EEX 40MW  ← exact dup of row 2
- Row 9:  TARGET_BUY  NBP(31.75) EEX 40MW  ← exact dup of row 1 (phantom)
- Row 10: TARGET_BUY  TTF(32)    EEX 40MW  ← hub-swapped phantom
- Row 11: TARGET_SELL NBP(31.75) EEX 40MW  ← hub-swapped phantom

Root issues: UNSOLVED guard did NOT suppress Toyota's phantom BUYs; deduplicateTradeDeals did NOT remove Toyota duplicates.

### [B] Volvo_Panasonic — ✅ PASS
1 row, TARGET_BUY 40MW only. No phantom SELL. UNSOLVED guard worked correctly for Volvo.

### [C] Ford_Panasonic — ✅ PASS
2 rows: TARGET_BUY 100MW + TARGET_SELL 100MW. No duplicates.

### [D] Honda_Panasonic — ✅ PASS
2 rows: TARGET_BUY 50MW + TARGET_SELL 50MW. No duplicates.

### [E] Total Row Count — ❌ FAIL
Actual: 11 rows (expected ≤10)  
Extra rows attributable entirely to Toyota_Panasonic (+5 phantom/duplicate rows).

### [F] Admin Trade Deals — ❌ FAIL
1 duplicate group: SonyHonda TARGET_BUY TTF EEX 40MW (Toyota_Panasonic counterparty) appears in rows 6 and 11.  
Admin total: 14 rows.

### [G] Honda_Sony Symmetry (regression) — ✅ PASS (with caveat)
Honda_Sony: BUY=80MW, SELL=80MW.  
Caveat: Sony Trade Deals also has duplicate rows (Volvo×2 pairs, Honda×2 BUY entries). Symmetry passes only because both sides are equally duplicated. Actual expected is BUY=40, SELL=40.

### [H] Volume Symmetry Panasonic SOLVED traders — ✅ PASS
Ford(100/100), Honda(50/50). Volvo(40/0) and Toyota(120/120) are UNSOLVED — expected asymmetry for Volvo, phantom symmetry for Toyota.

## CONSOLE MESSAGES
- `[R4G postFlipSynth]`: 2 ← new fix running but insufficient for Toyota
- `[R4G deduplicate]`: **0** ← dedup function produced 0 log messages (not logging or not running)
- `[R4G synthesize]`: 38 ← old fix running
- `[R4G symmetry]`: 0 ✅ (scaling correctly disabled)

## OVERALL VERDICT: ❌ FAIL

Primary check A FAILS. Toyota_Panasonic still has phantom+duplicate rows.

### What worked:
- Volvo_Panasonic UNSOLVED guard: ✅ fixed
- Ford, Honda deduplication: ✅ fixed
- Scaling messages still disabled: ✅

### What did NOT work:
- Toyota_Panasonic UNSOLVED guard: ❌ still shows phantom BUY rows
- Toyota_Panasonic deduplication: ❌ still has exact duplicates
- Admin deduplication: ❌ 1 duplicate group remaining

### Pattern observation:
Volvo (UNSOLVED 40MW) was fixed; Toyota (UNSOLVED, also 40MW in Trade Deals) was not. Something in Toyota's specific netting data or code path bypasses both the UNSOLVED guard and dedup logic.

