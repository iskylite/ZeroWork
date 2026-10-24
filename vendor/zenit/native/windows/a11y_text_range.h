// Included inside zenit_uia after Provider. Plain editable controls expose
// TextPattern. COM readers hold owned snapshots, never Zig data.
// COM enum parameters are untrusted ABI integers. Clang's enum sanitizer
// otherwise traps on out-of-range values before our E_INVALIDARG validation.
#if defined(__clang__)
#define ZENIT_UIA_ENUM_INPUT __attribute__((no_sanitize("enum")))
#else
#define ZENIT_UIA_ENUM_INPUT
#endif
static const GUID range_state_iid = {0x3d018d24, 0x1748, 0x4b79, {0x84,0x16,0x37,0x1e,0x12,0xbe,0x0c,0x62}};
struct RangeState: IUnknown {
    virtual HRESULT STDMETHODCALLTYPE Read(LONG *, uint32_t *, uint32_t *, uint32_t *) = 0;
};
static bool valid_text_viewport(const Viewport &vp) {
    return isfinite(vp.x) && isfinite(vp.y) && isfinite(vp.width) && isfinite(vp.height) &&
        isfinite(vp.scale) && vp.scale > 0 && vp.width >= 0 && vp.height >= 0;
}
static bool visible_text_piece(const Snapshot *snapshot, const Node *node,
    const ZenitA11yGeometrySegment &piece, UiaRect &out) {
    const auto &vp = snapshot->viewport;
    const double left = node->x > 0 ? node->x : 0;
    const double top = node->y > 0 ? node->y : 0;
    const double node_right = (double)node->x+node->width, node_bottom = (double)node->y+node->height;
    const double right = node_right < vp.width/vp.scale ? node_right : vp.width/vp.scale;
    const double bottom = node_bottom < vp.height/vp.scale ? node_bottom : vp.height/vp.scale;
    const double x = piece.x > left ? piece.x : left, y = piece.y > top ? piece.y : top;
    const double piece_right = (double)piece.x+piece.width, piece_bottom = (double)piece.y+piece.height;
    const double r = piece_right < right ? piece_right : right, b = piece_bottom < bottom ? piece_bottom : bottom;
    if (left >= right || top >= bottom || r <= x || b <= y) return false;
    out = {x,y,r-x,b-y}; return true;
}
class TextRange final: public ITextRangeProvider, public RangeState {
    volatile LONG refs = 1;
    Binding *binding;
    Snapshot *snapshot;
    uint32_t const id;
    uint32_t start, end;
    SRWLOCK lock = SRWLOCK_INIT;
    const Node *current(View &view) const {
        const Node *node = view.snapshot ? view.snapshot->find(id) : nullptr;
        const Node *original = snapshot->find(id);
        return node && node->editable && !(node->state & 2) && original &&
            node->text_length == original->text_length && !wcscmp(node->value, original->value) ? node : nullptr;
    }
    HRESULT peer(ITextRangeProvider *other, uint32_t &first, uint32_t &last) {
        if (!other) return E_INVALIDARG;
        RangeState *state = nullptr;
        if (FAILED(other->QueryInterface(range_state_iid, (void **)&state)) || !state) return E_INVALIDARG;
        LONG identity = 0; uint32_t handle = no_parent;
        HRESULT result = state->Read(&identity, &handle, &first, &last); state->Release();
        if (SUCCEEDED(result) && (identity != binding->identity || handle != id)) return E_INVALIDARG;
        const Node *original = snapshot->find(id);
        if (SUCCEEDED(result) && (first > last || last > original->text_length ||
            (first < original->text_length && original->value[first] >= 0xdc00 && original->value[first] <= 0xdfff) ||
            (last < original->text_length && original->value[last] >= 0xdc00 && original->value[last] <= 0xdfff))) return E_INVALIDARG;
        return result;
    }
    HRESULT single_selection_operation() {
        View view(binding); const Node *node = current(view);
        if (!node) return UIA_E_ELEMENTNOTAVAILABLE;
        AcquireSRWLockShared(&lock); uint32_t first = start, last = end; ReleaseSRWLockShared(&lock);
        // EditableText exposes one selected span. Add/remove of a nonempty
        // range is a multi-selection operation, which this model cannot represent.
        if (first != last) {
            if ((node->state & 1) || !IsWindowEnabled(binding->hwnd)) return UIA_E_ELEMENTNOTENABLED;
            if (!supports_action(node, 11) || !binding->has_action_handler()) return UIA_E_NOTSUPPORTED;
            return UIA_E_INVALIDOPERATION;
        }
        // Capture endpoints once: a concurrent Move must not turn this caret
        // operation into selection of an unsupported nonempty range.
        return binding->enqueue_selection(id, first, last, snapshot->find(id)->value);
    }
    static bool terminal_empty_line(const Node *node, int unit) {
        return unit == TextUnit_Line && (node->state & (1u << 15)) &&
            node->text_length && node->value[node->text_length-1] == L'\n';
    }
    static bool boundaries(const Node *node, int unit, const uint32_t *&points, size_t &count) {
        switch (unit) {
        case TextUnit_Character: points = node->characters; count = node->character_count; break;
        case TextUnit_Word: points = node->words; count = node->word_count; break;
        case TextUnit_Line: points = node->lines; count = node->line_count; break;
        case TextUnit_Paragraph: points = node->paragraphs; count = node->paragraph_count; break;
        case TextUnit_Document: points = nullptr; count = 0; return true;
        default: return false;
        }
        return count != 0;
    }
    static TextUnit resolve_unit(const Node *live, int requested, const uint32_t *&points, size_t &count) {
        // Unsupported units defer to the next larger supported unit. Uniform
        // plain text has exactly one Format span, with Document boundaries.
        for (int unit = requested; unit <= TextUnit_Document; ++unit) {
            if (unit == TextUnit_Format && live->uniform_format) {
                points = nullptr; count = 0; return TextUnit_Document;
            }
            if (boundaries(live, unit, points, count)) return (TextUnit)unit;
        }
        return TextUnit_Document; // Document is always supported.
    }
    static bool endpoint(int value) {
        return value == TextPatternRangeEndpoint_Start || value == TextPatternRangeEndpoint_End;
    }
    TextRange(Binding *owner, Snapshot *owned, uint32_t handle, uint32_t first, uint32_t last):
        binding(owner), snapshot(owned), id(handle), start(first), end(last) { binding->retain(); snapshot->retain(); }
    ~TextRange() { snapshot->release(); binding->release(); }
public:
    static void *operator new(size_t size) noexcept { return malloc(size); }
    static void operator delete(void *memory) noexcept { free(memory); }
    static HRESULT create(Binding *binding, uint32_t id, uint32_t first, uint32_t last, ITextRangeProvider **out) {
        if (!out) return E_POINTER; *out = nullptr;
        if (!binding) return E_INVALIDARG;
        View view(binding);
        return create_owned(binding, view.snapshot, id, first, last, out);
    }
    // Derive endpoints and construct their range from one pinned view.
    // Reacquiring could bind old selection offsets to newly published text.
    static HRESULT create_owned(Binding *binding, Snapshot *owned, uint32_t id,
        uint32_t first, uint32_t last, ITextRangeProvider **out) {
        if (!out) return E_POINTER; *out = nullptr;
        if (!binding) return E_INVALIDARG;
        const Node *node = owned ? owned->find(id) : nullptr;
        if (!node || !node->editable || (node->state & 2)) return UIA_E_ELEMENTNOTAVAILABLE;
        if (first > node->text_length || last > node->text_length ||
            (first < node->text_length && node->value[first] >= 0xdc00 && node->value[first] <= 0xdfff) ||
            (last < node->text_length && node->value[last] >= 0xdc00 && node->value[last] <= 0xdfff)) return E_INVALIDARG;
        auto *range = new TextRange(binding, owned, id, first < last ? first : last, first < last ? last : first);
        if (!range) return E_OUTOFMEMORY; *out = range; return S_OK;
    }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void **out) override {
        if (!out) return E_POINTER; *out = nullptr;
        if (iid == IID_IUnknown || iid == __uuidof(ITextRangeProvider)) *out = static_cast<ITextRangeProvider *>(this);
        else if (iid == range_state_iid) *out = static_cast<RangeState *>(this);
        else return E_NOINTERFACE;
        AddRef(); return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return (ULONG)InterlockedIncrement(&refs); }
    ULONG STDMETHODCALLTYPE Release() override { ULONG count = (ULONG)InterlockedDecrement(&refs); if (!count) delete this; return count; }
    HRESULT STDMETHODCALLTYPE Read(LONG *identity, uint32_t *handle, uint32_t *first, uint32_t *last) override {
        if (!identity || !handle || !first || !last) return E_POINTER;
        View view(binding); if (!current(view)) return UIA_E_ELEMENTNOTAVAILABLE;
        AcquireSRWLockShared(&lock); *identity = binding->identity; *handle = id; *first = start; *last = end;
        ReleaseSRWLockShared(&lock); return S_OK;
    }
    HRESULT STDMETHODCALLTYPE Clone(ITextRangeProvider **out) override {
        if (!out) return E_POINTER; *out = nullptr;
        View view(binding); if (!current(view)) return UIA_E_ELEMENTNOTAVAILABLE;
        AcquireSRWLockShared(&lock); auto *copy = new TextRange(binding, snapshot, id, start, end); ReleaseSRWLockShared(&lock);
        if (!copy) return E_OUTOFMEMORY; *out = copy; return S_OK;
    }
    HRESULT STDMETHODCALLTYPE Compare(ITextRangeProvider *other, BOOL *out) override {
        if (!out) return E_POINTER; *out = FALSE;
        View view(binding); if (!current(view)) return UIA_E_ELEMENTNOTAVAILABLE;
        uint32_t first, last; HRESULT result = peer(other, first, last); if (FAILED(result)) return result;
        AcquireSRWLockShared(&lock); *out = start == first && end == last; ReleaseSRWLockShared(&lock); return S_OK;
    }
    ZENIT_UIA_ENUM_INPUT HRESULT STDMETHODCALLTYPE CompareEndpoints(TextPatternRangeEndpoint which, ITextRangeProvider *other, TextPatternRangeEndpoint target, int *out) override {
        if (!out) return E_POINTER; *out = 0;
        if (!endpoint(which) || !endpoint(target)) return E_INVALIDARG;
        View view(binding); if (!current(view)) return UIA_E_ELEMENTNOTAVAILABLE;
        uint32_t first, last; HRESULT result = peer(other, first, last); if (FAILED(result)) return result;
        AcquireSRWLockShared(&lock); uint32_t here = which == TextPatternRangeEndpoint_Start ? start : end; ReleaseSRWLockShared(&lock);
        uint32_t there = target == TextPatternRangeEndpoint_Start ? first : last;
        *out = here < there ? -1 : here > there ? 1 : 0; return S_OK;
    }
    ZENIT_UIA_ENUM_INPUT HRESULT STDMETHODCALLTYPE MoveEndpointByRange(TextPatternRangeEndpoint which, ITextRangeProvider *other, TextPatternRangeEndpoint target) override {
        if (!endpoint(which) || !endpoint(target)) return E_INVALIDARG;
        View view(binding); if (!current(view)) return UIA_E_ELEMENTNOTAVAILABLE;
        uint32_t first, last; HRESULT result = peer(other, first, last); if (FAILED(result)) return result;
        uint32_t position = target == TextPatternRangeEndpoint_Start ? first : last;
        AcquireSRWLockExclusive(&lock);
        if (which == TextPatternRangeEndpoint_Start) { start = position; if (start > end) end = start; }
        else { end = position; if (end < start) start = end; }
        ReleaseSRWLockExclusive(&lock); return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetText(int maximum, BSTR *out) override {
        if (!out) return E_POINTER; *out = nullptr;
        if (maximum < -1) return E_INVALIDARG;
        View view(binding); if (!current(view)) return UIA_E_ELEMENTNOTAVAILABLE;
        const Node *original = snapshot->find(id);
        AcquireSRWLockShared(&lock); uint32_t first = start, count = end-start; ReleaseSRWLockShared(&lock);
        if (maximum >= 0 && count > (uint32_t)maximum) count = (uint32_t)maximum;
        if (count && first+count < original->text_length && original->value[first+count] >= 0xdc00 && original->value[first+count] <= 0xdfff) --count;
        *out = SysAllocStringLen(original->value+first, count); return *out ? S_OK : E_OUTOFMEMORY;
    }
    HRESULT STDMETHODCALLTYPE GetEnclosingElement(IRawElementProviderSimple **out) override {
        if (!out) return E_POINTER; *out = nullptr;
        View view(binding); if (!current(view)) return UIA_E_ELEMENTNOTAVAILABLE;
        auto *provider = new Provider(binding, id); if (!provider) return E_OUTOFMEMORY; *out = provider; return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetChildren(SAFEARRAY **out) override {
        if (!out) return E_POINTER; *out = nullptr;
        View view(binding); if (!current(view)) return UIA_E_ELEMENTNOTAVAILABLE;
        *out = SafeArrayCreateVector(VT_UNKNOWN, 0, 0); return *out ? S_OK : E_OUTOFMEMORY;
    }
    HRESULT STDMETHODCALLTYPE GetAttributeValue(TEXTATTRIBUTEID attribute, VARIANT *out) override {
        if (!out) return E_POINTER; VariantInit(out);
        View view(binding); const Node *node = current(view); if (!node) return UIA_E_ELEMENTNOTAVAILABLE;
        if (attribute == UIA_IsReadOnlyAttributeId) { out->vt = VT_BOOL; out->boolVal = value_readonly(node) ? VARIANT_TRUE : VARIANT_FALSE; return S_OK; }
        IUnknown *unsupported = nullptr; HRESULT result = UiaGetReservedNotSupportedValue(&unsupported);
        if (SUCCEEDED(result)) { out->vt = VT_UNKNOWN; out->punkVal = unsupported; } return result;
    }
    HRESULT STDMETHODCALLTYPE Select() override {
        View view(binding); if (!current(view)) return UIA_E_ELEMENTNOTAVAILABLE;
        AcquireSRWLockShared(&lock); uint32_t first = start, last = end; ReleaseSRWLockShared(&lock);
        return binding->enqueue_selection(id, first, last, snapshot->find(id)->value);
    }
    HRESULT STDMETHODCALLTYPE FindAttribute(TEXTATTRIBUTEID attribute, VARIANT value, BOOL, ITextRangeProvider **out) override {
        if (!out) return E_POINTER; *out = nullptr;
        View view(binding); const Node *node = current(view); if (!node) return UIA_E_ELEMENTNOTAVAILABLE;
        if (attribute != UIA_IsReadOnlyAttributeId) return S_OK; // Unsupported attributes have no known matching span.
        if (value.vt != VT_BOOL) return E_INVALIDARG;
        if ((value.boolVal != VARIANT_FALSE) != value_readonly(node)) return S_OK;
        AcquireSRWLockShared(&lock); auto *match = new TextRange(binding, snapshot, id, start, end); ReleaseSRWLockShared(&lock);
        if (!match) return E_OUTOFMEMORY; *out = match; return S_OK;
    }
    HRESULT STDMETHODCALLTYPE FindText(BSTR needle, BOOL backward, BOOL ignore_case, ITextRangeProvider **out) override {
        if (!out) return E_POINTER; *out = nullptr;
        View view(binding); if (!current(view)) return UIA_E_ELEMENTNOTAVAILABLE;
        if (!needle) return E_INVALIDARG;
        UINT units = SysStringLen(needle);
        if (!units || units > max_string_bytes || !WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
            needle, (int)units, nullptr, 0, nullptr, nullptr)) return E_INVALIDARG;
        AcquireSRWLockShared(&lock); uint32_t first = start, count = end-start; ReleaseSRWLockShared(&lock);
        if (!count || units > count) return S_OK;
        const Node *original = snapshot->find(id);
        SetLastError(ERROR_SUCCESS);
        int found = FindStringOrdinal(backward ? FIND_FROMEND : FIND_FROMSTART,
            original->value+first, (int)count, needle, (int)units, ignore_case != FALSE);
        if (found < 0) { DWORD error = GetLastError(); return error ? HRESULT_FROM_WIN32(error) : S_OK; }
        uint32_t begin = first+(uint32_t)found, finish = begin+units;
        if ((uint32_t)found > count-units ||
            (begin < original->text_length && original->value[begin] >= 0xdc00 && original->value[begin] <= 0xdfff) ||
            (finish < original->text_length && original->value[finish] >= 0xdc00 && original->value[finish] <= 0xdfff)) return E_INVALIDARG;
        // Keep the parent's owned text version, even if publication changes
        // between validation and construction. Never rebind old offsets to new text.
        auto *match = new TextRange(binding, snapshot, id, begin, finish);
        if (!match) return E_OUTOFMEMORY; *out = match; return S_OK;
    }
    ZENIT_UIA_ENUM_INPUT HRESULT STDMETHODCALLTYPE ExpandToEnclosingUnit(TextUnit unit) override {
        if (unit < TextUnit_Character || unit > TextUnit_Document) return E_INVALIDARG;
        View view(binding); if (!current(view)) return UIA_E_ELEMENTNOTAVAILABLE;
        const Node *original = snapshot->find(id);
        const uint32_t *points = nullptr; size_t point_count = 0;
        unit = resolve_unit(current(view), unit, points, point_count);
        AcquireSRWLockExclusive(&lock);
        if (unit == TextUnit_Document) { start = 0; end = original->text_length; }
        else if (terminal_empty_line(current(view), unit) && start == original->text_length) end = start;
        else if (point_count == 1) start = end = 0;
        else {
            size_t low = 0, high = point_count;
            while (low < high) { size_t mid = low+(high-low)/2; if (points[mid] <= start) low = mid+1; else high = mid; }
            size_t index = low ? low-1 : 0;
            if (index == point_count-1) --index;
            start = points[index]; end = points[index+1];
        }
        ReleaseSRWLockExclusive(&lock); return S_OK;
    }
    ZENIT_UIA_ENUM_INPUT HRESULT STDMETHODCALLTYPE MoveEndpointByUnit(TextPatternRangeEndpoint which, TextUnit unit, int count, int *out) override {
        if (!out) return E_POINTER; *out = 0;
        if (!endpoint(which) || unit < TextUnit_Character || unit > TextUnit_Document) return E_INVALIDARG;
        View view(binding); if (!current(view)) return UIA_E_ELEMENTNOTAVAILABLE;
        const Node *original = snapshot->find(id);
        const uint32_t *points = nullptr; size_t point_count = 0;
        unit = resolve_unit(current(view), unit, points, point_count);
        AcquireSRWLockExclusive(&lock);
        uint32_t position = which == TextPatternRangeEndpoint_Start ? start : end;
        uint32_t target = position;
        if (count && unit == TextUnit_Document) {
            target = count > 0 ? original->text_length : 0;
            if (target != position) *out = count > 0 ? 1 : -1;
        } else if (count) {
            size_t low = 0, high = point_count;
            while (low < high) {
                size_t mid = low+(high-low)/2;
                if (points[mid] < position || (count > 0 && points[mid] == position)) low = mid+1;
                else high = mid;
            }
            int64_t base = count > 0 ? (int64_t)low-1 : (int64_t)low;
            int64_t moved = base+(int64_t)count, maximum = (int64_t)point_count-1;
            if (moved < 0) moved = 0; if (moved > maximum) moved = maximum;
            target = points[moved]; *out = (int)(moved-base);
        }
        if (which == TextPatternRangeEndpoint_Start) { start = target; if (start > end) end = start; }
        else { end = target; if (end < start) start = end; }
        ReleaseSRWLockExclusive(&lock); return S_OK;
    }
    ZENIT_UIA_ENUM_INPUT HRESULT STDMETHODCALLTYPE Move(TextUnit unit, int count, int *out) override {
        if (!out) return E_POINTER; *out = 0;
        if (unit < TextUnit_Character || unit > TextUnit_Document) return E_INVALIDARG;
        View view(binding); if (!current(view)) return UIA_E_ELEMENTNOTAVAILABLE;
        const Node *original = snapshot->find(id);
        const uint32_t *points = nullptr; size_t point_count = 0;
        unit = resolve_unit(current(view), unit, points, point_count);
        if (!count) return S_OK;
        AcquireSRWLockExclusive(&lock);
        bool caret = start == end;
        if (unit == TextUnit_Document) {
            // There is only one Document unit. A nonempty range cannot move
            // to another document; failed movement must preserve its endpoints.
            if (caret) {
                uint32_t target = count > 0 ? original->text_length : 0;
                if (target != start) { start = end = target; *out = count > 0 ? 1 : -1; }
            }
        } else if (point_count > 1) {
            size_t low = 0, high = point_count;
            while (low < high) {
                size_t mid = low+(high-low)/2;
                bool before = points[mid] < start || ((!caret || count > 0) && points[mid] == start);
                if (before) low = mid+1; else high = mid;
            }
            int64_t base = (!caret || count > 0) ? (int64_t)low-1 : (int64_t)low;
            int64_t maximum = (int64_t)point_count-((caret || terminal_empty_line(current(view), unit)) ? 1 : 2);
            int64_t target = base+(int64_t)count;
            if (target < 0) target = 0; if (target > maximum) target = maximum;
            *out = (int)(target-base);
            if (*out) { start = points[target]; end = caret || target+1 == (int64_t)point_count ? start : points[target+1]; }
        }
        ReleaseSRWLockExclusive(&lock); return S_OK;
    }
    // All geometry reads use the current owned view.
    HRESULT STDMETHODCALLTYPE GetBoundingRectangles(SAFEARRAY **out) override {
        if (!out) return E_POINTER; *out = nullptr;
        View view(binding); const Node *node = current(view);
        if (!node) return UIA_E_ELEMENTNOTAVAILABLE;
        AcquireSRWLockShared(&lock); uint32_t first = start, last = end; ReleaseSRWLockShared(&lock);
        if (first == last) {
            *out = SafeArrayCreateVector(VT_R8,0,0); return *out ? S_OK : E_OUTOFMEMORY;
        }
        if (!node->geometry_ready) return UIA_E_NOTSUPPORTED;
        const auto &vp = view.snapshot->viewport;
        if (!valid_text_viewport(vp)) return E_FAIL;
        UiaRect *rects = node->geometry_count ? (UiaRect *)malloc(node->geometry_count*sizeof(UiaRect)) : nullptr;
        if (node->geometry_count && !rects) return E_OUTOFMEMORY;
        size_t count = 0;
        for (size_t i = 0; i < node->geometry_count; ++i) {
            const auto &piece = node->geometry[i];
            if (piece.end <= first || piece.start >= last) continue;
            UiaRect rect;
            if (visible_text_piece(view.snapshot,node,piece,rect)) rects[count++] = rect;
        }
        if (count) qsort(rects,count,sizeof(UiaRect),[](const void *a,const void *b) {
            const auto &x = *(const UiaRect *)a, &y = *(const UiaRect *)b;
            if (x.top != y.top) return x.top < y.top ? -1 : 1;
            if (x.height != y.height) return x.height < y.height ? -1 : 1;
            return x.left < y.left ? -1 : x.left > y.left ? 1 : 0;
        });
        size_t merged = 0;
        for (size_t i = 0; i < count; ++i) {
            const UiaRect r = rects[i];
            const double previous_end = merged ? rects[merged-1].left+rects[merged-1].width : 0;
            // Float shaping widths can reconstruct an adjacent edge a few
            // ulps below the next float x after promotion to double.
            const double tolerance = 4*FLT_EPSILON*(fabs(previous_end) > 1 ? fabs(previous_end) : 1);
            if (merged && rects[merged-1].top == r.top && rects[merged-1].height == r.height &&
                r.left <= previous_end+tolerance) {
                auto &previous = rects[merged-1];
                const double end = r.left+r.width;
                if (end > previous.left+previous.width) previous.width = end-previous.left;
            } else rects[merged++] = r;
        }
        SAFEARRAY *array = SafeArrayCreateVector(VT_R8,0,(ULONG)(4*merged));
        if (!array) { free(rects); return E_OUTOFMEMORY; }
        if (merged) {
            double *values = nullptr;
            HRESULT result = SafeArrayAccessData(array,(void **)&values);
            if (FAILED(result)) { SafeArrayDestroy(array); free(rects); return result; }
            for (size_t i = 0; i < merged; ++i) {
                values[4*i] = vp.x+rects[i].left*vp.scale;
                values[4*i+1] = vp.y+rects[i].top*vp.scale;
                values[4*i+2] = rects[i].width*vp.scale;
                values[4*i+3] = rects[i].height*vp.scale;
            }
            result = SafeArrayUnaccessData(array);
            if (FAILED(result)) { SafeArrayDestroy(array); free(rects); return result; }
        }
        free(rects); *out = array; return S_OK;
    }
    HRESULT STDMETHODCALLTYPE AddToSelection() override { return single_selection_operation(); }
    HRESULT STDMETHODCALLTYPE RemoveFromSelection() override { return single_selection_operation(); }
    HRESULT STDMETHODCALLTYPE ScrollIntoView(BOOL align_top) override {
        View view(binding); if (!current(view)) return UIA_E_ELEMENTNOTAVAILABLE;
        AcquireSRWLockShared(&lock); uint32_t first = start, last = end; ReleaseSRWLockShared(&lock);
        return binding->enqueue_text_range(id, first, last, snapshot->find(id)->value, 12, align_top ? 1 : 0);
    }
};

#undef ZENIT_UIA_ENUM_INPUT

// Shared owned read surface. Public TextPattern additionally requires a plain
// editable stream; private contracts can exercise richer snapshot geometry.
struct TextReadView {
    struct Span { uint32_t start, end; };
    static HRESULT point(Binding *binding, uint32_t id, UiaPoint point, ITextRangeProvider **out, bool plain = false) {
        if (!out) return E_POINTER; *out = nullptr;
        if (!binding || !isfinite(point.x) || !isfinite(point.y)) return E_INVALIDARG;
        View view(binding);
        const Node *node = view.snapshot ? view.snapshot->find(id) : nullptr;
        if (!node || !node->editable || (node->state & 2) || (plain && !supports_text(node))) return UIA_E_ELEMENTNOTAVAILABLE;
        const auto &vp = view.snapshot->viewport;
        if (!valid_text_viewport(vp)) return E_FAIL;
        const double x = (point.x-vp.x)/vp.scale, y = (point.y-vp.y)/vp.scale;
        if (!isfinite(x) || !isfinite(y)) return E_INVALIDARG;
        if (!node->text_length) return TextRange::create_owned(binding,view.snapshot,id,0,0,out);
        if (!node->carets_ready) return UIA_E_NOTSUPPORTED;
        // The owner has already applied affine ancestor clips. The snapshot
        // also fences synthetic/native inputs to the control and client area.
        const size_t capacity = node->geometry_count+node->row_count;
        Span *spans = capacity ? (Span *)malloc(capacity*sizeof(Span)) : nullptr;
        if (capacity && !spans) return E_OUTOFMEMORY;
        size_t count = 0;
        for (size_t i = 0; i < node->geometry_count; ++i) {
            const auto &piece = node->geometry[i]; UiaRect rect;
            if (visible_text_piece(view.snapshot,node,piece,rect)) spans[count++] = {piece.start,piece.end};
        }
        for (size_t i = 0; i < node->row_count; ++i) {
            const auto &row = node->rows[i]; UiaRect rect;
            bool blank = true;
            for (uint32_t j = row.start; j < row.end; ++j)
                if (node->value[j] != L'\r' && node->value[j] != L'\n') { blank = false; break; }
            if (blank && visible_text_piece(view.snapshot,node,row,rect)) spans[count++] = {row.start,row.end};
        }
        if (count) qsort(spans,count,sizeof(Span),[](const void *a,const void *b) {
            const auto &x = *(const Span *)a, &y = *(const Span *)b;
            return x.start < y.start ? -1 : x.start > y.start ? 1 : x.end < y.end ? -1 : x.end > y.end ? 1 : 0;
        });
        size_t merged = 0;
        for (size_t i = 0; i < count; ++i) {
            if (merged && spans[i].start <= spans[merged-1].end) {
                if (spans[i].end > spans[merged-1].end) spans[merged-1].end = spans[i].end;
            } else spans[merged++] = spans[i];
        }
        const double left = node->x > 0 ? node->x : 0, top = node->y > 0 ? node->y : 0;
        const double r = (double)node->x+node->width, b = (double)node->y+node->height;
        const double right = r < vp.width/vp.scale ? r : vp.width/vp.scale;
        const double bottom = b < vp.height/vp.scale ? b : vp.height/vp.scale;
        auto visible_line = [&](const ZenitA11yCaretCandidate &c) {
            if (!c.visible || left >= right || top >= bottom) return false;
            double lo = 0, hi = 1;
            auto axis = [&](double a, double z, double low, double high) {
                if (a == z) return a >= low && a <= high;
                double first = (low-a)/(z-a), last = (high-a)/(z-a);
                if (first > last) { double swap = first; first = last; last = swap; }
                if (first > lo) lo = first; if (last < hi) hi = last;
                return lo < hi;
            };
            return axis(c.visible_first_x,c.visible_last_x,left,right) &&
                axis(c.visible_first_y,c.visible_last_y,top,bottom) && lo < hi;
        };
        bool found = false; double best = 0; uint32_t offset = node->caret;
        for (size_t i = 0; i < node->caret_count; ++i) {
            const auto &c = node->carets[i];
            size_t lo = 0, hi = merged;
            while (lo < hi) {
                size_t mid = lo+(hi-lo)/2;
                if (spans[mid].end < c.offset) lo = mid+1; else hi = mid;
            }
            if (!visible_line(c) && !(lo < merged && spans[lo].start <= c.offset)) continue;
            // Distance to the exact original caret, not the clipping boundary.
            // Normalize before projection to avoid squaring large coordinates.
            const double dx = (double)c.last_x-c.first_x, dy = (double)c.last_y-c.first_y;
            const double length = hypot(dx,dy), ux = dx/length, uy = dy/length;
            double along = (x-c.first_x)*ux+(y-c.first_y)*uy;
            if (along < 0) along = 0; if (along > length) along = length;
            const double distance = hypot(x-(c.first_x+along*ux),y-(c.first_y+along*uy));
            // Visual ordering makes equidistant ties deterministic, including
            // repeated logical endpoints with different bidi affinities.
            if (!found || distance < best) { found = true; best = distance; offset = c.offset; }
        }
        free(spans);
        return TextRange::create_owned(binding,view.snapshot,id,offset,offset,out);
    }
    static HRESULT visible(Binding *binding, uint32_t id, SAFEARRAY **out, bool plain = false) {
        if (!out) return E_POINTER; *out = nullptr;
        if (!binding) return E_INVALIDARG;
        View view(binding);
        const Node *node = view.snapshot ? view.snapshot->find(id) : nullptr;
        if (!node || !node->editable || (node->state & 2) || (plain && !supports_text(node))) return UIA_E_ELEMENTNOTAVAILABLE;
        if (!valid_text_viewport(view.snapshot->viewport)) return E_FAIL;
        // Empty text is known independently of pending layout. Nonempty text
        // must not mistake missing geometry for an invisible document.
        if (node->text_length && !node->geometry_ready) return UIA_E_NOTSUPPORTED;
        const size_t capacity = node->geometry_count+node->row_count;
        Span *spans = capacity ? (Span *)malloc(capacity*sizeof(Span)) : nullptr;
        if (capacity && !spans) return E_OUTOFMEMORY;
        size_t count = 0;
        for (size_t i = 0; i < node->geometry_count; ++i) {
            const auto &piece = node->geometry[i]; UiaRect rect;
            if (piece.start < piece.end && visible_text_piece(view.snapshot,node,piece,rect))
                spans[count++] = {piece.start,piece.end};
        }
        for (size_t i = 0; i < node->row_count; ++i) {
            const auto &row = node->rows[i]; UiaRect rect;
            if (!visible_text_piece(view.snapshot,node,row,rect)) continue;
            uint32_t first = row.end;
            while (first > row.start && (node->value[first-1] == L'\r' || node->value[first-1] == L'\n')) --first;
            // Empty rows and logical separators have a visible row region
            // even when their insertion line is outside a horizontal clip.
            // Row regions must not expose horizontally hidden ordinary glyphs.
            if (first < row.end || row.start == row.end) spans[count++] = {first,row.end};
        }
        if (count) qsort(spans,count,sizeof(Span),[](const void *a,const void *b) {
            const Span &x = *(const Span *)a, &y = *(const Span *)b;
            return x.start < y.start ? -1 : x.start > y.start ? 1 : x.end < y.end ? -1 : x.end > y.end ? 1 : 0;
        });
        size_t merged = 0;
        for (size_t i = 0; i < count; ++i) {
            bool joins = merged && spans[i].start <= spans[merged-1].end;
            if (merged && !joins) {
                // Line separators have no ink, but belong to a contiguous
                // visible span when text on both sides is visible.
                joins = true;
                for (uint32_t j = spans[merged-1].end; j < spans[i].start; ++j)
                    if (node->value[j] != L'\r' && node->value[j] != L'\n') { joins = false; break; }
            }
            if (joins) {
                if (spans[i].end > spans[merged-1].end) spans[merged-1].end = spans[i].end;
            } else spans[merged++] = spans[i];
        }
        SAFEARRAY *array = SafeArrayCreateVector(VT_UNKNOWN,0,(ULONG)(merged ? merged : 1));
        if (!array) { free(spans); return E_OUTOFMEMORY; }
        HRESULT result = S_OK;
        for (LONG i = 0; i < (LONG)(merged ? merged : 1); ++i) {
            ITextRangeProvider *range = nullptr;
            const uint32_t first = merged ? spans[i].start : node->caret;
            const uint32_t last = merged ? spans[i].end : node->caret;
            result = TextRange::create_owned(binding,view.snapshot,id,first,last,&range);
            if (FAILED(result)) break;
            result = SafeArrayPutElement(array,&i,static_cast<IUnknown *>(range)); range->Release();
            if (FAILED(result)) break;
        }
        free(spans);
        if (FAILED(result)) { SafeArrayDestroy(array); return result; }
        *out = array; return S_OK;
    }
    static HRESULT document(Binding *binding, uint32_t id, ITextRangeProvider **out, bool plain = false) {
        if (!out) return E_POINTER; *out = nullptr;
        if (!binding) return E_INVALIDARG;
        View view(binding);
        const Node *node = view.snapshot ? view.snapshot->find(id) : nullptr;
        if (!node || !node->editable || (node->state & 2) || (plain && !supports_text(node))) return UIA_E_ELEMENTNOTAVAILABLE;
        return TextRange::create_owned(binding, view.snapshot, id, 0, node->text_length, out);
    }
    static HRESULT selection(Binding *binding, uint32_t id, SAFEARRAY **out, bool plain = false) {
        if (!out) return E_POINTER; *out = nullptr;
        if (!binding) return E_INVALIDARG;
        View view(binding);
        const Node *node = view.snapshot ? view.snapshot->find(id) : nullptr;
        if (!node || !node->editable || (node->state & 2) || (plain && !supports_text(node))) return UIA_E_ELEMENTNOTAVAILABLE;
        ITextRangeProvider *range = nullptr;
        HRESULT result = TextRange::create_owned(binding, view.snapshot, id,
            node->selection_start, node->selection_end, &range);
        if (FAILED(result)) return result;
        SAFEARRAY *array = SafeArrayCreateVector(VT_UNKNOWN, 0, 1);
        if (!array) { range->Release(); return E_OUTOFMEMORY; }
        LONG index = 0;
        result = SafeArrayPutElement(array, &index, static_cast<IUnknown *>(range));
        range->Release();
        if (FAILED(result)) { SafeArrayDestroy(array); return result; }
        *out = array; return S_OK;
    }
};


// Plain editable controls contain one semantic text stream and no embedded
// object ranges. Each call resolves current data through one owned snapshot.
class TextPattern final: public ITextProvider {
    volatile LONG refs = 1;
    Binding *binding;
    uint32_t const id;
    ~TextPattern() { binding->release(); }
public:
    TextPattern(Binding *owner, uint32_t handle): binding(owner), id(handle) { binding->retain(); }
    static void *operator new(size_t size) noexcept { return malloc(size); }
    static void operator delete(void *memory) noexcept { free(memory); }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void **out) override {
        if (!out) return E_POINTER; *out = nullptr;
        if (iid != IID_IUnknown && iid != IID_ITextProvider) return E_NOINTERFACE;
        *out = static_cast<ITextProvider *>(this); AddRef(); return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return (ULONG)InterlockedIncrement(&refs); }
    ULONG STDMETHODCALLTYPE Release() override { LONG count = InterlockedDecrement(&refs); if (!count) delete this; return (ULONG)count; }
    HRESULT STDMETHODCALLTYPE GetSelection(SAFEARRAY **out) override { return TextReadView::selection(binding,id,out,true); }
    HRESULT STDMETHODCALLTYPE GetVisibleRanges(SAFEARRAY **out) override { return TextReadView::visible(binding,id,out,true); }
    HRESULT STDMETHODCALLTYPE RangeFromPoint(UiaPoint point, ITextRangeProvider **out) override { return TextReadView::point(binding,id,point,out,true); }
    HRESULT STDMETHODCALLTYPE get_DocumentRange(ITextRangeProvider **out) override { return TextReadView::document(binding,id,out,true); }
    HRESULT STDMETHODCALLTYPE RangeFromChild(IRawElementProviderSimple *, ITextRangeProvider **out) override {
        if (!out) return E_POINTER; *out = nullptr;
        View view(binding);
        const Node *node = view.snapshot ? view.snapshot->find(id) : nullptr;
        if (!supports_text(node)) return UIA_E_ELEMENTNOTAVAILABLE;
        return E_INVALIDARG; // This plain text stream encloses no child object.
    }
    HRESULT STDMETHODCALLTYPE get_SupportedTextSelection(SupportedTextSelection *out) override {
        if (!out) return E_POINTER; *out = SupportedTextSelection_None;
        View view(binding);
        const Node *node = view.snapshot ? view.snapshot->find(id) : nullptr;
        if (!supports_text(node)) return UIA_E_ELEMENTNOTAVAILABLE;
        // EditableText has a single caret/anchor model. Disabled/readonly
        // states restrict actions without changing the control's selection model.
        *out = SupportedTextSelection_Single; return S_OK;
    }
};
static HRESULT create_text_pattern(Binding *binding, uint32_t id, IUnknown **out) {
    auto *pattern = new TextPattern(binding,id);
    if (!pattern) return E_OUTOFMEMORY;
    *out = static_cast<ITextProvider *>(pattern); return S_OK;
}
