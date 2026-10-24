//! Automation instrumentation is a build-time choice, never a user setting.
const builtin = @import("builtin");
const root = @import("root");
pub const automation = builtin.is_test or (@hasDecl(root, "application_test_mode") and root.application_test_mode);
