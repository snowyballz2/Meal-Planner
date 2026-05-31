# Audit Round 12 — Findings (working doc, uncommitted)

Baseline: `main` @ ac9f66d (V220), all hard INV at 0. Scope: full-system correctness + cleanup. Method: solo deep-read.
Severity: **CRITICAL** (data corruption / wrong output / hard-INV risk) · **MEDIUM** (edge-case wrong behavior, latent) · **LOW** (cleanup, cosmetic, defense-in-depth).

Status legend: 🔴 open · 🟡 needs user decision · ✅ verified-non-issue.

---

## 1. Data layer + DB consistency — DONE
Checks run: all `I()` refs resolve to NUTRI_DB (clean, 0 dangling); 61 meals, no dup IDs, no invalid slots; every lunch/dinner has a veg-role ingredient (INV10 surface holds); all DEFAULTS assignments resolve + support slot + person-flag OK.

- **L1 (LOW/cleanup)** — `triscuit` (index.html:565) is the **only** scalable non-`fixed` ingredient with no `maxAmt`. Every other scalable carb has one. It's `wholeOnly` (whole-snapped) and only in 10%-budget snacks, so real-world scaling is bounded — but INV13 can't bound it and it's an inconsistency. Suggest adding `maxAmt` (e.g. 8).
- **DOC nit (not code)** — CLAUDE.md waste-flag table lists lemon/lime under `softWaste`; DB (493/546) flags them `acceptableWaste` (per V204, memory authoritative). Only the CLAUDE.md summary table is stale. (Whether both INV20 sites honor `acceptableWaste` consistently → deferred to §9.)

No CRITICAL/MEDIUM in the data layer.

---

## 2. Calorie adjuster + display helpers — DONE
fmtFrac (595) and buildQtyOptions (701) reviewed — snap logic correct and well-reasoned. adjustIngredients (943) full path read.

- **M1 → downgraded to L-M1 (LOW/cleanup — verified benign in §6)** ✅ — `adjustIngredients`' **final min/max sweep** (index.html:1318–1332, full-adjustment path) does NOT skip freeze-pinned items, but the **early-return `_clampThresh`** (968–996) explicitly DOES, citing *"Clamping these can silently violate the freeze contract."* Real asymmetry — the skip is on one path, not its mirror. **VERIFIED BENIGN**: freeze's own bound expressions (`_freezeOneItem` 11590–11595: `minAmtSolo??minAmt` / `maxAmtSolo??maxAmt` / `minAmt` / `maxAmt`) are character-identical to `_effMin`/`_effMax` (957–966), and a pin is only written when `_tryFreezeY`/`_distributeAcrossBatches`/`_tradeBatchesAndSolos` satisfy those bounds (11926–11927, 11974–11975, 12079, 12104–12105). So a written pin is ALWAYS within the bounds the clamp would enforce → the clamp is a no-op. **Empirical confirmation: 28 seeds (him/her/shared), 2040 freeze pins checked (978 on solo slots incl. celery/carrots/broccoli/cucumber where solo bounds differ), 0 out of bounds.** Impact today: **zero**. Worth fixing only as defense-in-depth + consistency (every other post-pipeline pass DOES carry the skip) — becomes live only if freeze bounds ever diverge from adjustIngredients bounds.
- **L2 (LOW/cleanup)** — `buildQtyOptions` `'quarter'` branch (758–761) is dead (no DB unit is `'quarter'`); `qLabels` (760) is defined then immediately overwritten and never used. `'can'` in the each-branch condition (742) also never matches a real unit.
- **(note, no action)** — snap-pass minAmt at 1203 uses `db.minAmt` directly rather than `_effMin`, applying the batch floor even on solo slots; harmless because the final sweep re-applies `_effMin`/minAmtSolo right after.

---

## 3. Leftover/batch detector — DONE
computeLeftovers (3964), _collectHouseholdCooks (4077), _buildPostPipelineFrozenSlots (4109), countInv14/11 (4139/4160), _syncSamePersonBatchPortions (5436) reviewed. Logic sound: anchor=him-first lunch/dinner, batch window cook+2, cap 6, portions list, sameDayShared flag, INV12 (totalServings===portions.length) holds by construction.

- **(verified non-issue ✅)** — `countInv14` (4142–4145) counts HOUSEHOLD pairs (no person filter). Confirmed `verifyInvariants` INV14 (7345–7358) is identical (also `_collectHouseholdCooks` + person-agnostic loop). They match — no divergence between the swap-rejection counter and the fired invariant.
- **DOC nit (not code)** — CLAUDE.md INV14 row says *"Per person, no two NEW cooks…"* but the implementation (and code comment at 7339) is explicitly **household-level**. Doc table is misleading; code is self-consistent.
- **(note, low)** — breakfast/snack occurrences are collected in Phase 1 (3980) but can neither anchor (cookSlots=lunch/dinner) nor be leftovers (leftoverSlots=lunch/dinner); they're inert in batching (verified harmless across mixed-slot cases). `feedsAlso`/`feedsDay` capture only the *first* cross-person portion (UI-label only). `getPort('shared')` (4219) returns BASE-recipe combined macros, not balanced — appears legacy (real shared UI uses renderSharedCard); confirm no displayed-number consumer in §11.

No CRITICAL/MEDIUM in the detector.

---

## 4. Day balancer — DONE
getDayBalancedIngredients (5482) + balanceDayMacros (5753) read in full. Both carefully built:
- Recursion to cook days (5572/5697) always terminates (cookDay < leftoverDay); same-day-leftover materialization (5723) preserves INV1; dinner-absorbs-residual (5559–5595) sums everything-else incl. shake to hit CAL_BASE.
- Priority loop P0–P4: V211 1.25× slot cap correctly applied to all non-shake slots (5898–5908); "no make-worse" predictDayMacroPct guards (6091) sound; thrash detection (6259) reasonable; frozen slots (shake/leftovers) never mutated (itemsByRole skips them, 5815).

- **L3 (LOW/cleanup)** — `bestAdd('other')` is dead: P0's under-target boost order is `['protein','carb','other','fat']` (6073) but **0** ingredients have `role==='other'` (confirmed: only carb/condiment/fat/fixed/fruit/liquid/protein/veg in use). The `'other'` step always returns null. Functionally harmless (you wouldn't pad day kcal with condiments anyway) but it's a dead order entry. Remove `'other'` from the order.

No CRITICAL/MEDIUM in the day balancer.

---

## 5. Unify + snap + RBA loop — DONE
runBalanceAdjusters (14819), unifyCrossPersonRatios (14102), snapBatchTotals (14368), snapBatchTotalsToGrid (13947), snapSoloSlotAmountsToGrid (13866), boostBatchVegForDailyTarget (13712, disabled). All correct:
- RBA: clean 6-iter convergence; unify untracked-for-exit (can't infinite-loop even when it always flags affectedDays on infeasible floors); INV18 cap tracking.
- All 3 post-pipeline `balanceDayMacros` callers (14084/14357/14562) correctly omit `sameDayCookServings` (→ `{}`) per the LOAD-BEARING comment → no triple-count (resolves §4 concern).
- unify Option-C budget denominator + soft/hard-floor∩maxAmt infeasibility logic (14211–14283) is careful INV13 defense.
- **Sharpens M1**: every snap pass DOES skip freeze pins (`scalable===false && ∈ROUND_* → return`, e.g. 14175/14419/13973/13901). adjustIngredients' final sweep is the **only** post-pipeline write that omits this skip → M1 is inconsistent with the established pattern.

- **L4 (LOW/cleanup)** — dead `lo.sharedWith` check in unifyCrossPersonRatios (14119) **and** snapBatchTotals (14388). The current unified detector never sets `sharedWith` on an anchor (one anchor per batch); the guard never fires. Vestigial from the pre-unified "parallel co-anchor" model. Safe to remove (with comments).
- **L5 (LOW/latent)** — snapSoloSlotAmountsToGrid (13866) applies `db.minAmt`/`db.maxAmt` (13924–13925, 13936–13937) on **solo** slots, not the solo-aware `minAmtSolo`/`maxAmtSolo` that INV13 checks for solo slots. Currently unreachable (adjustIngredients `_effMin`/`_effMax` + balancer `_trimFloor`/`_addCeil` already pin solo values at the solo bounds on-grid), but it's the same fragile pattern as M1. Same-class consistency fix.
- **DOC nit** — CLAUDE.md calls it `unifyCrossPersonRatios(skipRebuild)`; the function now takes no args.
- **(cleanup candidate, user call)** — `postBalanceWastePass` (14582, ~240 lines) and `boostBatchVegForDailyTarget` (13712, ~135 lines) are disabled in RBA but fully defined; comments say keep them for possible revert. Flagging as dead-weight only if you want them gone — NOT recommending deletion.

No CRITICAL/MEDIUM in unify/snap/RBA.

---

## 6. Freeze pipeline — DONE
freezeTripTotals (10944), _freezeOneItem (11476), _tryFreezeY (11904), _distributeAcrossBatches (11958), _tradeSolosOnly (12016), _tradeBatchesAndSolos (12044), _trySwapForWaste (11682) all read. Sound: c1-aware carryUsed=min(priorCarry,c1Demand) (V208), Y_round±perUnit search (V210), trade hierarchy with bound enforcement at every write path, V175 multi-candidate swap with post-swap clean-verify, co-contributor override cleanup.

- **L-M1 resolved here** — see §2; verified benign via the 2040-pin probe.
- **(inert, intentional)** — `SWAP_OUT_EXCLUDE = {}` (11680) makes the checks at 11739–11743 dead, but the V201 comment says it's kept for future explicit-exempt items. Not flagging.
- **(documented trade-off)** — `_trySwapForWaste` cascade L1+ (11818–11821) drops the 4-day variety filter and only blocks INV11, so a last-resort waste swap can raise the INV14 (tracking-only) count. Acknowledged in-code; acceptable per design.

No CRITICAL/MEDIUM in the freeze pipeline.

---

## 7. Stage 2 absorb + carryover + variety — DONE
_absorbWeeklyDemandSplit (12199), _absorbFindCandidates (12244), _absorbHardINVsClean (12366), _absorbCarryItem (12433), _computePriorCarryover (12668), getRecentMealIds (12767), isBatchLeftoverEligible (12824), _prevWeekKey (12638). All sound:
- absorb: binary commit-or-revert, c1-aware (V208), V205 INV14 cross-pair pre-skip, 30-trial cap, `_absorbHardINVsClean` hard set correct (INV1–5/7–13/17/19/23–25 + INV20-hard; omits INV26 which is harness-only ✓).
- `_computePriorCarryover`: sequential-fill freshness rule correct (only NEW cook2 jars carry).
- `getRecentMealIds`: symmetric ±lookback, SEL-direct, skips leftovers this-week. Prev-week backward branch (12797–12804) does NOT skip leftovers — **correct by construction** (a prior-week leftover implies an anchor 0–2 days earlier, so rejecting that meal is the right INV14 call).

- **(note, low)** — `_computePriorCarryover` resolves prior-week recipes via the *current* `getMeal(mid)` definition (12702). If a custom meal's recipe was edited between weeks, the carryover estimate uses the new recipe, not what was cooked. Tracking-only (INV20Leftover) impact; negligible.

No CRITICAL/MEDIUM in absorb/carryover/variety.

---

## 8. Randomize core + post-retry sequence — DONE
randomizeWeek (14853), _randomizeWeekCore Phase 1 (16013), rerollMissDays (15181), rerollInv14Violations (15853), rerollKcalOffSnacks/Breakfast (15350/15569), skipKcalOverSnacks (15744). Post-retry order matches doc; reroll passes revert correctly + carry INV14/INV11/waste delta gates; skipKcalOverSnacks V218 co-contributor guard correct.

- **L6 (LOW/cleanup + DOC fix)** — **dead `bestCaches`/`cacheFromWinner` machinery.** `bestCaches` is initialized null (14924) and only ever reassigned `null` (15012, "force post-retry rerun"). So the `if(bestCaches){…}` cache-restore block (15035–15043), its sole `cacheFromWinner=true` (15043), and the `else` freeze branch (15081–15084) are **unreachable** — the pipeline always reruns. ~15 inert lines + a vestigial variable threaded through 6 sites. **Directly contradicts CLAUDE.md's "Stage 1a (2026-04-24) … bestCaches … skip re-running an identical pipeline"** — that optimization was disabled by V97 (2026-05-08) but the scaffolding + doc claim remain. Remove the dead branch; correct the doc.
- **L7 (LOW/latent, dormant)** — `rerollInv14Violations.tryResolveCook` swaps an anchor's `SEL[key]` (+`otherKey` for shared) but NOT that anchor's **time-shifted leftover** slots' SEL, so the leftover orphans into a fresh solo cook; the accept gate measures only `dayMissCount(t.d)` (waste + inv14 are global, but goal-misses on the orphaned day are unmeasured). **Empirically dormant: 0 commits across 30 seeds** (the retry selector ranks inv14 4th and drives `bestInv14`→0, so the resolver almost never runs). `rerollMissDays` shares the swap pattern but **self-heals** (orphans always land on later-processed days in its Mon→Sun sweep); `rerollKcalOff*` only touch breakfast/snack (never batch members). Fix (gate on global misses, or re-point/clear orphaned leftover SEL) **before** promoting INV14 to hard.
- **DOC nit** — retry-selector comment at 14945 says order is `(goalMisses, actualWaste, inv14)`; actual V188 code (15002–15005) is `(inv11, goalMisses, totalWaste, inv14)`. CLAUDE.md's "Retry selection: 1 waste 2 misses 3 inv14" is also stale (wrong order + omits inv11).

No CRITICAL/MEDIUM in randomize/post-retry.

---

## 9. verifyInvariants (all 26) — DONE
Read INV1–26 end to end. All checks correct: tolerances match the doc, both INV20 sites (per-trip 7524 + weekly `_inv20CarryWeekly` 7618) gate `longShelfLife`/`acceptableWaste`/`nonWaste`/`crossTripCarry` symmetrically (V219), and the hard/tracking split is **consistent across 3 sites** (`_absorbHardINVsClean` 12374, aggregator `hardFail` 20139, formatReport hardKeys 20240) — same hard set, same tracking exclusions, INV20-hard = INV20−INV20Soft everywhere, INV26 correctly harness-only. INV2 skips SKIPPED (6378) → confirms V214 skip-without-rebuild stays INV2-consistent. INV13 `isSoloSlot=!slotLo` (7294) matches freeze/adjustIngredients solo classification (corroborates M1).

- **L8 (LOW/cleanup + DOC)** — `db.produce.crossTripCarry` is **dead**: referenced in ~6 places (`_isCarryItem` 10987, `_inv3IsCarry` 6411, `_computePriorCarryover` 6683, `_inv20CarryWeekly` 7654/7693, absorb) but **no produce item sets it** (lemon/lime were moved to `acceptableWaste` in V199/V204). The branches never fire; the "(lime, lemon)" comments (e.g. 6409) are stale and contradict the 7684 comment ("lemon/lime lost crossTripCarry in V199"). Harmless dead scaffolding — remove branches or at least fix comments.
- **Resolves §1 DOC nit** — INV20 produce branch (7590) skips `acceptableWaste` → lemon/lime are **silently skipped**, matching the DB. Only CLAUDE.md's waste table (listing them as softWaste) is stale.

No CRITICAL/MEDIUM in verifyInvariants — cleanest subsystem.

---

## 10. Shopping list + INV3 — DONE
buildShoppingList (4604), shopQtyWithCount (4322), shopQtyAsCacheUnits (4427), _pkgsNeeded (4317), carry/prior-week pass. Clean:
- cook1/cook2 cook-anchor attribution + carry/prior-week subtraction are **exact mirrors** of INV3's `expected` reconstruction (6414–6748) — and INV3=0 in production confirms they agree.
- `_pkgsNeeded` 1e-9 epsilon prevents float-ceil over-buying a container; display/cache twins (`shopQtyWithCount`/`shopQtyAsCacheUnits`) are themselves runtime-verified by INV3's V126b drift check; dry-conversion uses cookedRange tolerance.
- custom trip = slot-based attribution (matches user intent; not INV3-scoped).

Carries the §9 dead `db.produce.crossTripCarry` note (the `_isCarry` here at 4678 also checks it; never true today).

No CRITICAL/MEDIUM in shopping.

---

## 11. UI rendering + state mutations — DONE
Render functions (computeCardMacros/buildIngrEditRow/buildMealCardHtml/renderMeals/renderSharedCard) are guarded by INV5/9/23/25 (all 0). Focused on state-mutation cache discipline:
- All mutations invalidate correctly: toggleSkip/toggleEatOut/toggleShared/changeMeal → `invalidateLeftoverCache()` before render; onIngr* use `_writeUserPin` success→preserve-cache / failure→invalidate; onIngrReset (10693) literal snapshot-restore (writes cache directly, correctly no invalidation; freeze pins preserved, V142 narrow-rebuild fallback).
- `calcTotals` (7961) **and** INV2 (6378) both skip SKIPPED → fully resolves §8 V214 consistency.
- **Cross-randomize health: ~60 direct randomizes (him/her/shared) in the live app produced ZERO hard-INV fires** — only tracking INVs (INV6 structural P/C outliers `sticky_miso_salmon_bowl`/`korean_juk`/`savory_congee` exactly per doc; INV15/16; INV20/22/INV20Soft avocado softWaste → hard count 0). Matches documented production quality.

- **L9 (LOW/doc)** — comment at index.html:9864–9867 (`recomputeLateSnackMacros` block) states *"Late snack does NOT participate in the day balancer … can never disturb other slots."* But `getDayBalancedIngredients` dinner-residual (5591) and `balanceDayMacros` `dailyMacros` (5798) **both add late-snack kcal**. So a standing late snack DOES reduce dinner at randomize/rebuild time; a post-randomize manual add is a pure add-on (cache not invalidated). No functional bug (calcTotals/INV2 count it consistently either way) — the comment is just misleading. Fix the comment.

No CRITICAL/MEDIUM in UI/state.

---

## 12. Sync + persistence + schedule edit — DONE

- **M2 (MEDIUM — confirmed bug) 🔴🟡 — surgical ingredient edits don't sync across devices.**
  `_writeUserPin` (10454) writes the override (`setOverride`, 3686) + sets `MANUAL_SET[k]` + `_markUserEdited`, but **never bumps `weekData[w].ts[k]`** (`setOverride` doesn't; `_markUserEdited` only sets the USER_EDITED display flag; `onIngrAmt` doesn't either). Meanwhile `mergeSyncData` merges `overrides` **and** `manualSet` ONLY inside the SEL-timestamp loop, gated by `remoteTime > localTime` on the **SEL** ts (17704–17710). There is **no `overridesTs`/`manualSetTs` map** (grep=0) and `saveWeeks` stamps per-key ts via `_stampDiffTs` for skipped/eatOut/lateSnack/sharedSchedule but **not** for overrides/manualSet (17451/17453). `changeMeal` syncs fine because it calls `stampSel` (bumps ts); surgical edits keep the same meal, so the ts never moves.
  **Consequence:** a per-ingredient amount edit / ingredient swap / temp-ingredient add (the "Surgical User Edits" feature) does NOT propagate on normal pull — only via **Force Push** (bumps all ts) or a later meal change on that slot. The slot's MANUAL_SET also fails to propagate (so the other device's LOCK_MANUAL_SLOTS can't even see it). Contradicts CLAUDE.md's "v4 per-key LWW … overrides" claim.
  **Empirically reproduced** (clean, state restored): local override amt=5 / ts=1000; remote = device-A surgical edit amt=9 / ts=1000 (unchanged) → after `mergeSyncData`, local stayed **amt=5** (`syncedRemoteEdit:false`).
  **Severity:** not corruption, single-device unaffected, Force Push works around it — but a real cross-device data-consistency gap on a documented feature (two people could cook different amounts). **Fix (your call — not applied):** simplest is `_writeUserPin` → `_bumpSlotTs(sk(p,d,s))` so overrides ride the SEL-ts merge (SEL is unchanged so copying it across is a no-op); or add `overridesTs`+`manualSetTs` maps with `_stampDiffTs` for true independent LWW. Confirm onIngrSwap/confirmTempIngredient/onIngrReset paths get the same bump.

- **Schedule edit (schedTap*/paint*/link groups):** light pass — these are V25–V86 mature and covered by the **Slot Mod Test (200/200 ops)** + **INV24** runtime mutual-exclusion (0 in production). Verified `changeMeal` clears contradicting SKIPPED/EAT_OUT/shared state (10126–10140). Prioritized the higher-risk sync merge over re-deep-reading the well-tested grid; no issues surfaced in the paths I did read.
- `mergeSyncData` otherwise correct: monday-date matching w/ ±1d fuzzy migration, legacy v3→ts0, per-key LWW for skipped/eatOut/lateSnack/sharedSchedule, V71 `skip-*`→`eo-*` migration, V151 initialized-flag union, LOCK_MANUAL_SLOTS guard.

M2 is the one MEDIUM of the audit.

---

## 13. Cross-cutting cleanup sweep — DONE
Removed-feature remnants verified gone (no live code): `pkg.type:'bulk'` (0), `getLastWeekMealIds` (deleted V217 — only 2 explanatory comments), `sun`/`wed` trip keys (0), `applyTripFlexScaling` / `_fastTripWasteForPersons` (functions removed). `SWAP_OUT_EXCLUDE={}` intentional.

- **L10 (LOW/cleanup — stale comments referencing removed code)** — `applyTripFlexScaling` is **removed but 8 comments still describe it as live**: 1171 ("handled by applyTripFlexScaling runs later"), 1307/1309 ("now owns all trip-level package fitting"), 6752 (INV4 rationale), 10831 (PKG_FLEX_CONFIG header — flex config now only feeds INV4's gate, not a scaling pass), 13859, 16295, 16649. Misleads anyone reading the pipeline. `_fastTripWasteForPersons` (3) and `getLastWeekMealIds` (2) comments are historical-only (fine). Recommend updating the 8 applyTripFlexScaling comments to point at `freezeTripTotals`.
- **(verify, low)** — `_paintSlot` (11 refs) is declared "legacy — kept for external refs (unused in new flow)"; confirm it's truly vestigial and droppable.

### Consolidated cleanup list (all LOW; none affect output)
| ID | Where | What |
|---|---|---|
| L1 | NUTRI_DB:565 | `triscuit` is the only scalable carb with no `maxAmt` (INV13 can't bound it) |
| L2 | buildQtyOptions 758–761 | dead `'quarter'` branch + unused `qLabels`; `'can'` case never matches |
| L3 | balanceDayMacros 6073 | `bestAdd('other')` — no ingredient has role `'other'`; dead order entry |
| L4 | unify 14119 / snapBatchTotals 14388 | dead `lo.sharedWith` guard (never set by unified detector) |
| L5 | snapSoloSlotAmountsToGrid 13924–13937 | uses `db.minAmt`/`maxAmt` not solo-aware bounds (masked by upstream) |
| L-M1 | adjustIngredients 1318–1332 | final sweep lacks freeze-pin skip — **verified benign** (bounds identical) |
| L6 | randomizeWeek 15035–15084 | dead `bestCaches`/`cacheFromWinner` machinery (always reruns) |
| L7 | rerollInv14Violations 15918 | anchor swap orphans time-shifted leftovers, gate misses those days — **dormant (0/30)** |
| L8 | ~6 sites | dead `db.produce.crossTripCarry` branches + stale "(lime,lemon)" comments |
| L9 | recomputeLateSnackMacros 9864 | comment "late snack does NOT participate in balancer" is wrong |
| L10 | 8 sites | stale `applyTripFlexScaling` comments (function removed) |

### Doc nits (CLAUDE.md / comments, not code)
- Waste-flag table lists lemon/lime as `softWaste`; they're `acceptableWaste` (DB + code agree).
- INV14 row says "Per person"; implementation is **household**.
- `unifyCrossPersonRatios(skipRebuild)` — function now takes no args.
- Retry-selector "1 waste 2 misses 3 inv14" — actual is `(inv11, goalMisses, totalWaste, inv14)`.
- "Stage 1a bestCaches skip-rerun" optimization — disabled by V97; code path dead.

### Cleanup candidates (user's call — NOT recommending deletion)
- `postBalanceWastePass` (14582, ~240 lines) and `boostBatchVegForDailyTarget` (13712, ~135 lines): disabled in RBA, fully defined, comments say keep for possible revert.

---

# SUMMARY — Audit Round 12

**Method:** solo deep-read of all ~24,971 lines across 13 subsystems + live-app probes (28-seed freeze-pin bounds check, 30-seed INV14-resolver activity, 60-randomize hard-INV scan, 2 mergeSyncData reproducers). State restored after each probe.

**Headline:** the pipeline is in excellent shape. **No CRITICAL findings. One MEDIUM. Zero hard-INV fires across ~60 live randomizes** (only documented tracking INVs: INV6 structural P/C outliers, INV15/16, INV20Soft avocado).

**The one thing to decide:**
- **M2 (MEDIUM, confirmed + reproduced):** surgical ingredient edits (amount/swap/temp-add) don't sync across devices — `_writeUserPin` never bumps the slot ts, and `mergeSyncData` gates override/manualSet merge on the SEL ts (no `overridesTs` map). Only Force Push or a meal change propagates them. Suggested fix: `_bumpSlotTs` in `_writeUserPin` (one line; SEL unchanged so the merge copy is a no-op). **Not applied — awaiting your call.**

**Everything else is LOW** (10 cleanup items + 5 doc nits, table above) — dead branches, stale comments, defensive-consistency gaps that upstream code already masks. None change output.

**Suggested next step:** decide on M2 (fix now vs. defer), then I can batch the LOW cleanups + doc fixes into a single commit if you want. (This `AUDIT_ROUND_12.md` is an uncommitted working doc.)

---

# RESOLUTION (all shipped 2026-05-30)

All findings actioned per user direction. 6 commits, each verified via `MPStress.runStandard` (clean-state harness — NOT naive back-to-back `randomizeWeek`, which accumulates polluted prior-week carryover → spurious INV3/INV20; caught during V222 via a baseline A/B).

| Commit | Branch | Contents | Verify |
|---|---|---|---|
| **V221** | MP_2026-05-30_V8 | **M2** — `_bumpSlotTs` in `_writeUserPin`/confirmTempIngredient/onIngrReset so surgical edits sync across devices | reproduced fixed (amt 9 propagates) + 0 hard after live edit |
| **V222** | _V9 | **L1** triscuit min/max, **L5** snapSolo solo-aware bounds, **L-M1** final-sweep freeze-pin skip | runStandard(12) 0 hard, 100% primary |
| **V223** | _V10 | **L7** INV14 resolver gates on household-wide misses | runStandard(12) 0 hard |
| **V224** | _V11 | **L2/L3/L4/L6** dead-code removal (quarter branch, bestAdd('other'), lo.sharedWith, bestCaches) | runStandard(12) 0 hard, funcs load |
| **V225** | _V12 | delete disabled `postBalanceWastePass` + `boostBatchVegForDailyTarget` (−366 lines) | runStandard(12) 0 hard, INV18 0 |
| **V226** | _V13 | **L8/L9/L10** + CLAUDE.md nits (comment/doc only) | funcs load |

**Final state validation:** `runStandard(25)` → **0 hard INV, 100% clean start, INV14 0, INV18 0** (INV6 ~23 tracking/structural, as documented). All pushed to `main` + version branches.

**Methodology note (logged):** during V222 a 20-seed back-to-back `randomizeWeek` loop falsely showed ~220 INV3/INV20 "fires" — the committed baseline showed the same, confirming it was cross-week carryover state pollution, not a regression. Lesson: validate with `MPStress.runStandard` (does `_clearAllState` + clean prime + INV26 guard). Matches existing memory `feedback_clear_localstorage_before_stress` + `feedback_dont_diagnose_from_stale_state`.

Audit Round 12 CLOSED.
