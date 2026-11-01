//! Shared admission budget for every forwarding entry point.
// At 32 KiB of payload buffers per client, one listener retains at most 8 MiB.
pub const max_connections: u32 = 256;

pub fn validConnections(value: u32) bool {
    return value > 0 and value <= max_connections;
}
