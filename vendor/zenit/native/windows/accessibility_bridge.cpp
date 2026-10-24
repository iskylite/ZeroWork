#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <ole2.h>
#include <uiautomation.h>
#include <stdio.h>
#include <string.h>
#include <float.h>
#include "a11y_snapshot.h"

namespace zenit_uia {
using namespace zenit_a11y;
static volatile LONG next_identity = 0;
static bool supports_expand(const Node *node) {
    return node && (node->state & (1u << 18)) && (node->setters & 8);
}
static ExpandCollapseState expand_state(const Node *node) {
    return node && (node->state & (1u << 2)) ? ExpandCollapseState_Expanded : ExpandCollapseState_Collapsed;
}
static bool supports_invoke(const Node *node) {
    return node && (node->actions & 1) && (node->role == 2 || node->role == 9 || node->role == 25);
}
// Role ordinals follow ui/a11y/tree.zig Role (appended only): 52 static_text,
// 53 switch_control, 54 scroll_area. A switch toggles like a check box.
static bool supports_toggle(const Node *node) {
    return node && (node->role == 3 || node->role == 26 || node->role == 53);
}
static bool supports_text(const Node *node) {
    return node && node->editable && node->uniform_format && !(node->state & (2 | secure_state));
}
static bool supports_value(const Node *node) {
    return node && (node->role == 10 || node->role == 11 || node->role == 12);
}
static bool value_readonly(const Node *node) {
    return (node->state & (1u << 9)) || (!(node->setters & 1) && !(node->state & 1));
}
static bool supports_range(const Node *node) {
    return node && node->numeric && (node->role == 6 || node->role == 7 || node->role == 8);
}
static bool range_readonly(const Node *node) {
    return (node->state & (1u << 9)) || (!(node->setters & 2) && !(node->state & 1));
}
static bool selection_group(const Node *node) {
    return node && (node->role == 5 || node->role == 14 || node->role == 16 || node->role == 33);
}
static bool selection_selected(const Node *node) { return node && (node->state & (1u << (node->role == 4 ? 4 : 3))); }
static bool selection_multiple(const Node *node) { return node && node->role != 5 && node->role != 33 && (node->state & (1u << 16)); }
static bool selection_required(const Node *node) { return node && (node->role == 5 || node->role == 33 || (node->state & (1u << 7))); }
static const Node *selection_container(const Snapshot *snapshot, const Node *node) {
    if (!snapshot || !node) return nullptr;
    const unsigned role = node->role == 4 ? 5 : node->role == 15 ? 14 : node->role == 17 ? 16 : node->role == 34 ? 33 : 0;
    if (!role) return nullptr;
    uint32_t parent = node->parent_index;
    while (parent != no_parent) {
        const Node *ancestor = snapshot->at(parent);
        if (!ancestor) return nullptr;
        if (selection_group(ancestor)) return ancestor->role == role ? ancestor : nullptr;
        parent = ancestor->parent_index;
    }
    return nullptr;
}
static size_t selection_count(const Snapshot *snapshot, const Node *parent) {
    size_t count = 0;
    for (size_t i = 0; i < snapshot->count(); ++i) {
        const Node *item = snapshot->at(i);
        if (selection_selected(item) && selection_container(snapshot, item) == parent) ++count;
    }
    return count;
}
// Count each group's selection once per publication, rather than rescanning
// the whole snapshot for every selected item during animation frames.
struct SelectionCounts {
    const Snapshot *snapshot;
    uint16_t counts[max_nodes] = {};
    explicit SelectionCounts(const Snapshot *source): snapshot(source) {
        for (size_t i = 0; i < snapshot->count(); ++i) {
            const Node *item = snapshot->at(i);
            if (!selection_selected(item)) continue;
            const Node *group = selection_container(snapshot, item);
            if (group) ++counts[group - snapshot->at(0)];
        }
    }
    size_t get(const Node *group) const { return group ? counts[group - snapshot->at(0)] : 0; }
};
static HRESULT selection_check(const Snapshot *snapshot, const Node *node, uint8_t action) {
    const Node *parent = selection_container(snapshot, node);
    if (!parent) return UIA_E_NOTSUPPORTED;
    if (parent->state & 1) return UIA_E_ELEMENTNOTENABLED;
    if (parent->state & (2 | (1u << 9))) return UIA_E_NOTSUPPORTED;
    if (action == 7 && !selection_multiple(parent)) for (size_t i = 0; i < snapshot->count(); ++i) {
        const Node *sibling = snapshot->at(i);
        if (sibling->id != node->id && selection_selected(sibling) && selection_container(snapshot, sibling) == parent)
            return UIA_E_INVALIDOPERATION;
    }
    if (action == 8 && selection_selected(node) && selection_required(parent) && selection_count(snapshot, parent) <= 1)
        return UIA_E_INVALIDOPERATION;
    return S_OK;
}
static bool supports_action(const Node *node, uint8_t action) {
    return action == 12 ? node && node->editable && node->can_scroll : action == 11 ? node && node->editable && node->can_set_selection : action == 2 ? node && (node->state & (1u << 13)) : (action == 9 || action == 10) ? supports_expand(node) && !(node->state & (1u << 9)) : action == 0 ? supports_invoke(node) : action == 1 ? supports_toggle(node) &&
        (node->actions & 2) && !(node->state & (1u << 9)) :
        action == 4 ? supports_value(node) && (node->setters & 1) && !value_readonly(node) :
        (action == 6 || action == 7 || action == 8) ? node && ((node->role == 4 && action != 8 && (node->actions & 1)) || (node->setters & 4)) && !(node->state & (1u << 9)) :
        action == 5 && supports_range(node) && (node->setters & 2) && !range_readonly(node);
}
static ToggleState toggle_state(const Node *node) {
    return node->state & (1u << 5) ? ToggleState_Indeterminate :
        node->state & (1u << 4) ? ToggleState_On : ToggleState_Off;
}
constexpr size_t max_value_bytes = 65536, max_pending_bytes = 256 * 1024;
struct Request {
    uint32_t id; uint8_t action; char *text = nullptr; size_t length = 0; double number = 0;
    void clear() { if (text) { SecureZeroMemory(text, length+1); free(text); text = nullptr; } }
};
static bool background_e2e() {
    wchar_t flag[2] = {};
    return GetEnvironmentVariableW(L"ZENIT_E2E_BACKGROUND", flag, 2) == 1 && flag[0] == L'1';
}
struct Binding {
    volatile LONG refs = 1;
    HWND const hwnd;
    DWORD const owner;
    LONG const identity;
    bool const preserve_foreground;
    Context *context;
    SRWLOCK action_lock = SRWLOCK_INIT;
    ZenitA11yActionCallback action_callback = nullptr;
    void *action_context = nullptr;
    Request pending[64] = {};
    unsigned pending_count = 0;
    size_t pending_bytes = 0;
    void clear_pending() { for (unsigned i = 0; i < pending_count; ++i) pending[i].clear(); pending_count = 0; pending_bytes = 0; }
    Binding(HWND window): hwnd(window), owner(GetCurrentThreadId()),
        identity(InterlockedIncrement(&next_identity)), preserve_foreground(background_e2e()), context(new Context) {}
    static void *operator new(size_t size) noexcept { return malloc(size); }
    static void operator delete(void *memory) noexcept { free(memory); }
    void retain() { InterlockedIncrement(&refs); }
    void release() { if (!InterlockedDecrement(&refs)) { clear_pending(); if (context) context->release(); delete this; } }
    bool has_action_handler() {
        AcquireSRWLockShared(&action_lock);
        bool result = action_callback != nullptr;
        ReleaseSRWLockShared(&action_lock); return result;
    }
    HRESULT enqueue_action(uint32_t id, uint8_t action, char *text = nullptr, size_t length = 0, double number = 0) {
        AcquireSRWLockExclusive(&action_lock);
        Snapshot *snapshot = context->acquire();
        const Node *node = snapshot ? snapshot->find(id) : nullptr;
        HRESULT result = S_OK;
        if (!node) result = UIA_E_ELEMENTNOTAVAILABLE;
        else if ((node->state & 1) || !IsWindowEnabled(hwnd)) result = UIA_E_ELEMENTNOTENABLED;
        else if ((node->state & 2) || !supports_action(node, action) || !action_callback) result = UIA_E_NOTSUPPORTED;
        else if ((action == 6 || action == 7 || action == 8) && FAILED(result = selection_check(snapshot, node, action))) {}
        else if (action == 5 && (!isfinite(number) || number < node->value_min || number > node->value_max)) result = E_INVALIDARG;
        else if (action == 12 && (number != 0 && number != 1)) result = E_INVALIDARG;
        else if (pending_count == 64 || length > max_pending_bytes - pending_bytes) result = HRESULT_FROM_WIN32(ERROR_NOT_ENOUGH_QUOTA);
        else {
            pending[pending_count++] = {id, action, text, length, number};
            pending_bytes += length;
            if (!PostMessageW(hwnd, ZENIT_UIA_WAKE_MESSAGE, 0, 0)) {
                --pending_count; pending_bytes -= length; DWORD error = GetLastError(); result = error ? HRESULT_FROM_WIN32(error) : E_FAIL;
            }
        }
        if (snapshot) snapshot->release();
        ReleaseSRWLockExclusive(&action_lock);
        if (FAILED(result)) { Request rejected{id, action, text, length}; rejected.clear(); }
        return result;
    }
    HRESULT enqueue_text_range(uint32_t id, uint32_t start, uint32_t end, const wchar_t *expected, uint8_t action = 11, double alignment = 0) {
        Snapshot *snapshot = context->acquire();
        const Node *node = snapshot ? snapshot->find(id) : nullptr;
        HRESULT result = S_OK;
        char *payload = nullptr;
        size_t payload_size = 0;
        if (!node) result = UIA_E_ELEMENTNOTAVAILABLE;
        else if (expected && wcscmp(expected, node->value)) result = UIA_E_ELEMENTNOTAVAILABLE;
        // Shared projection removes action capabilities from disabled widgets.
        // Preserve the same disabled error as enqueue_action before testing
        // those capabilities; the queue rechecks it after payload conversion.
        else if ((node->state & 1) || !IsWindowEnabled(hwnd)) result = UIA_E_ELEMENTNOTENABLED;
        else if (!supports_action(node, action)) result = UIA_E_NOTSUPPORTED;
        else if (start > node->text_length || end > node->text_length ||
            (start < node->text_length && node->value[start] >= 0xdc00 && node->value[start] <= 0xdfff) ||
            (end < node->text_length && node->value[end] >= 0xdc00 && node->value[end] <= 0xdfff)) result = E_INVALIDARG;
        else {
            int bytes = node->text_length ? WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
                node->value, (int)node->text_length, nullptr, 0, nullptr, nullptr) : 0;
            if ((node->text_length && !bytes) || (size_t)bytes > max_pending_bytes - 8) result = HRESULT_FROM_WIN32(ERROR_NOT_ENOUGH_QUOTA);
            else {
                payload_size = (size_t)bytes + 8;
                payload = (char *)malloc(payload_size + 1);
                if (!payload) result = E_OUTOFMEMORY;
                else {
                    // Private range actions 11/12: two little-endian UTF-8 offsets, then
                    // the exact text expected at owner-thread dispatch.
                    uint32_t offsets[] = {
                        start ? (uint32_t)WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, node->value, (int)start, nullptr, 0, nullptr, nullptr) : 0,
                        end ? (uint32_t)WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, node->value, (int)end, nullptr, 0, nullptr, nullptr) : 0};
                    memcpy(payload, offsets, 8);
                    if (bytes && WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, node->value,
                        (int)node->text_length, payload+8, bytes, nullptr, nullptr) != bytes) result = E_INVALIDARG;
                    payload[payload_size] = 0;
                }
            }
        }
        if (snapshot) snapshot->release();
        if (FAILED(result)) { Request rejected{id, action, payload, payload_size}; rejected.clear(); return result; }
        return enqueue_action(id, action, payload, payload_size, alignment);
    }
    HRESULT enqueue_selection(uint32_t id, uint32_t start, uint32_t end, const wchar_t *expected = nullptr) {
        return enqueue_text_range(id, start, end, expected);
    }
    HRESULT enqueue_text(uint32_t id, LPCWSTR value) {
        if (!value) return E_INVALIDARG;
        size_t units = 0; while (units <= 16384 && value[units]) ++units;
        if (units > 16384) return E_INVALIDARG;
        int length = units ? WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value, (int)units, nullptr, 0, nullptr, nullptr) : 0;
        if ((units && !length) || length > (int)max_value_bytes) return E_INVALIDARG;
        char *text = (char *)malloc((size_t)length + 1); if (!text) return E_OUTOFMEMORY;
        if (length && WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value, (int)units, text, length, nullptr, nullptr) != length) {
            SecureZeroMemory(text, (size_t)length+1); free(text); return E_INVALIDARG;
        }
        text[length] = 0;
        return enqueue_action(id, 4, text, (size_t)length);
    }
};
class InvokePattern final: public IInvokeProvider {
    volatile LONG refs = 1;
    Binding *binding;
    uint32_t const id;
    ~InvokePattern() { binding->release(); }
public:
    InvokePattern(Binding *owner, uint32_t handle): binding(owner), id(handle) { binding->retain(); }
    static void *operator new(size_t size) noexcept { return malloc(size); }
    static void operator delete(void *memory) noexcept { free(memory); }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void **out) override {
        if (!out) return E_POINTER; *out = nullptr;
        if (iid != IID_IUnknown && iid != IID_IInvokeProvider) return E_NOINTERFACE;
        *out = static_cast<IInvokeProvider *>(this); AddRef(); return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return InterlockedIncrement(&refs); }
    ULONG STDMETHODCALLTYPE Release() override { ULONG n = InterlockedDecrement(&refs); if (!n) delete this; return n; }
    HRESULT STDMETHODCALLTYPE Invoke() override { return binding->enqueue_action(id, 0); }
};
class TogglePattern final: public IToggleProvider {
    volatile LONG refs = 1;
    Binding *binding;
    uint32_t const id;
    ~TogglePattern() { binding->release(); }
public:
    TogglePattern(Binding *owner, uint32_t handle): binding(owner), id(handle) { binding->retain(); }
    static void *operator new(size_t size) noexcept { return malloc(size); }
    static void operator delete(void *memory) noexcept { free(memory); }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void **out) override {
        if (!out) return E_POINTER; *out = nullptr;
        if (iid != IID_IUnknown && iid != IID_IToggleProvider) return E_NOINTERFACE;
        *out = static_cast<IToggleProvider *>(this); AddRef(); return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return InterlockedIncrement(&refs); }
    ULONG STDMETHODCALLTYPE Release() override { ULONG n = InterlockedDecrement(&refs); if (!n) delete this; return n; }
    HRESULT STDMETHODCALLTYPE Toggle() override { return binding->enqueue_action(id, 1); }
    HRESULT STDMETHODCALLTYPE get_ToggleState(ToggleState *out) override {
        if (!out) return E_POINTER; *out = ToggleState_Off;
        Snapshot *snapshot = binding->context->acquire();
        const Node *node = snapshot ? snapshot->find(id) : nullptr;
        HRESULT result = !node ? UIA_E_ELEMENTNOTAVAILABLE : !supports_toggle(node) ? UIA_E_NOTSUPPORTED : S_OK;
        if (SUCCEEDED(result)) *out = toggle_state(node);
        if (snapshot) snapshot->release(); return result;
    }
};
class ValuePattern final: public IValueProvider {
    volatile LONG refs = 1;
    Binding *binding;
    uint32_t const id;
    ~ValuePattern() { binding->release(); }
public:
    ValuePattern(Binding *owner, uint32_t handle): binding(owner), id(handle) { binding->retain(); }
    static void *operator new(size_t size) noexcept { return malloc(size); }
    static void operator delete(void *memory) noexcept { free(memory); }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void **out) override {
        if (!out) return E_POINTER; *out = nullptr;
        if (iid != IID_IUnknown && iid != IID_IValueProvider) return E_NOINTERFACE;
        *out = static_cast<IValueProvider *>(this); AddRef(); return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return InterlockedIncrement(&refs); }
    ULONG STDMETHODCALLTYPE Release() override { ULONG n = InterlockedDecrement(&refs); if (!n) delete this; return n; }
    HRESULT STDMETHODCALLTYPE SetValue(LPCWSTR value) override { return binding->enqueue_text(id, value); }
    HRESULT STDMETHODCALLTYPE get_Value(BSTR *out) override {
        if (!out) return E_POINTER; *out = nullptr;
        Snapshot *snapshot = binding->context->acquire();
        const Node *node = snapshot ? snapshot->find(id) : nullptr;
        HRESULT result = !node ? UIA_E_ELEMENTNOTAVAILABLE : !supports_value(node) ? UIA_E_NOTSUPPORTED :
            node->state & secure_state ? E_ACCESSDENIED : S_OK;
        if (SUCCEEDED(result)) { *out = SysAllocString(node->value); if (!*out) result = E_OUTOFMEMORY; }
        if (snapshot) snapshot->release(); return result;
    }
    HRESULT STDMETHODCALLTYPE get_IsReadOnly(BOOL *out) override {
        if (!out) return E_POINTER; *out = TRUE;
        Snapshot *snapshot = binding->context->acquire();
        const Node *node = snapshot ? snapshot->find(id) : nullptr;
        HRESULT result = !node ? UIA_E_ELEMENTNOTAVAILABLE : !supports_value(node) ? UIA_E_NOTSUPPORTED : S_OK;
        if (SUCCEEDED(result)) *out = value_readonly(node);
        if (snapshot) snapshot->release(); return result;
    }
};
class RangePattern final: public IRangeValueProvider {
    volatile LONG refs = 1;
    Binding *binding;
    uint32_t const id;
    ~RangePattern() { binding->release(); }
    HRESULT read(double *out, unsigned field) {
        if (!out) return E_POINTER; *out = 0;
        Snapshot *snapshot = binding->context->acquire();
        const Node *node = snapshot ? snapshot->find(id) : nullptr;
        HRESULT result = !node ? UIA_E_ELEMENTNOTAVAILABLE : !supports_range(node) ? UIA_E_NOTSUPPORTED : S_OK;
        if (SUCCEEDED(result)) *out = field == 0 ? node->value_now : field == 1 ? node->value_min :
            field == 2 ? node->value_max : field == 3 ? node->small_change : node->large_change;
        if (snapshot) snapshot->release(); return result;
    }
public:
    RangePattern(Binding *owner, uint32_t handle): binding(owner), id(handle) { binding->retain(); }
    static void *operator new(size_t size) noexcept { return malloc(size); }
    static void operator delete(void *memory) noexcept { free(memory); }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void **out) override {
        if (!out) return E_POINTER; *out = nullptr;
        if (iid != IID_IUnknown && iid != IID_IRangeValueProvider) return E_NOINTERFACE;
        *out = static_cast<IRangeValueProvider *>(this); AddRef(); return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return InterlockedIncrement(&refs); }
    ULONG STDMETHODCALLTYPE Release() override { ULONG n = InterlockedDecrement(&refs); if (!n) delete this; return n; }
    HRESULT STDMETHODCALLTYPE SetValue(double number) override { return binding->enqueue_action(id, 5, nullptr, 0, number); }
    HRESULT STDMETHODCALLTYPE get_Value(double *out) override { return read(out, 0); }
    HRESULT STDMETHODCALLTYPE get_Minimum(double *out) override { return read(out, 1); }
    HRESULT STDMETHODCALLTYPE get_Maximum(double *out) override { return read(out, 2); }
    HRESULT STDMETHODCALLTYPE get_SmallChange(double *out) override { return read(out, 3); }
    HRESULT STDMETHODCALLTYPE get_LargeChange(double *out) override { return read(out, 4); }
    HRESULT STDMETHODCALLTYPE get_IsReadOnly(BOOL *out) override {
        if (!out) return E_POINTER; *out = TRUE;
        Snapshot *snapshot = binding->context->acquire();
        const Node *node = snapshot ? snapshot->find(id) : nullptr;
        HRESULT result = !node ? UIA_E_ELEMENTNOTAVAILABLE : !supports_range(node) ? UIA_E_NOTSUPPORTED : S_OK;
        if (SUCCEEDED(result)) *out = range_readonly(node);
        if (snapshot) snapshot->release(); return result;
    }
};
struct View {
    Snapshot *snapshot;
    explicit View(Binding *binding): snapshot(binding->context->acquire()) {}
    ~View() { if (snapshot) snapshot->release(); }
};
static CONTROLTYPEID control_type(uint16_t role) {
    switch (role) {
        case 2: return UIA_ButtonControlTypeId;
        case 3: case 26: case 53: return UIA_CheckBoxControlTypeId;
        case 4: case 27: return UIA_RadioButtonControlTypeId;
        case 6: return UIA_SliderControlTypeId;
        case 7: return UIA_SpinnerControlTypeId;
        case 8: return UIA_ProgressBarControlTypeId;
        case 9: return UIA_HyperlinkControlTypeId;
        case 10: case 11: case 12: return UIA_EditControlTypeId;
        case 13: return UIA_ComboBoxControlTypeId;
        case 14: case 44: return UIA_ListControlTypeId;
        case 15: return UIA_ListItemControlTypeId;
        case 16: return UIA_TreeControlTypeId;
        case 17: return UIA_TreeItemControlTypeId;
        case 18: return UIA_DataGridControlTypeId;
        case 19: case 20: return UIA_DataItemControlTypeId;
        case 21: case 22: return UIA_HeaderItemControlTypeId;
        case 23: return UIA_MenuControlTypeId;
        case 24: return UIA_MenuBarControlTypeId;
        case 25: return UIA_MenuItemControlTypeId;
        case 28: case 29: case 1: return UIA_WindowControlTypeId;
        case 33: return UIA_TabControlTypeId;
        case 34: return UIA_TabItemControlTypeId;
        case 36: return UIA_ToolTipControlTypeId;
        case 37: case 5: return UIA_GroupControlTypeId;
        case 30: case 31: case 32: case 39: case 40: case 52: return UIA_TextControlTypeId;
        case 41: return UIA_ImageControlTypeId;
        case 45: return UIA_SeparatorControlTypeId;
        // Roles this table does not name (scroll_area, or one added later) are
        // panes. A role value is never a reason to reject the snapshot.
        default: return UIA_PaneControlTypeId;
    }
}
static HRESULT create_text_pattern(Binding *, uint32_t, IUnknown **);
class Provider final: public IRawElementProviderSimple, public IRawElementProviderFragment, public IRawElementProviderFragmentRoot,
    public ISelectionProvider, public ISelectionItemProvider, public IExpandCollapseProvider {
    volatile LONG refs = 1;
    Binding *binding;
    uint32_t const id;
    bool root() const { return id == no_parent; }
    bool owns_keyboard_focus() const {
        GUITHREADINFO info = {}; info.cbSize = sizeof(info);
        return GetForegroundWindow() == binding->hwnd && GetGUIThreadInfo(binding->owner, &info) && info.hwndFocus == binding->hwnd;
    }
    const Node *node(const View &view) const { return view.snapshot && !root() ? view.snapshot->find(id) : nullptr; }
    bool available(const View &view) const { return view.snapshot && (root() || node(view)); }
    HRESULT fragment(uint32_t handle, IRawElementProviderFragment **out) {
        auto *provider = new Provider(binding, handle);
        if (!provider) return E_OUTOFMEMORY;
        *out = static_cast<IRawElementProviderFragment *>(provider); return S_OK;
    }
    UiaRect bounds(const View &view) const {
        const auto &vp = view.snapshot->viewport;
        const Node *n = node(view);
        return n ? UiaRect{vp.x + n->x * vp.scale, vp.y + n->y * vp.scale,
            n->width * vp.scale, n->height * vp.scale} : UiaRect{vp.x, vp.y, vp.width, vp.height};
    }
    ~Provider() { binding->release(); }
public:
    Provider(Binding *owner, uint32_t handle): binding(owner), id(handle) { binding->retain(); }
    static void *operator new(size_t size) noexcept { return malloc(size); }
    static void operator delete(void *memory) noexcept { free(memory); }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void **out) override {
        if (!out) return E_POINTER; *out = nullptr;
        if (iid == IID_IUnknown || iid == IID_IRawElementProviderSimple) *out = static_cast<IRawElementProviderSimple *>(this);
        else if (iid == IID_IRawElementProviderFragment) *out = static_cast<IRawElementProviderFragment *>(this);
        else if (iid == IID_IRawElementProviderFragmentRoot && root()) *out = static_cast<IRawElementProviderFragmentRoot *>(this);
        else if (iid == IID_IExpandCollapseProvider) *out = static_cast<IExpandCollapseProvider *>(this);
        else if (iid == IID_ISelectionProvider) *out = static_cast<ISelectionProvider *>(this);
        else if (iid == IID_ISelectionItemProvider) *out = static_cast<ISelectionItemProvider *>(this);
        else return E_NOINTERFACE;
        AddRef(); return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return InterlockedIncrement(&refs); }
    ULONG STDMETHODCALLTYPE Release() override { ULONG n = InterlockedDecrement(&refs); if (!n) delete this; return n; }
    HRESULT STDMETHODCALLTYPE Expand() override { return binding->enqueue_action(id, 9); }
    HRESULT STDMETHODCALLTYPE Collapse() override { return binding->enqueue_action(id, 10); }
    HRESULT STDMETHODCALLTYPE get_ExpandCollapseState(ExpandCollapseState *out) override {
        if (!out) return E_POINTER; *out = ExpandCollapseState_LeafNode;
        View view(binding); const Node *n = node(view);
        if (!available(view)) return UIA_E_ELEMENTNOTAVAILABLE;
        if (!supports_expand(n)) return UIA_E_NOTSUPPORTED;
        *out = expand_state(n); return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetSelection(SAFEARRAY **out) override {
        if (!out) return E_POINTER; *out = nullptr;
        View view(binding); const Node *n = node(view);
        if (!available(view)) return UIA_E_ELEMENTNOTAVAILABLE;
        if (!selection_group(n)) return UIA_E_NOTSUPPORTED;
        size_t count = 0;
        for (size_t i = 0; i < view.snapshot->count(); ++i) {
            const Node *child = view.snapshot->at(i);
            if (selection_container(view.snapshot, child) == n && selection_selected(child)) ++count;
        }
        SAFEARRAY *array = SafeArrayCreateVector(VT_UNKNOWN, 0, (ULONG)count);
        if (!array) return E_OUTOFMEMORY;
        LONG index = 0;
        for (size_t i = 0; i < view.snapshot->count(); ++i) {
            const Node *child = view.snapshot->at(i);
            if (selection_container(view.snapshot, child) != n || !selection_selected(child)) continue;
            auto *provider = new Provider(binding, child->id);
            if (!provider) { SafeArrayDestroy(array); return E_OUTOFMEMORY; }
            IUnknown *item = static_cast<IRawElementProviderSimple *>(provider);
            HRESULT result = SafeArrayPutElement(array, &index, item); provider->Release();
            if (FAILED(result)) { SafeArrayDestroy(array); return result; }
            ++index;
        }
        *out = array; return S_OK;
    }
    HRESULT STDMETHODCALLTYPE get_CanSelectMultiple(BOOL *out) override {
        if (!out) return E_POINTER; *out = FALSE;
        View view(binding); if (!available(view)) return UIA_E_ELEMENTNOTAVAILABLE;
        if (!selection_group(node(view))) return UIA_E_NOTSUPPORTED;
        *out = selection_multiple(node(view)); return S_OK;
    }
    HRESULT STDMETHODCALLTYPE get_IsSelectionRequired(BOOL *out) override {
        if (!out) return E_POINTER; *out = FALSE;
        View view(binding); if (!available(view)) return UIA_E_ELEMENTNOTAVAILABLE;
        if (!selection_group(node(view))) return UIA_E_NOTSUPPORTED;
        *out = selection_required(node(view)); return S_OK;
    }
    HRESULT STDMETHODCALLTYPE get_IsSelected(BOOL *out) override {
        if (!out) return E_POINTER; *out = FALSE;
        View view(binding); if (!available(view)) return UIA_E_ELEMENTNOTAVAILABLE;
        const Node *n = node(view);
        if (!selection_container(view.snapshot, n)) return UIA_E_NOTSUPPORTED;
        *out = selection_selected(n); return S_OK;
    }
    HRESULT STDMETHODCALLTYPE get_SelectionContainer(IRawElementProviderSimple **out) override {
        if (!out) return E_POINTER; *out = nullptr;
        View view(binding); if (!available(view)) return UIA_E_ELEMENTNOTAVAILABLE;
        const Node *parent = selection_container(view.snapshot, node(view));
        if (!parent) return UIA_E_NOTSUPPORTED;
        auto *provider = new Provider(binding, parent->id); if (!provider) return E_OUTOFMEMORY;
        *out = static_cast<IRawElementProviderSimple *>(provider); return S_OK;
    }
    HRESULT select_action(uint8_t action) {
        View view(binding); if (!available(view)) return UIA_E_ELEMENTNOTAVAILABLE;
        const Node *n = node(view);
        if (!n) return UIA_E_NOTSUPPORTED;
        if ((n->state & 1) || !IsWindowEnabled(binding->hwnd)) return UIA_E_ELEMENTNOTENABLED;
        HRESULT result = selection_check(view.snapshot, n, action);
        if (FAILED(result)) return result;
        if (n->state & (2 | (1u << 9))) return UIA_E_NOTSUPPORTED;
        if (action == 8 && !selection_selected(n)) return S_OK;
        const Node *parent = selection_container(view.snapshot, n);
        if (selection_selected(n) && (action == 7 || (action == 6 && selection_count(view.snapshot, parent) == 1))) return S_OK;
        return binding->enqueue_action(id, action);
    }
    HRESULT STDMETHODCALLTYPE Select() override { return select_action(6); }
    HRESULT STDMETHODCALLTYPE AddToSelection() override { return select_action(7); }
    HRESULT STDMETHODCALLTYPE RemoveFromSelection() override { return select_action(8); }
    HRESULT STDMETHODCALLTYPE get_ProviderOptions(ProviderOptions *out) override {
        if (!out) return E_POINTER;
        // In unattended mode UIA focus requests only change internal Cx focus.
        // UIA can request focus implicitly while setting an editable value.
        // Interactive Apps continue to let UIA focus the HWND host.
        // Free-threaded: reads come from the published immutable snapshot and
        // every mutation is queued for the owner thread, so clients are served
        // on their own RPC threads. UseComThreading marshalled each property
        // read into the UI thread's STA, where a continuously animating window
        // (one frame per pump) stalled a tree walk past the client's timeout.
        *out = (ProviderOptions)(ProviderOptions_ServerSideProvider |
            (binding->preserve_foreground ? ProviderOptions_ProviderOwnsSetFocus : 0));
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetPatternProvider(PATTERNID pattern, IUnknown **out) override {
        if (!out) return E_POINTER; *out = nullptr;
        View view(binding); if (!available(view)) return UIA_E_ELEMENTNOTAVAILABLE;
        if (pattern == UIA_TextPatternId && supports_text(node(view)))
            return create_text_pattern(binding,id,out);
        if (pattern == UIA_InvokePatternId && supports_invoke(node(view)) && binding->has_action_handler()) {
            auto *provider = new InvokePattern(binding, id); if (!provider) return E_OUTOFMEMORY;
            *out = provider;
        } else if (pattern == UIA_TogglePatternId && supports_toggle(node(view)) && binding->has_action_handler()) {
            auto *provider = new TogglePattern(binding, id); if (!provider) return E_OUTOFMEMORY;
            *out = provider;
        } else if (pattern == UIA_ValuePatternId && supports_value(node(view)) && binding->has_action_handler()) {
            auto *provider = new ValuePattern(binding, id); if (!provider) return E_OUTOFMEMORY;
            *out = provider;
        }
        if (pattern == UIA_RangeValuePatternId && supports_range(node(view)) && binding->has_action_handler()) {
            auto *provider = new RangePattern(binding, id); if (!provider) return E_OUTOFMEMORY;
            *out = provider;
        }
        if (pattern == UIA_ExpandCollapsePatternId && supports_expand(node(view)) && binding->has_action_handler()) {
            *out = static_cast<IExpandCollapseProvider *>(this); AddRef();
        }
        if (pattern == UIA_SelectionPatternId && selection_group(node(view))) {
            *out = static_cast<ISelectionProvider *>(this); AddRef();
        } else if (pattern == UIA_SelectionItemPatternId && selection_container(view.snapshot, node(view))) {
            *out = static_cast<ISelectionItemProvider *>(this); AddRef();
        }
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetPropertyValue(PROPERTYID property, VARIANT *out) override {
        if (!out) return E_POINTER; VariantInit(out);
        View view(binding); if (!available(view)) return UIA_E_ELEMENTNOTAVAILABLE;
        const Node *n = node(view); uint32_t state = n ? n->state : 0;
        const wchar_t *text = nullptr;
        switch (property) {
            case UIA_IsTextPatternAvailablePropertyId:
                out->vt = VT_BOOL; out->boolVal = supports_text(n) ? VARIANT_TRUE : VARIANT_FALSE; break;
            case UIA_IsExpandCollapsePatternAvailablePropertyId:
                out->vt = VT_BOOL; out->boolVal = supports_expand(n) && binding->has_action_handler() ? VARIANT_TRUE : VARIANT_FALSE; break;
            case UIA_ExpandCollapseExpandCollapseStatePropertyId:
                if (supports_expand(n)) { out->vt = VT_I4; out->lVal = expand_state(n); } break;
            case UIA_IsSelectionPatternAvailablePropertyId:
                out->vt = VT_BOOL; out->boolVal = selection_group(n) ? VARIANT_TRUE : VARIANT_FALSE; break;
            case UIA_IsSelectionItemPatternAvailablePropertyId:
                out->vt = VT_BOOL; out->boolVal = selection_container(view.snapshot, n) ? VARIANT_TRUE : VARIANT_FALSE; break;
            case UIA_SelectionCanSelectMultiplePropertyId:
                if (selection_group(n)) { out->vt = VT_BOOL; out->boolVal = selection_multiple(n) ? VARIANT_TRUE : VARIANT_FALSE; } break;
            case UIA_SelectionIsSelectionRequiredPropertyId:
                if (selection_group(n)) { out->vt = VT_BOOL; out->boolVal = selection_required(n) ? VARIANT_TRUE : VARIANT_FALSE; } break;
            case UIA_SelectionItemIsSelectedPropertyId:
                if (selection_container(view.snapshot, n)) { out->vt = VT_BOOL; out->boolVal = selection_selected(n) ? VARIANT_TRUE : VARIANT_FALSE; } break;
            case UIA_SelectionItemSelectionContainerPropertyId:
                if (const Node *parent = selection_container(view.snapshot, n)) {
                    auto *provider = new Provider(binding, parent->id); if (!provider) return E_OUTOFMEMORY;
                    out->vt = VT_UNKNOWN; out->punkVal = static_cast<IRawElementProviderSimple *>(provider);
                } break;
            case UIA_SelectionSelectionPropertyId:
                if (selection_group(n)) {
                    HRESULT result = GetSelection(&out->parray); if (FAILED(result)) return result;
                    out->vt = VT_ARRAY | VT_UNKNOWN;
                } break;
            case UIA_ControlTypePropertyId: out->vt = VT_I4; out->lVal = n ? control_type(n->role) : UIA_WindowControlTypeId; break;
            case UIA_FrameworkIdPropertyId: text = L"Zenit"; break;
            case UIA_IsInvokePatternAvailablePropertyId:
                out->vt = VT_BOOL; out->boolVal = supports_invoke(n) && binding->has_action_handler() ? VARIANT_TRUE : VARIANT_FALSE; break;
            case UIA_IsTogglePatternAvailablePropertyId:
                out->vt = VT_BOOL; out->boolVal = supports_toggle(n) && binding->has_action_handler() ? VARIANT_TRUE : VARIANT_FALSE; break;
            case UIA_ToggleToggleStatePropertyId:
                if (supports_toggle(n)) { out->vt = VT_I4; out->lVal = toggle_state(n); } break;
            case UIA_IsValuePatternAvailablePropertyId:
                out->vt = VT_BOOL; out->boolVal = supports_value(n) && binding->has_action_handler() ? VARIANT_TRUE : VARIANT_FALSE; break;
            case UIA_ValueIsReadOnlyPropertyId:
                if (supports_value(n)) { out->vt = VT_BOOL; out->boolVal = value_readonly(n) ? VARIANT_TRUE : VARIANT_FALSE; } break;
            case UIA_ValueValuePropertyId:
                if (supports_value(n)) { if (n->state & secure_state) return E_ACCESSDENIED; text = n->value; } break;
            case UIA_IsRangeValuePatternAvailablePropertyId:
                out->vt = VT_BOOL; out->boolVal = supports_range(n) && binding->has_action_handler() ? VARIANT_TRUE : VARIANT_FALSE; break;
            case UIA_RangeValueIsReadOnlyPropertyId:
                if (supports_range(n)) { out->vt = VT_BOOL; out->boolVal = range_readonly(n) ? VARIANT_TRUE : VARIANT_FALSE; } break;
            case UIA_RangeValueValuePropertyId: case UIA_RangeValueMinimumPropertyId: case UIA_RangeValueMaximumPropertyId:
            case UIA_RangeValueSmallChangePropertyId: case UIA_RangeValueLargeChangePropertyId:
                if (supports_range(n)) {
                    out->vt = VT_R8; out->dblVal = property == UIA_RangeValueValuePropertyId ? n->value_now :
                        property == UIA_RangeValueMinimumPropertyId ? n->value_min : property == UIA_RangeValueMaximumPropertyId ? n->value_max :
                        property == UIA_RangeValueSmallChangePropertyId ? n->small_change : n->large_change;
                } break;
            case UIA_NamePropertyId: if (n) text = n->name; break; // Root inherits the HWND title.
            case UIA_HelpTextPropertyId: if (n) text = n->description; break;
            case UIA_AutomationIdPropertyId: {
                if (n && n->identifier[0]) { text = n->identifier; break; }
                wchar_t identifier[32]; swprintf(identifier, 32, L"zenit:%08x", id);
                out->vt = VT_BSTR; out->bstrVal = SysAllocString(identifier);
                return out->bstrVal ? S_OK : E_OUTOFMEMORY;
            }
            case UIA_IsEnabledPropertyId: out->vt = VT_BOOL; out->boolVal = !(state & 1) && IsWindowEnabled(binding->hwnd) ? VARIANT_TRUE : VARIANT_FALSE; break;
            case UIA_HasKeyboardFocusPropertyId: out->vt = VT_BOOL; out->boolVal = (state & (1u << 12)) && owns_keyboard_focus() ? VARIANT_TRUE : VARIANT_FALSE; break;
            case UIA_IsKeyboardFocusablePropertyId: out->vt = VT_BOOL; out->boolVal = state & (1u << 13) ? VARIANT_TRUE : VARIANT_FALSE; break;
            case UIA_IsPasswordPropertyId: out->vt = VT_BOOL; out->boolVal = state & secure_state ? VARIANT_TRUE : VARIANT_FALSE; break;
            case UIA_IsRequiredForFormPropertyId: out->vt = VT_BOOL; out->boolVal = state & (1u << 7) ? VARIANT_TRUE : VARIANT_FALSE; break;
            case UIA_IsControlElementPropertyId: case UIA_IsContentElementPropertyId:
                out->vt = VT_BOOL; out->boolVal = !n || (n->role != 0 && n->role != 51) ? VARIANT_TRUE : VARIANT_FALSE; break;
            case UIA_IsOffscreenPropertyId: {
                UiaRect r = bounds(view); const auto &vp = view.snapshot->viewport;
                bool off = (state & 2) || r.width <= 0 || r.height <= 0 ||
                    r.left + r.width <= vp.x || r.top + r.height <= vp.y ||
                    r.left >= vp.x + vp.width || r.top >= vp.y + vp.height;
                out->vt = VT_BOOL; out->boolVal = off ? VARIANT_TRUE : VARIANT_FALSE; break;
            }
            default: break; // VT_EMPTY asks UIA to use its default/host value.
        }
        if (text) { out->vt = VT_BSTR; out->bstrVal = SysAllocString(text); if (!out->bstrVal) return E_OUTOFMEMORY; }
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE get_HostRawElementProvider(IRawElementProviderSimple **out) override {
        if (!out) return E_POINTER; *out = nullptr;
        View view(binding); if (!available(view)) return UIA_E_ELEMENTNOTAVAILABLE;
        return root() ? UiaHostProviderFromHwnd(binding->hwnd, out) : S_OK;
    }
    HRESULT STDMETHODCALLTYPE Navigate(NavigateDirection direction, IRawElementProviderFragment **out) override {
        if (!out) return E_POINTER; *out = nullptr;
        View view(binding); if (!available(view)) return UIA_E_ELEMENTNOTAVAILABLE;
        const Node *self = node(view);
        if (direction == NavigateDirection_Parent) {
            if (root()) return S_OK;
            return fragment(self->parent_index == no_parent ? no_parent : view.snapshot->at(self->parent_index)->id, out);
        }
        bool child = direction == NavigateDirection_FirstChild || direction == NavigateDirection_LastChild;
        bool sibling = direction == NavigateDirection_NextSibling || direction == NavigateDirection_PreviousSibling;
        if (!child && !sibling) return E_INVALIDARG;
        if (sibling && root()) return S_OK;
        uint32_t parent = child ? (root() ? no_parent : (uint32_t)(self - view.snapshot->at(0))) : self->parent_index;
        const Node *match = nullptr;
        for (size_t i = 0; i < view.snapshot->count(); ++i) {
            const Node *candidate = view.snapshot->at(i);
            if (candidate->parent_index != parent || (candidate->state & 2)) continue;
            if (sibling && (direction == NavigateDirection_NextSibling ? candidate <= self : candidate >= self)) continue;
            match = candidate;
            if (direction == NavigateDirection_FirstChild || direction == NavigateDirection_NextSibling) break;
        }
        return match ? fragment(match->id, out) : S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetRuntimeId(SAFEARRAY **out) override {
        if (!out) return E_POINTER; *out = nullptr;
        View view(binding); if (!available(view)) return UIA_E_ELEMENTNOTAVAILABLE;
        if (root()) return S_OK;
        SAFEARRAY *array = SafeArrayCreateVector(VT_I4, 0, 3); if (!array) return E_OUTOFMEMORY;
        LONG values[3] = {UiaAppendRuntimeId, binding->identity, (LONG)id};
        for (LONG i = 0; i < 3; ++i) {
            HRESULT hr = SafeArrayPutElement(array, &i, &values[i]);
            if (FAILED(hr)) { SafeArrayDestroy(array); return hr; }
        }
        *out = array; return S_OK;
    }
    HRESULT STDMETHODCALLTYPE get_BoundingRectangle(UiaRect *out) override {
        if (!out) return E_POINTER; *out = {};
        View view(binding); if (!available(view)) return UIA_E_ELEMENTNOTAVAILABLE;
        *out = bounds(view); return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetEmbeddedFragmentRoots(SAFEARRAY **out) override {
        if (!out) return E_POINTER; *out = nullptr;
        View view(binding); return available(view) ? S_OK : UIA_E_ELEMENTNOTAVAILABLE;
    }
    HRESULT STDMETHODCALLTYPE SetFocus() override {
        View view(binding);
        if (!available(view)) return UIA_E_ELEMENTNOTAVAILABLE;
        if (!IsWindowEnabled(binding->hwnd)) return UIA_E_ELEMENTNOTENABLED;
        if (root()) return S_OK; // Host focus is managed by UI Automation.
        return binding->enqueue_action(id, 2);
    }
    HRESULT STDMETHODCALLTYPE get_FragmentRoot(IRawElementProviderFragmentRoot **out) override {
        if (!out) return E_POINTER; *out = nullptr;
        View view(binding); if (!available(view)) return UIA_E_ELEMENTNOTAVAILABLE;
        auto *provider = new Provider(binding, no_parent); if (!provider) return E_OUTOFMEMORY;
        *out = provider; return S_OK;
    }
    HRESULT STDMETHODCALLTYPE ElementProviderFromPoint(double x, double y, IRawElementProviderFragment **out) override {
        if (!out) return E_POINTER; *out = nullptr;
        View view(binding); if (!available(view)) return UIA_E_ELEMENTNOTAVAILABLE;
        const auto &vp = view.snapshot->viewport;
        if (x < vp.x || y < vp.y || x >= vp.x+vp.width || y >= vp.y+vp.height) return S_OK;
        uint32_t best = no_parent; size_t best_depth = 0;
        for (size_t i = 0; i < view.snapshot->count(); ++i) {
            const Node *n = view.snapshot->at(i);
            if (n->state & 2) continue;
            double nx = vp.x + n->x * vp.scale, ny = vp.y + n->y * vp.scale;
            if (x < nx || y < ny || x >= nx + n->width * vp.scale || y >= ny + n->height * vp.scale) continue;
            size_t depth = 1; uint32_t parent = n->parent_index;
            while (parent != no_parent) { ++depth; parent = view.snapshot->at(parent)->parent_index; }
            if (depth >= best_depth) { best = n->id; best_depth = depth; }
        }
        return fragment(best, out);
    }
    HRESULT STDMETHODCALLTYPE GetFocus(IRawElementProviderFragment **out) override {
        if (!out) return E_POINTER; *out = nullptr;
        View view(binding); if (!available(view)) return UIA_E_ELEMENTNOTAVAILABLE;
        if (!owns_keyboard_focus()) return S_OK;
        for (size_t i = 0; i < view.snapshot->count(); ++i) {
            const Node *n = view.snapshot->at(i);
            if ((n->state & (1u << 12)) && !(n->state & 2)) return fragment(n->id, out);
        }
        return S_OK;
    }
};
#include "a11y_text_range.h"
} // namespace zenit_uia

#ifdef ZENIT_WINDOW_CONTRACT
extern "C" int32_t zenit_uia_contract_selection_operation(void *opaque, uint32_t id, uint32_t position, int remove) {
    auto *binding = (zenit_uia::Binding *)opaque;
    if (!binding) return UIA_E_ELEMENTNOTAVAILABLE;
    ITextRangeProvider *range = nullptr;
    HRESULT result = zenit_uia::TextRange::create(binding, id, position, position, &range);
    if (SUCCEEDED(result)) { result = remove ? range->RemoveFromSelection() : range->AddToSelection(); range->Release(); }
    return result;
}
extern "C" int32_t zenit_uia_contract_scroll(void *opaque, uint32_t id, uint32_t start, uint32_t end, int align_top) {
    auto *binding = (zenit_uia::Binding *)opaque;
    if (!binding) return UIA_E_ELEMENTNOTAVAILABLE;
    ITextRangeProvider *range = nullptr;
    HRESULT result = zenit_uia::TextRange::create(binding, id, start, end, &range);
    if (SUCCEEDED(result)) { result = range->ScrollIntoView(align_top); range->Release(); }
    return result;
}
extern "C" int32_t zenit_uia_contract_single_unit_select(void *opaque, uint32_t id, uint32_t position, int page) {
    auto *binding = (zenit_uia::Binding *)opaque;
    if (!binding) return UIA_E_ELEMENTNOTAVAILABLE;
    ITextRangeProvider *range = nullptr;
    HRESULT result = zenit_uia::TextRange::create(binding, id, position, position, &range);
    if (SUCCEEDED(result)) {
        result = range->ExpandToEnclosingUnit(page ? TextUnit_Page : TextUnit_Format);
        if (SUCCEEDED(result)) result = range->Select();
        range->Release();
    }
    return result;
}
extern "C" int32_t zenit_uia_contract_line_select(void *opaque, uint32_t id, uint32_t position) {
    auto *binding = (zenit_uia::Binding *)opaque;
    if (!binding) return UIA_E_ELEMENTNOTAVAILABLE;
    ITextRangeProvider *range = nullptr;
    HRESULT result = zenit_uia::TextRange::create(binding, id, position, position, &range);
    if (SUCCEEDED(result)) {
        result = range->ExpandToEnclosingUnit(TextUnit_Line);
        if (SUCCEEDED(result)) result = range->Select();
        range->Release();
    }
    return result;
}
extern "C" int32_t zenit_uia_contract_logical_select(void *opaque, uint32_t id, uint32_t position, int paragraph) {
    auto *binding = (zenit_uia::Binding *)opaque;
    if (!binding) return UIA_E_ELEMENTNOTAVAILABLE;
    ITextRangeProvider *range = nullptr;
    HRESULT result = zenit_uia::TextRange::create(binding, id, position, position, &range);
    if (SUCCEEDED(result)) {
        result = range->ExpandToEnclosingUnit(paragraph ? TextUnit_Paragraph : TextUnit_Word);
        if (SUCCEEDED(result)) result = range->Select();
        range->Release();
    }
    return result;
}
extern "C" int32_t zenit_uia_contract_move_select(void *opaque, uint32_t id, uint32_t start, uint32_t end, int count) {
    auto *binding = (zenit_uia::Binding *)opaque;
    if (!binding) return UIA_E_ELEMENTNOTAVAILABLE;
    ITextRangeProvider *range = nullptr;
    HRESULT result = zenit_uia::TextRange::create(binding, id, start, end, &range);
    if (SUCCEEDED(result)) {
        int moved = 0;
        result = range->Move(TextUnit_Character, count, &moved);
        if (SUCCEEDED(result)) result = moved ? range->Select() : E_FAIL;
        range->Release();
    }
    return result;
}
extern "C" int32_t zenit_uia_contract_character_select(void *opaque, uint32_t id, uint32_t position) {
    auto *binding = (zenit_uia::Binding *)opaque;
    if (!binding) return UIA_E_ELEMENTNOTAVAILABLE;
    ITextRangeProvider *range = nullptr;
    HRESULT result = zenit_uia::TextRange::create(binding, id, position, position, &range);
    if (SUCCEEDED(result)) {
        int moved = 0;
        result = range->MoveEndpointByUnit(TextPatternRangeEndpoint_End, TextUnit_Character, 1, &moved);
        if (SUCCEEDED(result)) result = moved == 1 ? range->Select() : E_FAIL;
        range->Release();
    }
    return result;
}
extern "C" int32_t zenit_uia_contract_range_select(void *opaque, uint32_t id, uint32_t start, uint32_t end) {
    auto *binding = (zenit_uia::Binding *)opaque;
    if (!binding) return UIA_E_ELEMENTNOTAVAILABLE;
    ITextRangeProvider *range = nullptr;
    HRESULT result = zenit_uia::TextRange::create(binding, id, start, end, &range);
    if (SUCCEEDED(result)) { result = range->Select(); range->Release(); }
    return result;
}
extern "C" int32_t zenit_uia_contract_text_selection(void *opaque, uint32_t id, uint32_t start, uint32_t end) {
    auto *binding = (zenit_uia::Binding *)opaque;
    return binding ? binding->enqueue_selection(id, start, end) : UIA_E_ELEMENTNOTAVAILABLE;
}
extern "C" int32_t zenit_uia_contract_point(void *opaque, uint32_t id, double x, double y, uint32_t *out) {
    if (!out) return E_POINTER; memset(out,0,2*sizeof(uint32_t));
    ITextRangeProvider *range = nullptr;
    HRESULT result = zenit_uia::TextReadView::point((zenit_uia::Binding *)opaque,id,{x,y},&range);
    if (FAILED(result)) return result;
    zenit_uia::RangeState *state = nullptr;
    result = range->QueryInterface(zenit_uia::range_state_iid,(void **)&state); range->Release();
    if (FAILED(result)) return result;
    LONG identity = 0; uint32_t handle = 0, first = 0, last = 0;
    result = state->Read(&identity,&handle,&first,&last); state->Release();
    if (SUCCEEDED(result)) { out[0] = first; out[1] = last; }
    return result;
}
extern "C" int32_t zenit_uia_contract_visible_ranges(void *opaque, uint32_t id, uint32_t *out) {
    if (!out) return E_POINTER; memset(out,0,3*sizeof(uint32_t));
    SAFEARRAY *array = nullptr;
    HRESULT result = zenit_uia::TextReadView::visible((zenit_uia::Binding *)opaque,id,&array);
    if (FAILED(result)) return result;
    LONG high = -1, index = 0; IUnknown *unknown = nullptr;
    result = SafeArrayGetUBound(array,1,&high);
    if (SUCCEEDED(result)) result = SafeArrayGetElement(array,&index,&unknown);
    SafeArrayDestroy(array);
    if (FAILED(result)) return result;
    if (!unknown) return E_FAIL;
    zenit_uia::RangeState *state = nullptr;
    result = unknown->QueryInterface(zenit_uia::range_state_iid,(void **)&state); unknown->Release();
    if (FAILED(result)) return result;
    LONG identity = 0; uint32_t handle = 0, first = 0, last = 0;
    result = state->Read(&identity,&handle,&first,&last); state->Release();
    if (SUCCEEDED(result)) { out[0] = high+1; out[1] = first; out[2] = last; }
    return result;
}
extern "C" int32_t zenit_uia_contract_document_selection(void *opaque, uint32_t id, uint32_t *out) {
    if (!out) return E_POINTER;
    memset(out, 0, 4*sizeof(uint32_t));
    auto *binding = (zenit_uia::Binding *)opaque;
    ITextRangeProvider *document = nullptr;
    HRESULT result = zenit_uia::TextReadView::document(binding, id, &document);
    if (FAILED(result)) return result;
    BSTR text = nullptr;
    result = document->GetText(-1, &text); document->Release();
    if (FAILED(result)) return result;
    uint32_t length = SysStringLen(text); SysFreeString(text);
    SAFEARRAY *array = nullptr;
    result = zenit_uia::TextReadView::selection(binding, id, &array);
    if (FAILED(result)) return result;
    IUnknown *unknown = nullptr; LONG index = 0;
    result = SafeArrayGetElement(array, &index, &unknown); SafeArrayDestroy(array);
    if (FAILED(result)) return result;
    if (!unknown) return E_FAIL;
    zenit_uia::RangeState *state = nullptr;
    result = unknown->QueryInterface(zenit_uia::range_state_iid, (void **)&state); unknown->Release();
    if (FAILED(result)) return result;
    LONG identity = 0; uint32_t handle = 0, first = 0, last = 0;
    result = state->Read(&identity, &handle, &first, &last); state->Release();
    if (SUCCEEDED(result)) { out[0] = length; out[1] = first; out[2] = last; out[3] = last-first; }
    return result;
}
extern "C" int zenit_uia_contract_editable(void *opaque, uint32_t id, uint32_t *out) {
    auto *binding = (zenit_uia::Binding *)opaque;
    if (!binding || !out) return 0;
    zenit_uia::View view(binding);
    const auto *node = view.snapshot ? view.snapshot->find(id) : nullptr;
    if (!node) return 0;
    const uint32_t values[] = {node->editable, node->can_set_selection, node->text_length,
        node->selection_start, node->selection_end, node->caret, node->visible_start, node->visible_end};
    memcpy(out, values, sizeof(values));
    return 1;
}
extern "C" int zenit_uia_contract_geometry(void *opaque, uint32_t id, uint32_t index, uint32_t *out, float *rect) {
    auto *binding = (zenit_uia::Binding *)opaque;
    if (!binding || !out || !rect) return 0;
    zenit_uia::View view(binding);
    const auto *node = view.snapshot ? view.snapshot->find(id) : nullptr;
    if (!node || !node->geometry_ready || index >= node->geometry_count) return 0;
    const auto &piece = node->geometry[index];
    const uint32_t values[] = {node->geometry_ready,(uint32_t)node->geometry_count,piece.start,piece.end};
    const float bounds[] = {piece.x,piece.y,piece.width,piece.height};
    memcpy(out,values,sizeof(values)); memcpy(rect,bounds,sizeof(bounds)); return 1;
}
extern "C" int zenit_uia_contract_caret(void *opaque, uint32_t id, uint32_t index, uint32_t *out, float *line) {
    auto *binding = (zenit_uia::Binding *)opaque;
    if (!binding || !out || !line) return 0;
    zenit_uia::View view(binding);
    const auto *node = view.snapshot ? view.snapshot->find(id) : nullptr;
    if (!node || !node->carets_ready || index >= node->caret_count) return 0;
    const auto &piece = node->carets[index];
    const uint32_t values[] = {(uint32_t)node->caret_count,piece.offset,piece.downstream,piece.visible};
    const float points[] = {piece.first_x,piece.first_y,piece.last_x,piece.last_y,
        piece.visible_first_x,piece.visible_first_y,piece.visible_last_x,piece.visible_last_y};
    memcpy(out,values,sizeof(values)); memcpy(line,points,sizeof(points)); return 1;
}
extern "C" int32_t zenit_uia_contract_bounds(void *opaque, uint32_t id, uint32_t start, uint32_t end, double *out, uint32_t *count) {
    if (!out || !count) return E_POINTER;
    memset(out,0,4*sizeof(double)); *count = 0;
    auto *binding = (zenit_uia::Binding *)opaque;
    ITextRangeProvider *range = nullptr;
    HRESULT result = zenit_uia::TextRange::create(binding,id,start,end,&range);
    SAFEARRAY *array = nullptr;
    if (SUCCEEDED(result)) { result = range->GetBoundingRectangles(&array); range->Release(); }
    if (SUCCEEDED(result) && array) {
        LONG upper = -1; result = SafeArrayGetUBound(array,1,&upper);
        if (SUCCEEDED(result)) {
            *count = (uint32_t)(upper+1)/4;
            if (*count) {
                double *data = nullptr; result = SafeArrayAccessData(array,(void **)&data);
                if (SUCCEEDED(result)) { memcpy(out,data,4*sizeof(double)); result = SafeArrayUnaccessData(array); }
            }
        }
    }
    if (array) SafeArrayDestroy(array);
    return result;
}
extern "C" int32_t zenit_uia_contract_focus(void *opaque, uint32_t id) {
    auto *binding = (zenit_uia::Binding *)opaque;
    auto *provider = new zenit_uia::Provider(binding, id);
    if (!provider) return E_OUTOFMEMORY;
    HRESULT result = provider->SetFocus(); provider->Release(); return result;
}
#endif

extern "C" size_t zenit_uia_node_size(void) { return sizeof(ZenitA11yNode); }
extern "C" int zenit_uia_publish(void *opaque, const ZenitA11yNode *nodes, size_t count) {
    auto *binding = (zenit_uia::Binding *)opaque;
    if (!binding || binding->owner != GetCurrentThreadId()) return 0;
    RECT rect; POINT origin = {};
    if (!GetClientRect(binding->hwnd, &rect) || !ClientToScreen(binding->hwnd, &origin)) return 0;
    zenit_a11y::Viewport vp{(double)origin.x, (double)origin.y,
        (double)(rect.right-rect.left), (double)(rect.bottom-rect.top), (double)GetDpiForWindow(binding->hwnd)/96};
    zenit_uia::View before(binding);
    if (!binding->context->publish(nodes, count, vp)) {
        // Log each distinct rejection (site and reason) once; publication runs every frame.
        static thread_local int logged_line = -1;
        static thread_local const char *logged_reason = nullptr;
        if (zenit_a11y::last_reject_line != logged_line || zenit_a11y::last_reject_reason != logged_reason) {
            logged_line = zenit_a11y::last_reject_line; logged_reason = zenit_a11y::last_reject_reason;
            fprintf(stderr, "[a11y] snapshot rejected at a11y_snapshot.h:%d (%zu nodes): %s, node %zu role %u\n", logged_line, count,
                logged_reason, zenit_a11y::last_reject_node, zenit_a11y::last_reject_role);
            if (zenit_a11y::last_reject_node < count) {
                const auto &n = nodes[zenit_a11y::last_reject_node];
                fprintf(stderr, "[a11y]   frame=(%g,%g %gx%g) numeric=%u now=%g min=%g max=%g small=%g large=%g state=0x%x\n",
                    n.x, n.y, n.width, n.height, (unsigned)n.numeric, n.value_now, n.value_min, n.value_max, n.small_change, n.large_change, (unsigned)n.state);
            }
        }
        return 0;
    }
    // Notify only after publication, so clients reading in the event callback
    // observe the same committed state. All input paths share this notification.
    if (before.snapshot && UiaClientsAreListening()) {
        zenit_uia::View after(binding);
        if (!after.snapshot) return 1;
        zenit_uia::SelectionCounts old_counts(before.snapshot), new_counts(after.snapshot);
        for (size_t i = 0; after.snapshot && i < after.snapshot->count(); ++i) {
            const auto *current = after.snapshot->at(i);
            const auto *previous = before.snapshot->find(current->id);
            if (!previous || (current->state & 2)) continue;
            if (zenit_uia::supports_text(previous) && zenit_uia::supports_text(current)) {
                const bool text_changed = wcscmp(previous->value, current->value) != 0;
                const bool selection_changed = previous->selection_start != current->selection_start ||
                    previous->selection_end != current->selection_end || previous->caret != current->caret;
                if (text_changed || selection_changed) {
                    auto *provider = new zenit_uia::Provider(binding, current->id);
                    if (provider) {
                        if (text_changed) UiaRaiseAutomationEvent(provider, UIA_Text_TextChangedEventId);
                        if (selection_changed) UiaRaiseAutomationEvent(provider, UIA_Text_TextSelectionChangedEventId);
                        provider->Release();
                    }
                }
            }
            if (zenit_uia::supports_expand(previous) && zenit_uia::supports_expand(current) && zenit_uia::expand_state(previous) != zenit_uia::expand_state(current)) {
                auto *provider = new zenit_uia::Provider(binding, current->id);
                if (provider) {
                    VARIANT old_value = {}, new_value = {}; old_value.vt = new_value.vt = VT_I4;
                    old_value.lVal = zenit_uia::expand_state(previous); new_value.lVal = zenit_uia::expand_state(current);
                    UiaRaiseAutomationPropertyChangedEvent(provider, UIA_ExpandCollapseExpandCollapseStatePropertyId, old_value, new_value);
                    provider->Release();
                }
            }
            if (zenit_uia::selection_container(before.snapshot, previous) && zenit_uia::selection_container(after.snapshot, current) &&
                (zenit_uia::selection_selected(previous) != zenit_uia::selection_selected(current) ||
                 (zenit_uia::selection_selected(current) && new_counts.get(zenit_uia::selection_container(after.snapshot, current)) == 1 &&
                  old_counts.get(zenit_uia::selection_container(before.snapshot, previous)) != 1))) {
                auto *provider = new zenit_uia::Provider(binding, current->id);
                if (provider) {
                    VARIANT old_selected = {}, new_selected = {}; old_selected.vt = new_selected.vt = VT_BOOL;
                    old_selected.boolVal = zenit_uia::selection_selected(previous) ? VARIANT_TRUE : VARIANT_FALSE;
                    new_selected.boolVal = zenit_uia::selection_selected(current) ? VARIANT_TRUE : VARIANT_FALSE;
                    if (old_selected.boolVal != new_selected.boolVal) UiaRaiseAutomationPropertyChangedEvent(provider, UIA_SelectionItemIsSelectedPropertyId, old_selected, new_selected);
                    const zenit_a11y::Node *group = zenit_uia::selection_container(after.snapshot, current);
                    UiaRaiseAutomationEvent(provider, !zenit_uia::selection_selected(current) ? UIA_SelectionItem_ElementRemovedFromSelectionEventId :
                        new_counts.get(group) == 1 ? UIA_SelectionItem_ElementSelectedEventId : UIA_SelectionItem_ElementAddedToSelectionEventId);
                    provider->Release();
                }
            }
            VARIANT old_value = {}, new_value = {};
            PROPERTYID property = 0;
            if (zenit_uia::supports_toggle(previous) && zenit_uia::supports_toggle(current) &&
                zenit_uia::toggle_state(previous) != zenit_uia::toggle_state(current)) {
                property = UIA_ToggleToggleStatePropertyId;
                old_value.vt = new_value.vt = VT_I4;
                old_value.lVal = zenit_uia::toggle_state(previous); new_value.lVal = zenit_uia::toggle_state(current);
            } else if (zenit_uia::supports_range(previous) && zenit_uia::supports_range(current) && previous->value_now != current->value_now) {
                property = UIA_RangeValueValuePropertyId;
                old_value.vt = new_value.vt = VT_R8; old_value.dblVal = previous->value_now; new_value.dblVal = current->value_now;
            } else if (zenit_uia::supports_value(previous) && zenit_uia::supports_value(current) &&
                !((previous->state | current->state) & zenit_a11y::secure_state) && wcscmp(previous->value, current->value)) {
                property = UIA_ValueValuePropertyId;
                old_value.vt = new_value.vt = VT_BSTR;
                old_value.bstrVal = SysAllocString(previous->value); new_value.bstrVal = SysAllocString(current->value);
                if (!old_value.bstrVal || !new_value.bstrVal) { VariantClear(&old_value); VariantClear(&new_value); continue; }
            }
            if (!property) continue;
            auto *provider = new zenit_uia::Provider(binding, current->id);
            if (provider) { UiaRaiseAutomationPropertyChangedEvent(provider, property, old_value, new_value); provider->Release(); }
            VariantClear(&old_value); VariantClear(&new_value);
        }
    }
    return 1;
}
extern "C" void *zenit_uia_create(void *hwnd) {
    if (!hwnd || GetWindowThreadProcessId((HWND)hwnd, nullptr) != GetCurrentThreadId()) return nullptr;
    auto *binding = new zenit_uia::Binding((HWND)hwnd);
    if (!binding) return nullptr;
    if (!binding->context || !zenit_uia_publish(binding, nullptr, 0)) { binding->release(); return nullptr; }
    return binding;
}
extern "C" void zenit_uia_destroy(void *opaque) {
    auto *binding = (zenit_uia::Binding *)opaque; if (!binding) return;
    zenit_uia_set_action_handler(binding, nullptr, nullptr);
    binding->context->disconnect();
    UiaReturnRawElementProvider(binding->hwnd, 0, 0, nullptr);
    binding->release();
}
extern "C" int zenit_uia_set_action_handler(void *opaque, void *context, ZenitA11yActionCallback callback) {
    auto *binding = (zenit_uia::Binding *)opaque;
    if (!binding || binding->owner != GetCurrentThreadId() || (!!context != !!callback)) return 0;
    AcquireSRWLockExclusive(&binding->action_lock);
    if (binding->action_context != context || binding->action_callback != callback) binding->clear_pending();
    binding->action_context = context; binding->action_callback = callback;
    ReleaseSRWLockExclusive(&binding->action_lock); return 1;
}
extern "C" int zenit_uia_drain(void *opaque) {
    using namespace zenit_uia;
    auto *binding = (Binding *)opaque;
    if (!binding || binding->owner != GetCurrentThreadId()) return 0;
    binding->retain(); unsigned dispatched = 0;
    // Bound each UI turn even if other client threads keep enqueueing requests.
    for (unsigned budget = 0; budget < 64; ++budget) {
        AcquireSRWLockExclusive(&binding->action_lock);
        if (!binding->pending_count || !binding->action_callback) {
            ReleaseSRWLockExclusive(&binding->action_lock); break;
        }
        Request request = binding->pending[0]; uint32_t id = request.id;
        --binding->pending_count; binding->pending_bytes -= request.length;
        memmove(binding->pending, binding->pending+1, binding->pending_count*sizeof(Request));
        auto callback = binding->action_callback; void *context = binding->action_context;
        ReleaseSRWLockExclusive(&binding->action_lock);
        View view(binding); const Node *node = view.snapshot ? view.snapshot->find(id) : nullptr;
        if (!supports_action(node, request.action) || (node->state & 3) || !IsWindowEnabled(binding->hwnd)) { request.clear(); continue; }
        if ((request.action == 6 || request.action == 7 || request.action == 8) && FAILED(selection_check(view.snapshot, node, request.action))) { request.clear(); continue; }
        if (request.action == 5 && (!isfinite(request.number) || request.number < node->value_min || request.number > node->value_max)) { request.clear(); continue; }
        // The registered callback additionally validates the current mutable UI
        // tree on this thread; no Zig pointer is touched by COM/RPC threads.
        if (callback(context, id, request.action, request.text, request.length, request.number)) {
            ++dispatched;
            if (request.action == 0 && UiaClientsAreListening()) {
                auto *provider = new Provider(binding, id);
                if (provider) { UiaRaiseAutomationEvent(provider, UIA_Invoke_InvokedEventId); provider->Release(); }
            }
        }
        request.clear();
    }
    binding->release(); return (int)dispatched;
}
extern "C" intptr_t zenit_uia_get_object(void *opaque, uintptr_t wparam, intptr_t lparam) {
    auto *binding = (zenit_uia::Binding *)opaque;
    if (!binding || (LONG)lparam != UiaRootObjectId) return 0;
    auto *root = new zenit_uia::Provider(binding, zenit_a11y::no_parent); if (!root) return 0;
    LRESULT result = UiaReturnRawElementProvider(binding->hwnd, wparam, lparam, root);
    root->Release(); return result;
}
