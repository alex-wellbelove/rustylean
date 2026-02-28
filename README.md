# UniqueCheck — Uniqueness Checking for Lean 4

Lean 4 has no compile-time uniqueness guarantees. FFI resource handles (sockets, DB connections) can be silently aliased, leading to use-after-free segfaults. This project provides both **compile-time** and **runtime** defenses against uniqueness violations.

## The Problem

```lean
opaque Database : Type

def bad : IO Unit := do
  let db ← Database.open "test.db"
  let db2 := db              -- aliased! refcount is now 2
  Database.close db2          -- closes the underlying resource
  Database.close db           -- use-after-free → segfault
```

## Compile-Time Analysis (`UniqueAnalysis`)

Mark types with `@[unique]` and get compile-time warnings when uniqueness is violated:

```lean
import UniqueAnalysis

@[unique] opaque Database : Type
@[extern "db_open"] opaque Database.open : String → IO Database
@[extern "db_close"] opaque Database.close : Database → IO Unit

def bad : IO Unit := do
  let db ← Database.open "test.db"
  let db2 := db
  Database.close db2
  Database.close db    -- ⚠ use-after-consume: already consumed by Database.close
```

The analysis works as a native LCNF compiler pass (registered via `@[cpass]`). It runs after the first `simp` pass, when monadic bind has been inlined into flat `cases` on `EST.Out`, and detects when the same variable is passed to a unique-consuming parameter position more than once.

Key design insight: LCNF erases types to `lcAny`, so the pass looks up each callee's **original** type from the environment to determine which parameter positions expect `@[unique]` types.

## Runtime Checking (`UniqueCheck`)

### `ensureExclusive` — panic if aliased

```lean
let resource ← acquire
let resource ← ensureExclusive "resource" resource  -- throws if RC > 1
use resource
```

### `withResource` — bracket pattern catches smuggling

```lean
withResource
  (acquire := Socket.open addr)
  (release := Socket.close)
  (label := "socket")
  (action := fun sock => do
    -- if you try to smuggle `sock` out via IORef, withResource catches it
    sendData sock payload
    pure result)
```

## API

| Function | Type | Description |
|---|---|---|
| `isExclusiveFFI` | `@& α → BaseIO Bool` | Core FFI primitive — checks if RC == 1 |
| `ensureExclusive` | `String → @& α → IO α` | Throws `IO.Error` if value is aliased |
| `assertExclusive` | `String → @& α → IO α` | Alias for `ensureExclusive` |
| `withResource` | `IO α → (α → IO Unit) → String → (α → IO β) → IO β` | Bracket pattern with smuggling detection |

## How It Works

The core primitive is a C FFI shim that uses `b_lean_obj_arg` (Lean's borrowed parameter convention) to check the reference count **without incrementing it**:

```c
LEAN_EXPORT uint8_t lean_unique_check_is_exclusive(b_lean_obj_arg obj) {
    if (lean_is_scalar(obj)) return 1;
    return lean_is_exclusive(obj);
}
```

Key design decisions:
- **Borrowed parameter** (`@&` / `b_lean_obj_arg`): An owned parameter would bump RC, making the check always fail for unique values
- **`BaseIO Bool` return type**: A pure `Bool` return would let the compiler CSE multiple calls — the refcount is mutable state that changes between checks
- **Dynamic allocation**: Values must be allocated at runtime (e.g., in `IO`); compile-time constants have a special RC that is never exclusive

## Building

Requires [Lean 4.28.0](https://github.com/leanprover/lean4/releases/tag/v4.28.0) (see `lean-toolchain`).

```bash
lake build
.lake/build/bin/demo
```

## Demo Output

```
--- Demo 1: ensureExclusive (unique value) ---
  pass: #[1, 2, 3]

--- Demo 2: ensureExclusive (aliased value) ---
  caught: uniqueness violation: `y` is aliased (refcount > 1)

--- Demo 3: withResource (smuggling detected) ---
  caught: uniqueness violation: `resource` was smuggled out of withResource

--- Demo 4: withResource (clean usage) ---
  released #[10, 11, 12]
  result: sum = 33
```

## Architecture

| File | Purpose |
|---|---|
| `UniqueAttr.lean` | Registers the `@[unique]` tag attribute |
| `UniqueAnalysis.lean` | LCNF compiler pass — detects use-after-consume at compile time |
| `UniqueCheck.lean` | Runtime library — `ensureExclusive`, `withResource` |
| `ffi/unique_check.c` | C shim for runtime RC check via `b_lean_obj_arg` |
| `TestUnique.lean` | Compile-time analysis test cases |
| `Main.lean` | Runtime checking demos |

## Context

See [`problem_statement.md`](problem_statement.md) for the full roadmap.
