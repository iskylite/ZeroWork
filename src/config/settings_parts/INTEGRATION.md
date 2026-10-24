# T10 settings content integration

Use `settings_content_view.mountContent(cx, page_scope, &controller, hooks)` instead
of the generic key/section table in `SettingsHost.rebuildContent`. Content already
contains the original page padding, Chinese title/description, rows and footer.
Use a zero-padding content host. The modal is 840px wide, nav 190px; page heights
are exposed by `modal_heights` (600/700/690/600/716/600/600/600).

Create a child scope per content mount and dispose that scope when replacing the
page. The binding and click contexts register cleanup in that scope. Keep the
Controller alive across page switches. After switching, maintain its unsaved
owned draft. `changed` should rebuild content after discrete toggle/theme/weight
edits. Footer `action(.reset_defaults)` calls Controller.resetDefaults;
`action(.save)` invokes the existing host persistence path. They are distinct.

`request_edit(context, Key, anchor)` receives the clicked original chip/keyboard
cell. Supply the existing overlay stack with a picker anchored to that node.
Numeric chips must offer appropriate numeric choices/editors; shortcuts enter
recording at the existing chip; download_dir selects a directory. No extra
permanent row/button is needed. Mouse rows remain fixed and do not record.
The sliding-window control combines window_chunks and chunk_kb: edit both.

`read` and `edit` override the config binding for extended fields. The full
Chinese-label-to-key map is `settings_content_view.rows`. Existing fields read
Controller.model.value and edits go through Controller.editKey. Unavailable
fields currently show an em dash/off state, rather than false sample values.
Integrate real fields before claiming T10 complete. Completion.enabled is read
from the actual model but requires writer support (or hooks.edit).

The AI page requires `mount_providers(context,cx,scope)`. It must build the real
provider/model draft accordion using the original AI PNG row structure. Missing
this hook returns ProviderViewRequired; fabricated gateway/model/API-key values
are not rendered. The original sample provider functions are absent from the
production content module.

Data actions expose import_theme/export_logs/clear_logs/open_config_dir. Hook
read for data.config_dir to show the actual resolved directory. Clear logs must
use the existing intended destructive-operation confirmation behavior.

Tests live in src/settings_content_tests.zig. Add its import to the existing
src/transfer_panel_tests.zig aggregation to include it in zig build test-ui.
Independent build verified 31/31 tests, zero allocator leaks. Tests prove all
page branches mount, font value comes from edited draft, and a theme-card click
updates the controller. They do not prove screenshot pixel alignment or native
keyboard/picker/provider operations. The integrator must complete formal app
visual and operation-chain verification against eight original PNGs.
