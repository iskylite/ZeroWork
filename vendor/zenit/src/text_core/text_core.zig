/// text_core: generic text data structure layer
///
/// Language-agnostic, editor-agnostic pure algorithm library:
/// PieceTable / PieceTree / SumTree / FenwickTree / WrapMap / DocCursor / Anchor / Clock / Point
///
/// Text input controls (Input/Textarea) in any GUI framework can be built on these
/// primitives without LSP / tree-sitter / language intelligence.
const std = @import("std");

// Core data structures
pub const PieceTable = @import("piece_table.zig").PieceTable;
pub const Piece = @import("piece_table.zig").Piece;
pub const Source = @import("piece_table.zig").Source;

pub const UndoStack = @import("undo_stack.zig").UndoStack;
pub const Operation = @import("undo_stack.zig").Operation;
pub const OpType = @import("undo_stack.zig").OpType;

// PieceTree - high-performance text storage based on SumTree
pub const PieceTree = @import("piece_tree.zig").PieceTree;
pub const PieceTreeSnapshot = @import("piece_tree.zig").PieceTreeSnapshot;
pub const TreePiece = @import("piece_tree.zig").TreePiece;
pub const PieceSummary = @import("piece_tree.zig").PieceSummary;
pub const ChunkIterator = @import("piece_tree.zig").ChunkIterator;

pub const piece_stats = @import("piece_stats.zig");

/// UTF-8 validation (only copy in repo, replaces prior scattered duplicate implementations)
pub const utf8 = @import("utf8.zig");
pub const PieceTextStats = piece_stats.TextStats;

// SumTree - generic B-Tree index structure
const sum_tree_mod = @import("sum_tree.zig");
pub const sum_tree = sum_tree_mod;
pub const SumTree = sum_tree_mod.SumTree;
pub const TextSumTree = sum_tree_mod.TextSumTree;
pub const TextSummary = sum_tree_mod.TextSummary;
pub const TextChunk = sum_tree_mod.TextChunk;
pub const ByteDim = sum_tree_mod.ByteDim;
pub const LineDim = sum_tree_mod.LineDim;

// FenwickTree
pub const FenwickTree = @import("fenwick_tree.zig").FenwickTree;
pub const prepared_wrap_line = @import("prepared_wrap_line.zig");
pub const PreparedWrapLine = prepared_wrap_line.PreparedWrapLine;

// WrapMap, generic soft wrap mapping
pub const wrap_map = @import("wrap_map.zig");
pub const WrapMap = wrap_map.WrapMap;
pub const MeasureFn = wrap_map.MeasureFn;
pub const WrapEntry = wrap_map.WrapEntry;
pub const DisplayLineInfo = wrap_map.DisplayLineInfo;
pub const DisplayPoint = wrap_map.DisplayPoint;
pub const BufferLineRange = wrap_map.BufferLineRange;

// Generic document cursor
// Grapheme cluster boundaries (UAX #29)
pub const grapheme = @import("grapheme.zig");
pub const text_coordinate_corpus = @import("text_coordinate_corpus.zig");
pub const text_coordinates = @import("text_coordinates.zig");
pub const ByteOffset = text_coordinates.ByteOffset;
pub const GraphemeIndex = text_coordinates.GraphemeIndex;
pub const LineIndex = text_coordinates.LineIndex;
pub const TextPosition = text_coordinates.TextPosition;
pub const Affinity = text_coordinates.Affinity;
pub const BoundaryBias = text_coordinates.BoundaryBias;
pub const VisualLine = text_coordinates.VisualLine;
pub const OwnedVisualLine = text_coordinates.OwnedVisualLine;

pub const cursor = @import("cursor.zig");
pub const DocCursor = cursor.DocCursor;
pub const LineCol = cursor.LineCol;

// Scaffolding primitives
pub const clock = @import("clock.zig");
pub const LocalClock = clock.LocalClock;
pub const Global = clock.Global;
pub const EditTimestamp = clock.EditTimestamp;

pub const anchor = @import("anchor.zig");
pub const Anchor = anchor.Anchor;
pub const Bias = anchor.Bias;

pub const point = @import("point.zig");
pub const Point = point.Point;
pub const PointUtf16 = point.PointUtf16;
pub const OffsetUtf16 = point.OffsetUtf16;

pub const unclipped = @import("unclipped.zig");
pub const Unclipped = unclipped.Unclipped;

pub const dimensions = @import("dimensions.zig");

test {
    std.testing.refAllDecls(@This());
    // refAllDecls does not guarantee recursive collection of tests in submodules; explicit
    // reference is required
    _ = @import("utf8.zig");
}
