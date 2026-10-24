//! Compatibility import for existing application callers. The SFTP provider
//! owns all native resources, controllers and independent file composition.
const provider = @import("../plugins/sftp/provider_host.zig");
pub const Host = provider.Host;
pub const TransferHandler = provider.TransferHandler;
