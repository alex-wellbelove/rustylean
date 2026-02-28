/-
  TestUnique: test cases for the compile-time uniqueness analysis.

  Compiling this file should produce warnings for `bad` (use-after-consume)
  but no warnings for `good` (clean single-use).
-/
import UniqueAnalysis

@[unique] opaque Database : Type
@[extern "db_open_stub"] opaque Database.open : String → IO Database
@[extern "db_close_stub"] opaque Database.close : Database → IO Unit

-- Should warn: use-after-consume (db is passed to Database.close twice)
def bad : IO Unit := do
  let db ← Database.open "test.db"
  let db2 := db              -- alias (optimized away by simp, but...)
  Database.close db2          -- first consume
  Database.close db           -- V2: use-after-consume

-- Should NOT warn: clean single-use
def good : IO Unit := do
  let db ← Database.open "test.db"
  Database.close db
