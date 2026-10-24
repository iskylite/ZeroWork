# Signal-first component props

Component props normalize literals and reactive sources through `ui.props.coerce`.
Use `Source(T)` for a value the component reads and `Model(T)` for a value the
user can change. Signals and memos must be mutable pointers because reading can
register reactive dependencies. Keep their owning scope alive while mounted.

## Read-only values

`Source(T)` accepts a literal, `*Signal(T)`, `*Memo(T)` or a derived value such as
`ui.not(loading)` and `ui.map(count, transform)`. It follows the source without
writing back. An optional value uses `Source(?T)`, rather than `?Source(T)`.

## Controlled values

| Input to `Model(T)` | Ownership and behavior |
|---|---|
| Literal | Component-local state |
| `*Signal(T)` | Interaction writes to the caller's signal |
| `ui.split(read, on_write)` | Interaction proposes a value; the caller decides what the source becomes |
| Memo, derived value or `Source(T)` | Parent-controlled display; no automatic write-back |

A read-only input with `on_<prop>_change` is normalized into split behavior.
For a component with one model prop, `on_change` also serves this purpose.
Without a change handler, a read-only model continues to display its source.
The view follows the value the source actually accepted, including transformed
or rejected proposals. Callbacks on bound signals report the resulting value.

## Validation

Unknown props, missing required props, mismatched source value types, const
reactive pointers and `ui.split` on a read-only prop produce compile errors.
`bash scripts/check_compile_errors.sh` verifies these diagnostics. Positive
coercion and controlled read-only cases are covered by the reactive unit tests
in `src/ui/reactive/props.zig` and `src/ui/reactive/source.zig`.
