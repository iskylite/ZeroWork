/// Per-frame redraw flag: markRenderDirty() in the on_before_render hook sets it, telling
/// Cx that active animations need rendering next frame.
///
/// Thread safety: main (UI) thread only; safe under the current single-threaded architecture.
/// Multi-threaded rendering would need an atomic or instance field.
pub var requested: bool = false;
