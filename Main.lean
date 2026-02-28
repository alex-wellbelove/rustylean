import UniqueCheck

/-- Build an array dynamically (in IO) to prevent compile-time constant folding.
    Persistent (constant-folded) objects have a special RC that is never exclusive. -/
def mkDynArray (vals : List Nat) : IO (Array Nat) := do
  let mut arr := Array.mkEmpty vals.length
  for v in vals do
    arr := arr.push v
  pure arr

-- ============================================================================
-- Demo 1: ensureExclusive — passing case (unique value)
-- ============================================================================

def demo1 : IO Unit := do
  IO.println "--- Demo 1: ensureExclusive (unique value) ---"
  let x ← mkDynArray [1, 2, 3]
  let x ← ensureExclusive "x" x
  IO.println s!"  pass: {x}"

-- ============================================================================
-- Demo 2: ensureExclusive — failing case (aliased value)
-- ============================================================================

def demo2 : IO Unit := do
  IO.println "--- Demo 2: ensureExclusive (aliased value) ---"
  let y ← mkDynArray [4, 5, 6]
  -- Store alias in IORef so the compiler can't optimize it away
  let aliasRef ← IO.mkRef y
  let y ← ensureExclusive "y" y
  IO.println s!"  BUG — should not reach: {y}"
  let z ← aliasRef.get
  IO.println s!"  (alias was: {z})"

-- ============================================================================
-- Demo 3: withResource — bracket pattern catches smuggling
-- ============================================================================

def demo3 : IO Unit := do
  IO.println "--- Demo 3: withResource (smuggling detected) ---"
  let smuggled ← IO.mkRef (none : Option (Array Nat))
  let result ← withResource
    (acquire := mkDynArray [7, 8, 9])
    (release := fun _ => IO.println "  released (should NOT happen)")
    (label := "resource")
    (action := fun resource => do
      smuggled.set (some resource)
      pure "done")
  -- Use smuggled after withResource so the compiler keeps the IORef alive
  -- during the call (otherwise it moves the ref into the closure, and when
  -- the closure is freed the IORef+resource get freed before the check)
  let s ← smuggled.get
  IO.println s!"  result: {result}, smuggled: {s}"

-- ============================================================================
-- Demo 4: withResource — passing case (no smuggling)
-- ============================================================================

def demo4 : IO Unit := do
  IO.println "--- Demo 4: withResource (clean usage) ---"
  let result ← withResource
    (acquire := mkDynArray [10, 11, 12])
    (release := fun r => IO.println s!"  released {r}")
    (label := "resource")
    (action := fun resource => do
      pure s!"sum = {resource.foldl (· + ·) 0}")
  IO.println s!"  result: {result}"

def main : IO Unit := do
  demo1
  IO.println ""
  try demo2
  catch e => IO.println s!"  caught: {e}"
  IO.println ""
  try demo3
  catch e => IO.println s!"  caught: {e}"
  IO.println ""
  demo4
