# General Instructions

These instructions apply to this project AND any projects that use this as a dependency.

## Code

- Save all code with LF line endings. For Zig files, this should usually happen by running `zig fmt`.
- Memory allocations and lifetimes are important. Always think about them, and try to group allocations into related/existing lifetimes. Use temporary arenas whenever possible, ideally using the getTempArena pattern from zigkm. Avoid general-purpose allocation.
- Prioritize making "error" states impossible via type checking. If this is not possible, prefer assertions for "error" states over early returns. Make unexpected conditions fail loudly.
- Avoid unions and type-based switches when ordinary data plus indexing can express the distinction. Add specialized representations only when the underlying behavior is genuinely different.
- Optimize for reading code in execution order. Long cohesive functions are preferable to many small helpers. Extract a helper when it has AT LEAST two or three real call sites or isolates a genuinely independent operation.
- Prefer direct arrays, loops, and explicit intermediate structures over wrapper-heavy APIs. Compile-time generation is useful when it eliminates duplicated declarations and keeps one source of truth.
- Put reusable mathematical operations in zigkm's math.zig. If the function is nontrivial, you can also write math-focused tests there, but don't overdo test code.

## Build & Validation

- On Windows, invoke Zig build commands directly as `C:\Users\jmric\zig.exe ...`. Do not use PowerShell’s `&` call operator or another shell wrapper, so the global command rule matches.
- In zigkm web app repositories (Zig built as WASM), use `zig build server_build`. A plain `zig build` is not sufficient validation for browser-facing changes because it does not update the server artifacts used on refresh.
- Keep code linted with `zig fmt`.
