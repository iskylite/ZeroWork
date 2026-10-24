// UI Automation reads only these owned snapshots, never the mutable Zig tree.
// Input is a parent-before-child projection. Element IDs retain Zig generations.
#pragma once
#include <windows.h>
#include <stdint.h>
#include <stdlib.h>
#include <math.h>
#include "accessibility_bridge.h"

namespace zenit_a11y {
// Why the last Snapshot::create on this thread failed (diagnostics only).
// Reset on every create; node is SIZE_MAX when the failure is not per node.
inline thread_local int last_reject_line = 0;
inline thread_local const char *last_reject_reason = "";
inline thread_local size_t last_reject_node = SIZE_MAX;
inline thread_local unsigned last_reject_role = 0;
constexpr uint32_t no_parent = UINT32_MAX;
constexpr size_t max_nodes = 4096, max_string_bytes = 8 * 1024 * 1024;
constexpr uint32_t secure_state = 1u << 17;
constexpr size_t max_geometry_segments = 65536, max_geometry_bytes = 8 * 1024 * 1024;
using Text = ZenitA11yText;
using InputNode = ZenitA11yNode;
struct Viewport { double x = 0, y = 0, width = 0, height = 0, scale = 1; };
struct Node {
    uint32_t id, parent_index, state;
    uint16_t role;
    uint8_t actions, setters;
    bool numeric;
    float x, y, width, height;
    double value_now, value_min, value_max, small_change, large_change;
    const wchar_t *name, *description, *value, *identifier;
    uint32_t *characters; size_t character_count;
    uint32_t *words, *paragraphs, *lines; size_t word_count, paragraph_count, line_count;
    bool editable, can_set_selection, uniform_format, can_scroll;
    uint32_t text_length, selection_start, selection_end, caret, visible_start, visible_end; // UTF-16 units.
    bool geometry_ready;
    ZenitA11yGeometrySegment *geometry; size_t geometry_count;
    bool carets_ready;
    ZenitA11yCaretCandidate *carets; size_t caret_count;
    bool rows_ready;
    ZenitA11yGeometrySegment *rows; size_t row_count;

};
struct Index { uint32_t id, index; };
class Snapshot final {
    volatile LONG refs = 1;
    Node *nodes_ = nullptr;
    Index *index_ = nullptr;
    size_t count_ = 0;
    struct GeometryOffset { uint32_t byte; size_t endpoint; };
    static int compare_geometry_offset(const void *a, const void *b) {
        uint32_t x = ((const GeometryOffset *)a)->byte, y = ((const GeometryOffset *)b)->byte;
        return x < y ? -1 : x > y ? 1 : 0;
    }
    static bool copy_segments(const InputNode &in, const ZenitA11yGeometry &source, bool ready, bool allow_empty,
        ZenitA11yGeometrySegment *&output, size_t &output_count, size_t &budget) {
        const size_t count = source.count;
        if (!ready) return count == 0;
        if (!count) return true;
        if (!source.segments || count > max_geometry_segments ||
            count > (max_geometry_bytes-budget)/sizeof(ZenitA11yGeometrySegment)) return false;
        auto *offsets = (GeometryOffset *)malloc(2*count*sizeof(GeometryOffset));
        output = (ZenitA11yGeometrySegment *)malloc(count*sizeof(ZenitA11yGeometrySegment));
        if (!offsets || !output) { free(offsets); return false; }
        output_count = count; budget += count*sizeof(ZenitA11yGeometrySegment);
        for (size_t i = 0; i < count; ++i) {
            const auto &piece = source.segments[i];
            if ((allow_empty ? piece.start > piece.end : piece.start >= piece.end) || piece.end > in.value.length ||
                (allow_empty && i && piece.start < source.segments[i-1].end) ||
                !isfinite(piece.x) || !isfinite(piece.y) || !isfinite(piece.width) || !isfinite(piece.height) ||
                piece.width < 0 || piece.height < 0 || (allow_empty && piece.height <= 0)) { free(offsets); return false; }
            output[i] = piece;
            offsets[2*i] = {piece.start, 2*i}; offsets[2*i+1] = {piece.end, 2*i+1};
        }
        // Visual order is not logical order for bidi. Sort endpoint requests,
        // scan validated UTF-8 once, then scatter UTF-16 offsets back into the
        // original visual ordering. Avoid conversion of every text prefix.
        qsort(offsets, 2*count, sizeof(GeometryOffset), compare_geometry_offset);
        size_t byte = 0; uint32_t wide = 0;
        for (size_t i = 0; i < 2*count; ++i) {
            const uint32_t target = offsets[i].byte;
            while (byte < target) {
                unsigned char lead = (unsigned char)in.value.bytes[byte];
                size_t size = lead < 0x80 ? 1 : lead < 0xe0 ? 2 : lead < 0xf0 ? 3 : 4;
                byte += size; wide += size == 4 ? 2 : 1;
            }
            if (byte != target) { free(offsets); return false; }
            auto &piece = output[offsets[i].endpoint/2];
            if (offsets[i].endpoint & 1) piece.end = wide; else piece.start = wide;
        }
        free(offsets); return true;
    }
    static bool copy_carets(const InputNode &in, Node &out, size_t &budget) {
        const size_t count = in.carets.count;
        if (!in.carets_ready) return count == 0;
        out.carets_ready = true;
        if (!count) return true;
        if (!in.carets.candidates || count > max_geometry_segments ||
            count > (max_geometry_bytes-budget)/sizeof(ZenitA11yCaretCandidate)) return false;
        auto *offsets = (GeometryOffset *)malloc(count*sizeof(GeometryOffset));
        out.carets = (ZenitA11yCaretCandidate *)malloc(count*sizeof(ZenitA11yCaretCandidate));
        if (!offsets || !out.carets) { free(offsets); return false; }
        out.caret_count = count; budget += count*sizeof(ZenitA11yCaretCandidate);
        for (size_t i = 0; i < count; ++i) {
            const auto &piece = in.carets.candidates[i];
            if (piece.offset > in.value.length || piece.downstream > 1 || piece.visible > 1 ||
                !isfinite(piece.first_x) || !isfinite(piece.first_y) ||
                !isfinite(piece.last_x) || !isfinite(piece.last_y) ||
                (piece.first_x == piece.last_x && piece.first_y == piece.last_y) ||
                (piece.visible && (!isfinite(piece.visible_first_x) || !isfinite(piece.visible_first_y) ||
                    !isfinite(piece.visible_last_x) || !isfinite(piece.visible_last_y) ||
                    (piece.visible_first_x == piece.visible_last_x && piece.visible_first_y == piece.visible_last_y)))) {
                free(offsets); return false;
            }
            out.carets[i] = piece;
            if (!piece.visible) {
                out.carets[i].visible_first_x = out.carets[i].visible_first_y = 0;
                out.carets[i].visible_last_x = out.carets[i].visible_last_y = 0;
            }
            offsets[i] = {piece.offset,i};
        }
        // Preserve bidi ordering, repeated offsets and affinity. Convert all
        // requested byte offsets in one sorted UTF-8 scan, then scatter back.
        qsort(offsets,count,sizeof(GeometryOffset),compare_geometry_offset);
        size_t byte = 0; uint32_t wide = 0;
        for (size_t i = 0; i < count; ++i) {
            const uint32_t target = offsets[i].byte;
            while (byte < target) {
                unsigned char lead = (unsigned char)in.value.bytes[byte];
                size_t size = lead < 0x80 ? 1 : lead < 0xe0 ? 2 : lead < 0xf0 ? 3 : 4;
                byte += size; wide += size == 4 ? 2 : 1;
            }
            if (byte != target) { free(offsets); return false; }
            out.carets[offsets[i].endpoint].offset = wide;
        }
        free(offsets); return true;
    }
    static int compare(const void *a, const void *b) {
        uint32_t x = ((const Index *)a)->id, y = ((const Index *)b)->id;
        return x < y ? -1 : x > y ? 1 : 0;
    }
    static wchar_t *copy(Text text, size_t &budget) {
        if (text.length > max_string_bytes - budget || (text.length && !text.bytes)) return nullptr;
        int count = text.length ? MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
            text.bytes, (int)text.length, nullptr, 0) : 0;
        if (text.length && !count) return nullptr;
        // Embedded NUL cannot be represented by UIA's string properties.
        for (size_t i = 0; i < text.length; ++i) if (!text.bytes[i]) return nullptr;
        wchar_t *result = (wchar_t *)calloc((size_t)count + 1, sizeof(wchar_t));
        if (!result) return nullptr;
        if (count && MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                text.bytes, (int)text.length, result, count) != count) { free(result); return nullptr; }
        budget += text.length;
        return result;
    }
    static bool offset(Text text, uint32_t byte, uint32_t &wide) {
        if (byte > text.length || (byte < text.length && ((unsigned char)text.bytes[byte] & 0xc0) == 0x80)) return false;
        if (!byte) { wide = 0; return true; }
        int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.bytes, (int)byte, nullptr, 0);
        if (!count) return false;
        wide = (uint32_t)count;
        return true;
    }
    ~Snapshot() {
        for (size_t i = 0; i < count_; ++i) {
            free((void *)nodes_[i].name); free((void *)nodes_[i].description); free((void *)nodes_[i].value);
            free((void *)nodes_[i].identifier); free(nodes_[i].characters); free(nodes_[i].words); free(nodes_[i].paragraphs); free(nodes_[i].lines);
            free(nodes_[i].geometry); free(nodes_[i].carets); free(nodes_[i].rows);
        }
        free(nodes_); free(index_);
    }
public:
    Snapshot() = default;
    Snapshot(const Snapshot &) = delete;
    Snapshot &operator=(const Snapshot &) = delete;
    Viewport viewport;
    static void *operator new(size_t size) noexcept { return malloc(size); }
    static void operator delete(void *memory) noexcept { free(memory); }
    // Per-node input contract; returns the violated rule, or null.
    static const char *invalid_input(const InputNode &in, size_t i) {
        if (in.id == no_parent) return "id";
        if (in.parent_index != no_parent && in.parent_index >= i) return "parent order";
        if (in.numeric > 1 || in.editable > 1 || in.can_set_selection > 1 || in.uniform_format > 1 || in.can_scroll > 1 ||
            in.geometry_ready > 1 || in.carets_ready > 1 || in.rows_ready > 1) return "flag value";
        if (in.can_set_selection && !in.editable) return "selection without editable";
        if (in.setters & ~15) return "setters";
        if (in.state & ~((1u << 19) - 1)) return "state bits";
        if (in.actions & ~15) return "actions";
        if (!isfinite(in.x) || !isfinite(in.y) || !isfinite(in.width) || !isfinite(in.height)) return "non-finite frame";
        if (in.width < 0 || in.height < 0) return "negative size";
        if (!isnan(in.small_change) && (!isfinite(in.small_change) || in.small_change < 0)) return "small change";
        if (!isnan(in.large_change) && (!isfinite(in.large_change) || in.large_change < 0)) return "large change";
        if (in.numeric && (!isfinite(in.value_now) || !isfinite(in.value_min) || !isfinite(in.value_max) ||
            in.value_min > in.value_max || in.value_now < in.value_min || in.value_now > in.value_max)) return "range value";
        return nullptr;
    }
    static Snapshot *create(const InputNode *input, size_t count) {
        last_reject_line = 0; last_reject_reason = "node text or geometry data"; last_reject_node = SIZE_MAX; last_reject_role = 0;
        if (count > max_nodes || (count && !input)) { last_reject_line = __LINE__; last_reject_reason = "node count"; return nullptr; }
        Snapshot *snapshot = new Snapshot;
        if (!snapshot) { last_reject_line = __LINE__; last_reject_reason = "allocation"; return nullptr; }
        if (count) {
            snapshot->nodes_ = (Node *)calloc(count, sizeof(Node));
            snapshot->index_ = (Index *)calloc(count, sizeof(Index));
            if (!snapshot->nodes_ || !snapshot->index_) { last_reject_line = __LINE__; last_reject_reason = "allocation"; delete snapshot; return nullptr; }
        }
        snapshot->count_ = count;
        size_t budget = 0, boundary_budget = 0, geometry_budget = 0, caret_budget = 0, row_budget = 0;
        for (size_t i = 0; i < count; ++i) {
            const InputNode &in = input[i]; Node &out = snapshot->nodes_[i];
            last_reject_node = i; last_reject_role = in.role;
            if (const char *reason = invalid_input(in, i)) {
                last_reject_line = __LINE__; last_reject_reason = reason;
                delete snapshot; return nullptr;
            }
            out.id = in.id; out.parent_index = in.parent_index; out.state = in.state;
            out.role = in.role; out.actions = in.actions; out.setters = in.setters; out.numeric = in.numeric && !(in.state & secure_state);
            out.x = in.x; out.y = in.y; out.width = in.width; out.height = in.height;
            out.value_now = in.value_now; out.value_min = in.value_min; out.value_max = in.value_max;
            out.small_change = in.small_change; out.large_change = in.large_change;
            if (in.state & secure_state) out.value_now = out.value_min = out.value_max = 0;
            out.name = copy(in.name, budget); out.description = copy(in.description, budget);
            out.value = copy(in.state & secure_state ? Text{nullptr, 0} : in.value, budget);
            out.identifier = copy(in.identifier, budget);
            if (!out.name || !out.description || !out.value || !out.identifier) { last_reject_line = __LINE__; delete snapshot; return nullptr; }
            // Password snapshots expose neither text length nor caret/selection
            // offsets. Their unredacted value is never read for conversion.
            out.editable = in.editable && !(in.state & secure_state);
            out.can_set_selection = in.can_set_selection && out.editable;
            out.uniform_format = in.uniform_format && out.editable;
            out.can_scroll = in.can_scroll && out.editable;
            if (out.editable) {
                const uint32_t visible_end = in.visible_end == UINT32_MAX ? (uint32_t)in.value.length : in.visible_end;
                if (in.visible_start > visible_end ||
                    !offset(in.value, (uint32_t)in.value.length, out.text_length) ||
                    !offset(in.value, in.selection_start, out.selection_start) ||
                    !offset(in.value, in.selection_end, out.selection_end) ||
                    !offset(in.value, in.caret, out.caret) ||
                    !offset(in.value, in.visible_start, out.visible_start) ||
                    !offset(in.value, visible_end, out.visible_end)) { last_reject_line = __LINE__; delete snapshot; return nullptr; }
                const ZenitA11yOffsets inputs[] = {in.characters, in.words, in.paragraphs, in.lines};
                uint32_t **outputs[] = {&out.characters, &out.words, &out.paragraphs, &out.lines};
                size_t *counts[] = {&out.character_count, &out.word_count, &out.paragraph_count, &out.line_count};
                for (size_t unit = 0; unit < 4; ++unit) if (inputs[unit].count) {
                    size_t count = inputs[unit].count;
                    if (!inputs[unit].bytes || count > in.value.length+1 || count > 4*(max_string_bytes+max_nodes)-boundary_budget ||
                        inputs[unit].bytes[0] != 0 || inputs[unit].bytes[count-1] != in.value.length) { last_reject_line = __LINE__; delete snapshot; return nullptr; }
                    *outputs[unit] = (uint32_t *)malloc(count*sizeof(uint32_t));
                    if (!*outputs[unit]) { last_reject_line = __LINE__; delete snapshot; return nullptr; }
                    *counts[unit] = count; boundary_budget += count;
                    // The value was validated above. Advance once across its
                    // UTF-8 scalars instead of rescanning every prefix (O(n²)).
                    size_t byte = 0; uint32_t wide = 0;
                    for (size_t j = 0; j < count; ++j) {
                        uint32_t target = inputs[unit].bytes[j];
                        if (target > in.value.length || (j && target <= inputs[unit].bytes[j-1])) { last_reject_line = __LINE__; delete snapshot; return nullptr; }
                        while (byte < target) {
                            unsigned char lead = (unsigned char)in.value.bytes[byte];
                            size_t size = lead < 0x80 ? 1 : lead < 0xe0 ? 2 : lead < 0xf0 ? 3 : 4;
                            byte += size; wide += size == 4 ? 2 : 1;
                        }
                        if (byte != target) { last_reject_line = __LINE__; delete snapshot; return nullptr; }
                        (*outputs[unit])[j] = wide;
                    }
                }
                out.geometry_ready = in.geometry_ready; out.rows_ready = in.rows_ready;
                if (!copy_segments(in,in.geometry,in.geometry_ready,false,out.geometry,out.geometry_count,geometry_budget) ||
                    !copy_segments(in,in.rows,in.rows_ready,true,out.rows,out.row_count,row_budget) ||
                    !copy_carets(in,out,caret_budget)) { last_reject_line = __LINE__; delete snapshot; return nullptr; }
            }

            snapshot->index_[i] = {in.id, (uint32_t)i};
        }
        if (count) qsort(snapshot->index_, count, sizeof(Index), compare);
        for (size_t i = 1; i < count; ++i)
            if (snapshot->index_[i-1].id == snapshot->index_[i].id) { last_reject_line = __LINE__; last_reject_reason = "duplicate id"; last_reject_node = SIZE_MAX; delete snapshot; return nullptr; }
        return snapshot;
    }
    void retain() { InterlockedIncrement(&refs); }
    void release() { if (!InterlockedDecrement(&refs)) delete this; }
    size_t count() const { return count_; }
    const Node *at(size_t index) const { return index < count_ ? &nodes_[index] : nullptr; }
    const Node *find(uint32_t id) const {
        size_t lo = 0, hi = count_;
        while (lo < hi) {
            size_t mid = lo + (hi - lo) / 2;
            if (index_[mid].id < id) lo = mid + 1; else hi = mid;
        }
        return lo < count_ && index_[lo].id == id ? &nodes_[index_[lo].index] : nullptr;
    }
};

// A retained provider keeps Context alive after the owning window disconnects.
// Publication and disconnection are serialized with reader acquisition; readers
// release independently, so old snapshots remain valid during a frame update.
class Context final {
    volatile LONG refs = 1;
    SRWLOCK lock = SRWLOCK_INIT;
    Snapshot *current = nullptr;
    bool connected = true;
    ~Context() { disconnect(); }
public:
    Context() = default;
    Context(const Context &) = delete;
    Context &operator=(const Context &) = delete;
    static void *operator new(size_t size) noexcept { return malloc(size); }
    static void operator delete(void *memory) noexcept { free(memory); }
    void retain() { InterlockedIncrement(&refs); }
    void release() { if (!InterlockedDecrement(&refs)) delete this; }
    bool publish(const InputNode *input, size_t count, const Viewport &viewport = {}) {
        Snapshot *next = Snapshot::create(input, count);
        if (!next) return false;
        next->viewport = viewport;
        AcquireSRWLockExclusive(&lock);
        bool accepted = connected;
        Snapshot *old = current;
        if (accepted) current = next;
        ReleaseSRWLockExclusive(&lock);
        if (accepted) { if (old) old->release(); } else next->release();
        return accepted;
    }
    Snapshot *acquire() {
        AcquireSRWLockShared(&lock);
        Snapshot *result = connected ? current : nullptr;
        if (result) result->retain();
        ReleaseSRWLockShared(&lock);
        return result;
    }
    void disconnect() {
        AcquireSRWLockExclusive(&lock);
        connected = false; Snapshot *old = current; current = nullptr;
        ReleaseSRWLockExclusive(&lock);
        if (old) old->release();
    }
};
} // namespace zenit_a11y
