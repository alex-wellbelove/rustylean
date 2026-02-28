# Static Uniqueness Analysis for Lean 4: Problem Statement & Implementation Approaches

## Problem Statement

Lean 4 is a dependently-typed functional programming language and theorem prover. It uses reference counting for memory management, with a key optimization: when a value's reference count is 1 (i.e., it is "uniquely referenced"), the runtime can mutate it in place rather than copying. This is critical for performance — an array update goes from O(n) (copy) to O(1) (mutate) when the array is unique.

However, Lean provides **no compile-time guarantee** of uniqueness. If a programmer accidentally aliases a value, the code silently falls back to copying. Worse, for FFI (Foreign Function Interface) code wrapping C resources like sockets or database handles, aliasing can cause use-after-free bugs that segfault with no context.

### The Goal

Build a **lint-style static analysis tool** for Lean 4 that:

1. Allows types to be annotated as `@[unique]` (e.g., FFI resource handles like sockets, database connections)
2. Tracks where values of those types flow through the program
3. Warns when a `@[unique]` value is provably aliased at a program point where uniqueness is required

This is NOT full linear types or a borrow checker. It is a conservative, opt-in analysis that catches the most common bugs. False positives (spurious warnings) are acceptable; false negatives (missed bugs) should be minimized.

### Motivating Example

```lean
-- FFI binding to libsqlite
opaque Database : Type

@[extern "sqlite3_open"]
opaque Database.open : String → IO Database

@[extern "sqlite3_close"]
opaque Database.close : Database → IO Unit

-- BUG: use after free
def bad : IO Unit := do
  let db ← Database.open "test.db"
  let db2 := db              -- aliased! refcount is now 2
  Database.close db2          -- closes the underlying resource
  Database.close db           -- use-after-free, segfault
```

The analysis should warn that `db` is aliased at line 4, and that `db` is used after `db2` (which shares the same underlying resource) is passed to a consuming function.

### Desired output

```
warning: uniqueness violation in `bad`
  `db` (type: Database, marked @[unique]) is aliased at line 4
  `db` is used at line 6 after alias `db2` is consumed at line 5
```

## Background

### Lean 4 Compilation Pipeline

Lean compiles code through several stages:

```
Surface Lean → Elaboration → Core → LCNF → RC-inserted IR → C code
```

- **Surface Lean**: What the programmer writes
- **Core**: Fully elaborated, dependently-typed terms
- **LCNF** (Lean Compiler Normal Form): A-normal form IR where every intermediate value has a name. Types are still available but simplified. This is where most compiler optimizations happen.
- **RC-inserted IR**: LCNF with explicit `inc`/`dec` reference counting operations, plus `reset`/`reuse` for destructive update optimization
- **C code**: Final output

The best level to operate at is **LCNF**, because:
- Types are still available (so we can identify `@[unique]` types)
- Code is in A-normal form (every value is named, no nested expressions)
- It's before RC insertion (so we're reasoning about aliasing, not low-level refcount ops)

### LCNF Structure (Simplified)

LCNF code consists of:
- `let x := f args` — function application, result bound to `x`
- `let x := Constructor args` — constructor application
- `let x := proj_i y` — field projection from `y`
- `cases x of | C₁ args => body₁ | C₂ args => body₂` — pattern matching
- `return x` — return a value
- `fun params => body` — function/closure (join points)

Key properties:
- Every value is explicitly named (A-normal form)
- Parameters can be marked as **borrowed** (`@&`), meaning the function only reads the value and doesn't consume or store it
- The compiler already tracks whether parameters are borrowed for RC optimization purposes

### Prior Work

Marc Huisinga's master thesis, "Static Uniqueness Analysis for the Lean 4 Theorem Prover" (KIT, 2023, supervised by Sebastian Ullrich — a core Lean 4 developer), designed a uniqueness type system targeting a model of Lean's IR. Key findings:

- **Uniqueness types** (from Clean) are more appropriate than linear types for this use case. Linear types say "use exactly once"; uniqueness says "no other references exist right now." A value can be unique and later become shared.
- The thesis supports uniqueness types, borrowing, escape analysis, and subtyping between unique and shared types
- **Not implemented in Lean proper** — remains a thesis. Key unsolved problems include type inference, polymorphism, higher-order functions, and soundness proof.
- Paper: https://pp.ipd.kit.edu/uploads/publikationen/huisinga23masterarbeit.pdf

### Existing Lean Runtime Facilities

Lean already has runtime uniqueness checking:
- `dbgTraceIfShared : String → α → α` — prints a message if the value's refcount > 1
- `isExclusiveUnsafe` — low-level primitive that checks if refcount is 1 (marked `unsafe`)
- The array destructive update optimization already uses runtime refcount checks to decide between mutation and copying

### Existing Tooling

- **lean-souffle** (https://github.com/ydewit/lean-souffle): Exports Lean's LCNF AST as Datalog facts for analysis with the Soufflé Datalog engine. Exports `Lean.Expr`, namespaces, modules, and `Lean.Compiler.LCNF.Decl`.

## Implementation Approach A: Lean Compiler Plugin (Direct LCNF Analysis)

### Overview

Write a Lean metaprogram or compiler plugin that hooks into the LCNF pipeline, walks the IR, and tracks uniqueness-marked values through the program.

### Architecture

```
Surface Lean
  ↓ (elaboration)
LCNF
  ↓ (your analysis pass runs here)
  ↓ → warnings emitted
RC-inserted IR
  ↓
C code
```

### Implementation Steps

1. **Define the `@[unique]` attribute** for types wrapping FFI resources:
```lean
-- Register a new attribute
register_option uniqueType : Bool := {
  defValue := false
  descr := "Mark this type as requiring uniqueness"
}

-- Usage:
@[unique]
opaque Socket : Type
```

2. **Write an LCNF pass** that:
   - Scans for variables whose type is marked `@[unique]`
   - Tracks the "alias set" for each unique variable — all variables that refer to the same underlying value
   - At each program point, counts how many live variables are in each alias set
   - Warns when the count exceeds 1 at a point where a consuming (non-borrowed) use occurs

3. **Alias tracking rules for LCNF constructs:**
   - `let y := x` where `x` is unique → `y` joins `x`'s alias set. Both are live. **WARN** if `x` is used after this point.
   - `let r := f x` where parameter is `@&` (borrowed) → `x` is temporarily borrowed, alias set unchanged, fine.
   - `let r := f x` where parameter is owned → `x` is consumed. Remove from alias set. **WARN** if `x` is used after this point.
   - `return x` where `x` is unique → `x` escapes. Depending on context, this may be fine (returning from a factory) or bad (returning from a `withResource` callback).
   - `let closure := fun ... => ... x ...` where `x` is unique and captured → **WARN**, `x` escapes into closure.
   - `let s := Constructor ... x ...` where `x` is unique → **WARN**, `x` is stored into a structure.

4. **Handling function boundaries (interprocedural analysis):**
   - **Conservative approach (recommended for MVP):** If a unique value is passed to a function with a non-borrowed parameter, assume it escapes. If the parameter is borrowed (`@&`), assume it doesn't escape.
   - **More precise (future work):** Analyze callee bodies to determine if they actually store/alias the parameter.

5. **Integration point:** The pass should run after LCNF is generated but before RC insertion. Look at `Lean.Compiler.LCNF` module and the existing pass infrastructure.

### Advantages
- Integrated into the Lean build — warnings appear alongside other compiler output
- Can access full LCNF type information directly
- Could eventually be upstreamed as a compiler feature
- Results could show in VS Code via the Lean language server

### Disadvantages
- Requires deep understanding of Lean compiler internals
- LCNF APIs are internal and may change between Lean versions
- More complex implementation than the Datalog approach
- Harder to iterate on the analysis rules (they're embedded in Lean code)

## Implementation Approach B: Soufflé Datalog Analysis

### Overview

Export LCNF as relational facts, write the alias/escape analysis as Datalog rules, and query for violations. Uses the existing `lean-souffle` project as a starting point.

### Architecture

```
Surface Lean
  ↓ (elaboration + compilation)
LCNF
  ↓ (lean-souffle fact export, extended)
Datalog facts (.facts files)
  ↓ (Soufflé engine)
Analysis results (violation.csv)
  ↓ (reporting script)
Human-readable warnings
```

### Fact Schema

The following relations need to be exported from LCNF. Some may already exist in lean-souffle; others would need to be added.

```prolog
// ===== Type information =====

// Type t is marked @[unique]
.decl unique_type(t: symbol)

// Variable x in function f has type t  
.decl var_type(func: symbol, var: symbol, typ: symbol)

// ===== Control flow =====

// Program point p1 comes before p2 in function f
.decl before(func: symbol, p1: number, p2: number)

// Program point p is in the scope of cases branch b
.decl in_branch(func: symbol, point: number, branch: symbol)

// ===== Variable definitions and uses =====

// Variable x is defined at program point p in function f
.decl defined_at(func: symbol, var: symbol, point: number)

// Variable x is used at program point p in function f
.decl used_at(func: symbol, var: symbol, point: number)

// Variable x is live at program point p (can be derived)
.decl live_at(func: symbol, var: symbol, point: number)

// ===== Data flow =====

// Direct assignment: let y := x
.decl assigns(func: symbol, target: symbol, source: symbol, point: number)

// Function call: let result := callee(args...) at point p
// arg_var is passed at parameter position n
.decl call(func: symbol, call_site: number, callee: symbol, result: symbol)
.decl call_arg(func: symbol, call_site: number, position: number, arg_var: symbol)

// Parameter n of function g is borrowed (@&)  
.decl borrowed_param(callee: symbol, position: number)

// Variable x is captured by a closure created at point p
.decl captured_by_closure(func: symbol, var: symbol, closure_point: number)

// Variable x is stored into a constructor/structure at point p
.decl stored_into(func: symbol, var: symbol, point: number)

// Variable x is returned from function f
.decl returned(func: symbol, var: symbol, point: number)

// Variable x is projected from y (let x := proj_i y)
.decl projected_from(func: symbol, target: symbol, source: symbol, point: number)

// ===== Source location mapping =====

// Program point p in function f corresponds to source file/line/col
.decl source_loc(func: symbol, point: number, file: symbol, line: number, col: number)
```

### Analysis Rules

```prolog
// ===== Derived: unique variables =====

.decl unique_var(func: symbol, var: symbol)
unique_var(f, x) :- var_type(f, x, t), unique_type(t).

// ===== Alias analysis =====

// Direct alias: y is an alias of x
.decl aliases(func: symbol, var1: symbol, var2: symbol)
aliases(f, y, x) :- assigns(f, y, x, _), unique_var(f, x).
aliases(f, x, y) :- aliases(f, y, x).  // symmetric
aliases(f, x, z) :- aliases(f, x, y), aliases(f, y, z).  // transitive

// ===== Escape analysis =====

// Variable x escapes at point p (consumed by non-borrowing call)
.decl consumed_at(func: symbol, var: symbol, point: number)
consumed_at(f, x, p) :-
    unique_var(f, x),
    call_arg(f, p, n, x),
    call(f, p, callee, _),
    !borrowed_param(callee, n).

// Variable x escapes into a closure
.decl escapes_to_closure(func: symbol, var: symbol, point: number)
escapes_to_closure(f, x, p) :-
    unique_var(f, x),
    captured_by_closure(f, x, p).

// Variable x escapes into a data structure
.decl escapes_to_struct(func: symbol, var: symbol, point: number)
escapes_to_struct(f, x, p) :-
    unique_var(f, x),
    stored_into(f, x, p).

// ===== VIOLATIONS =====

// V1: Unique variable is aliased (two live references)
.decl violation_aliased(func: symbol, var: symbol, alias: symbol, point: number)
.output violation_aliased
violation_aliased(f, x, y, p) :-
    aliases(f, x, y),
    x != y,
    used_at(f, x, p),
    used_at(f, y, p2),
    live_at(f, x, p),
    live_at(f, y, p).

// V2: Unique variable used after being consumed
.decl violation_use_after_consume(func: symbol, var: symbol, use_point: number, consume_point: number)
.output violation_use_after_consume
violation_use_after_consume(f, x, p_use, p_consume) :-
    unique_var(f, x),
    consumed_at(f, x, p_consume),
    used_at(f, x, p_use),
    before(f, p_consume, p_use).

// V3: Alias of unique variable used after original is consumed  
.decl violation_alias_use_after_consume(func: symbol, var: symbol, alias: symbol, use_point: number, consume_point: number)
.output violation_alias_use_after_consume
violation_alias_use_after_consume(f, x, y, p_use, p_consume) :-
    aliases(f, x, y),
    x != y,
    consumed_at(f, y, p_consume),
    used_at(f, x, p_use),
    before(f, p_consume, p_use).

// V4: Unique variable escapes into closure
.decl violation_closure_escape(func: symbol, var: symbol, point: number)
.output violation_closure_escape
violation_closure_escape(f, x, p) :-
    escapes_to_closure(f, x, p).

// V5: Unique variable stored into structure  
.decl violation_struct_escape(func: symbol, var: symbol, point: number)
.output violation_struct_escape
violation_struct_escape(f, x, p) :-
    escapes_to_struct(f, x, p).
```

### Workflow

```bash
# 1. Build the project (lean-souffle exports facts during compilation)
lake build

# 2. Run the uniqueness analysis  
souffle -F ./facts -D ./results uniqueness.dl

# 3. Check for violations
cat ./results/violation_use_after_consume.csv
cat ./results/violation_aliased.csv

# Or: a wrapper script that formats results with source locations
python3 format_warnings.py ./results ./facts/source_loc.facts
```

### Advantages
- Datalog is purpose-built for program analysis (alias analysis, points-to analysis, escape analysis are classic Datalog applications)
- Fixpoint computation is handled automatically by Soufflé
- Rules are declarative and easy to iterate on — changing the analysis means editing a .dl file, not recompiling a Lean plugin
- Soufflé compiles Datalog to C++ and is very fast, even for whole-program analysis
- Lower barrier to entry — don't need to understand Lean compiler internals deeply
- lean-souffle already exists as a starting point for fact export

### Disadvantages
- Offline tool — not integrated into the IDE or build process (without additional wrapping)
- Mapping LCNF program points back to source locations requires extra plumbing
- The fact export schema from lean-souffle may need significant extension
- Two-language solution (Lean for fact export, Datalog for analysis)
- Soufflé is an additional dependency

## The Runtime Fallback

Regardless of which static approach is chosen, a runtime check provides immediate value today with minimal implementation effort:

```lean
/-- Check that a value is uniquely referenced. Panic if not. -/
@[inline] def ensureExclusive (label : String) (a : @& α) : IO Unit := do
  if !isExclusive a then
    throw (IO.Error.userError s!"uniqueness violation: {label} is aliased (refcount > 1)")

/-- Safe resource bracket pattern -/
def withSocket (addr : String) (f : Socket → IO α) : IO α := do
  let sock ← Socket.open addr
  let result ← f sock
  ensureExclusive "socket" sock  -- catch smuggling
  Socket.rawClose sock
  pure result
```

This catches violations at runtime rather than compile time, but turns silent segfaults into loud errors with context. It composes well with either static approach as a defense-in-depth measure.

## Recommended Implementation Order

1. **Runtime `ensureExclusive`** — implementable in an afternoon, immediately useful
2. **Soufflé-based analysis MVP** — extend lean-souffle fact export, write initial Datalog rules, get basic violation detection working on simple examples
3. **Iterate on rules** — handle more LCNF constructs, reduce false positives
4. **Compiler plugin version** — if the approach proves valuable, reimplement as a Lean compiler pass for better integration and IDE support

## Key Resources

- Huisinga thesis: https://pp.ipd.kit.edu/uploads/publikationen/huisinga23masterarbeit.pdf
- lean-souffle: https://github.com/ydewit/lean-souffle
- Lean LCNF source: https://github.com/leanprover/lean4 (src/Lean/Compiler/LCNF/)
- Lean LCNF docs: https://leanprover-community.github.io/mathlib4_docs/Lean/Compiler/LCNF.html
- Perceus RC paper: "Counting Immutable Beans: Reference Counting Optimized for Purely Functional Programming" (Ullrich & de Moura, 2019)
- LCNF Param type includes `borrow : Bool` field — this is how borrowed parameters are tracked in the actual IR
- Lorenzen thesis on Perceus borrowing: https://antonlorenzen.de/master_thesis_perceus_borrowing.pdf

## Example: What a Full Analysis Looks Like

Given this Lean code:

```lean
@[unique]
opaque Database : Type

def problematic : IO Unit := do
  let db ← Database.open "test.db"    -- point 1: db defined, unique
  let handle := db                      -- point 2: handle aliases db  
  doSomethingWith handle                -- point 3: handle consumed (non-borrowed)
  Database.close db                     -- point 4: db used after alias consumed
                                        -- VIOLATION: db's resource may be invalid
```

Expected facts:
```
unique_type("Database").
var_type("problematic", "db", "Database").
var_type("problematic", "handle", "Database").
defined_at("problematic", "db", 1).
assigns("problematic", "handle", "db", 2).
call_arg("problematic", 3, 0, "handle").
call_arg("problematic", 4, 0, "db").
before("problematic", 1, 2).
before("problematic", 2, 3).
before("problematic", 3, 4).
```

Expected violations:
```
violation_aliased("problematic", "db", "handle", 2).
violation_alias_use_after_consume("problematic", "db", "handle", 4, 3).
```
