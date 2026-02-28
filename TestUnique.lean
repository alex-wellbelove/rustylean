/-
  TestUnique: test cases for the compile-time uniqueness analysis.

  Legend:
    T = true positive (should warn)
    N = true negative (should NOT warn)
    B = borderline — documents analysis behavior and known gaps

  Results (all passing as expected):
    T0 bad              — 1 warning ✓
    T1 useAfterClose    — 1 warning ✓
    T2 tripleClose      — 2 warnings ✓
    T3 sequentialConsume — 1 warning ✓
    T4 twoResources     — 1 warning (only db, not db2) ✓
    N0 good             — clean ✓
    N1 cleanSequential  — clean ✓
    N2 singleUseWithWork — clean ✓
    N3 immediateClose   — clean ✓
    N4 twoClean         — clean ✓
    B1 aliasKept        — clean (simp eliminates alias + each branch uses once)
    B2 indirect         — warns (simp inlines `let f := Database.close`)
    B3 higherOrder      — clean (opaque higher-order call, not visible)
    B4 borrowThenClose  — clean ✓ (@& correctly not treated as consume)
    B5 withErrorHandling — warns (false positive: branches share consumed state)
-/
import UniqueAnalysis

@[unique] opaque Database : Type
@[extern "db_open_stub"] opaque Database.open : String → IO Database
@[extern "db_close_stub"] opaque Database.close : Database → IO Unit
@[extern "db_query_stub"] opaque Database.query : @& Database → String → IO Unit
@[extern "db_query_owned_stub"] opaque Database.queryOwned : Database → String → IO Unit

-- ============================================================================
-- True positives: should warn
-- ============================================================================

-- T0: Original double-close
def bad : IO Unit := do
  let db ← Database.open "test.db"
  let db2 := db
  Database.close db2
  Database.close db

-- T1: Close then use with an owned (non-borrowed) function
def useAfterClose : IO Unit := do
  let db ← Database.open "test.db"
  Database.close db
  Database.queryOwned db "SELECT 1"

-- T2: Three consumers (should warn twice: second and third)
def tripleClose : IO Unit := do
  let db ← Database.open "test.db"
  Database.close db
  Database.close db
  Database.close db

-- T3: Consumed, then a different resource opens, then consumed again
def sequentialConsume : IO Unit := do
  let db ← Database.open "test.db"
  Database.close db
  let _db2 ← Database.open "other.db"
  Database.close db

-- T4: Two unique resources, only one double-closed
def twoResources : IO Unit := do
  let db ← Database.open "a.db"
  let db2 ← Database.open "b.db"
  Database.close db
  Database.close db2
  Database.close db

-- ============================================================================
-- True negatives: should NOT warn
-- ============================================================================

-- N0: Clean single-use
def good : IO Unit := do
  let db ← Database.open "test.db"
  Database.close db

-- N1: Sequential open/close of different resources
def cleanSequential : IO Unit := do
  let db ← Database.open "a.db"
  Database.close db
  let db2 ← Database.open "b.db"
  Database.close db2

-- N2: Single use with other IO in between
def singleUseWithWork : IO Unit := do
  let db ← Database.open "test.db"
  IO.println "doing stuff"
  IO.println "more stuff"
  Database.close db

-- N3: Create and immediately close
def immediateClose : IO Unit := do
  let db ← Database.open "test.db"
  Database.close db

-- N4: Multiple unique types, each used correctly
def twoClean : IO Unit := do
  let a ← Database.open "a.db"
  let b ← Database.open "b.db"
  Database.close a
  Database.close b

-- ============================================================================
-- Borderline: documents analysis behavior and known gaps
-- ============================================================================

-- B1: Alias with conditional — simp eliminates the alias, each branch
-- uses the resource once. Clean (no warning).
def aliasKept : IO Unit := do
  let db ← Database.open "test.db"
  let db2 := db
  if (← IO.rand 0 1) == 0 then
    Database.close db2
  else
    Database.close db

-- B2: Indirect call via fvar — simp inlines `let f := Database.close`
-- into direct calls, so warnings fire as expected.
def indirect : IO Unit := do
  let db ← Database.open "test.db"
  let f := Database.close
  f db
  f db

-- B3: Higher-order — passing close as a callback. The analysis doesn't
-- see inside `forM`, so no warning. Known gap.
def higherOrder : IO Unit := do
  let db ← Database.open "test.db"
  [db].forM Database.close

-- B4: Borrowed parameter — @& does NOT count as consume.
-- query uses @& so db is still unconsumed for close.
def borrowThenClose : IO Unit := do
  let db ← Database.open "test.db"
  Database.query db "SELECT 1"
  Database.close db

-- B5: Error handling — same resource closed in catch and try branches.
-- Currently warns (false positive) because the analysis doesn't track
-- that try/catch branches are mutually exclusive.
def withErrorHandling : IO Unit := do
  let db ← Database.open "test.db"
  try
    Database.close db
  catch _ =>
    Database.close db
