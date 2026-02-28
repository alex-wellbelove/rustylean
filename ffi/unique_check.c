#include <lean/lean.h>

/*
 * Check if a Lean object is exclusively referenced (RC == 1).
 *
 * Uses b_lean_obj_arg (borrowed) so calling this function does NOT
 * increment the refcount — we see the true RC from the caller's perspective.
 *
 * Note: Even though the Lean signature is `BaseIO Bool`, the @[extern]
 * convention expects the raw return type. The compiler auto-generates
 * a wrapper that handles the IO plumbing.
 */
LEAN_EXPORT uint8_t lean_unique_check_is_exclusive(b_lean_obj_arg obj) {
    if (lean_is_scalar(obj)) return 1;
    return lean_is_exclusive(obj);
}
