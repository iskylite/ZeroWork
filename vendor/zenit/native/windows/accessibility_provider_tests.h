#pragma once
#include "accessibility_bridge.cpp"
struct InvokeCounter { DWORD owner; unsigned calls = 0, wrong_thread = 0; uint32_t last = 0; uint8_t last_action = 0; double number = 0; size_t text_length = 0; char text[128] = {}; };
static int count_invoke(void *opaque, uint32_t id, uint8_t action, const char *text, size_t length, double number) {
    auto *counter = (InvokeCounter *)opaque;
    ++counter->calls; counter->wrong_thread += GetCurrentThreadId() != counter->owner; counter->last = id; counter->last_action = action; counter->text_length = length; counter->number = number;
    if (text && length < sizeof(counter->text)) { memcpy(counter->text, text, length); counter->text[length] = 0; }
    return 1;
}
struct WorkerInvoke { zenit_uia::Binding *binding; IInvokeProvider *pattern; HRESULT result; int drained, installed; };
static DWORD WINAPI invoke_worker(void *opaque) {
    auto *work = (WorkerInvoke *)opaque;
    work->result = work->pattern->Invoke();
    work->drained = zenit_uia_drain(work->binding);
    work->installed = zenit_uia_set_action_handler(work->binding, nullptr, nullptr);
    return 0;
}
struct WorkerFocus { zenit_uia::Binding *binding; IRawElementProviderFragment *provider; HRESULT result; int drained; };
static DWORD WINAPI focus_worker(void *opaque) {
    auto *work = (WorkerFocus *)opaque;
    work->result = work->provider->SetFocus();
    work->drained = zenit_uia_drain(work->binding);
    return 0;
}
static void a11y_focus_contract(HWND window) {
    using namespace zenit_uia;
    unsigned before = checks;
    auto *binding = (Binding *)zenit_uia_create(window); CHECK(binding); if (!binding) return;
    InvokeCounter counter{GetCurrentThreadId()};
    InputNode node = {}; node.id = 0x01000002; node.parent_index = no_parent; node.role = 10;
    node.state = (1u << 13) | (1u << 9); // Readonly controls can still receive focus.
    CHECK(zenit_uia_publish(binding, &node, 1));
    auto *provider = new Provider(binding, node.id); CHECK(provider);
    if (!provider) { zenit_uia_destroy(binding); return; }
    CHECK(provider->SetFocus() == (HRESULT)UIA_E_NOTSUPPORTED);
    CHECK(zenit_uia_set_action_handler(binding, &counter, count_invoke));
    WorkerFocus work{binding, provider, E_FAIL, -1};
    HANDLE thread = CreateThread(nullptr, 0, focus_worker, &work, 0, nullptr); CHECK(thread);
    if (thread) {
        DWORD wait = WaitForSingleObject(thread, 5000); CHECK(wait == WAIT_OBJECT_0);
        if (wait != WAIT_OBJECT_0) ExitProcess(2);
        CloseHandle(thread);
        CHECK(work.result == S_OK && work.drained == 0 && counter.calls == 0);
        CHECK(zenit_uia_drain(binding) == 1 && counter.calls == 1 && counter.last_action == 2 && !counter.wrong_thread);
    }
    CHECK(provider->SetFocus() == S_OK);
    node.state |= 1; CHECK(zenit_uia_publish(binding, &node, 1));
    CHECK(zenit_uia_drain(binding) == 0 && counter.calls == 1);
    CHECK(provider->SetFocus() == (HRESULT)UIA_E_ELEMENTNOTENABLED);
    node.state = (1u << 13) | 2; CHECK(zenit_uia_publish(binding, &node, 1));
    CHECK(provider->SetFocus() == (HRESULT)UIA_E_NOTSUPPORTED);
    node.state = 0; CHECK(zenit_uia_publish(binding, &node, 1));
    CHECK(provider->SetFocus() == (HRESULT)UIA_E_NOTSUPPORTED);
    node.state = 1u << 13; CHECK(zenit_uia_publish(binding, &node, 1));
    CHECK(provider->SetFocus() == S_OK);
    CHECK(zenit_uia_set_action_handler(binding, nullptr, nullptr));
    CHECK(zenit_uia_drain(binding) == 0 && counter.calls == 1);
    CHECK(zenit_uia_publish(binding, nullptr, 0));
    CHECK(provider->SetFocus() == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE);
    zenit_uia_destroy(binding);
    CHECK(provider->SetFocus() == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE);
    provider->Release();
    printf("Windows UIA focus routing: %u checks\n", checks-before);
}
static void a11y_invoke_contract(HWND window) {
    using namespace zenit_uia;
    unsigned before = checks;
    auto *binding = (Binding *)zenit_uia_create(window); CHECK(binding); if (!binding) return;
    InvokeCounter counter{GetCurrentThreadId()};
    InputNode node = {}; node.id = 0x01000002; node.parent_index = no_parent; node.role = 2; node.actions = 1;
    CHECK(zenit_uia_publish(binding, &node, 1));
    auto *provider = new Provider(binding, node.id); CHECK(provider); if (!provider) { zenit_uia_destroy(binding); return; }
    IUnknown *unknown = nullptr; CHECK(provider->GetPatternProvider(UIA_InvokePatternId, &unknown) == S_OK && !unknown);
    CHECK(zenit_uia_set_action_handler(binding, &counter, count_invoke));
    CHECK(provider->GetPatternProvider(UIA_InvokePatternId, &unknown) == S_OK && unknown);
    IInvokeProvider *invoke = nullptr;
    if (unknown) { CHECK(unknown->QueryInterface(IID_IInvokeProvider, (void **)&invoke) == S_OK && invoke); unknown->Release(); }
    if (!invoke) { provider->Release(); zenit_uia_destroy(binding); return; }
    VARIANT property = {};
    CHECK(provider->GetPropertyValue(UIA_IsInvokePatternAvailablePropertyId, &property) == S_OK && property.boolVal == VARIANT_TRUE); VariantClear(&property);
    CHECK(invoke->Invoke() == S_OK && counter.calls == 0);
    CHECK(zenit_uia_drain(binding) == 1 && counter.calls == 1 && counter.last == node.id && !counter.wrong_thread);
    WorkerInvoke work{binding, invoke, E_FAIL, -1, -1}; HANDLE thread = CreateThread(nullptr, 0, invoke_worker, &work, 0, nullptr);
    CHECK(thread);
    if (thread) {
        DWORD wait = WaitForSingleObject(thread, 5000); CHECK(wait == WAIT_OBJECT_0);
        if (wait != WAIT_OBJECT_0) ExitProcess(2);
        CloseHandle(thread);
        CHECK(work.result == S_OK && work.drained == 0 && work.installed == 0 && counter.calls == 1);
        CHECK(zenit_uia_drain(binding) == 1 && counter.calls == 2 && !counter.wrong_thread);
    }
    unsigned executed = counter.calls;
    node.state = 1; CHECK(zenit_uia_publish(binding, &node, 1));
    CHECK(invoke->Invoke() == (HRESULT)UIA_E_ELEMENTNOTENABLED && zenit_uia_drain(binding) == 0);
    node.state = 0; CHECK(zenit_uia_publish(binding, &node, 1)); CHECK(invoke->Invoke() == S_OK);
    node.state = 1; CHECK(zenit_uia_publish(binding, &node, 1));
    CHECK(zenit_uia_drain(binding) == 0 && counter.calls == executed); // Disabled after acceptance.
    node.state = 0; CHECK(zenit_uia_publish(binding, &node, 1)); CHECK(invoke->Invoke() == S_OK);
    node.state = 2; CHECK(zenit_uia_publish(binding, &node, 1));
    CHECK(invoke->Invoke() == (HRESULT)UIA_E_NOTSUPPORTED && zenit_uia_drain(binding) == 0 && counter.calls == executed);
    node.state = 0; node.role = 3; node.actions = 3; CHECK(zenit_uia_publish(binding, &node, 1));
    unknown = nullptr; CHECK(provider->GetPatternProvider(UIA_InvokePatternId, &unknown) == S_OK && !unknown);
    CHECK(invoke->Invoke() == (HRESULT)UIA_E_NOTSUPPORTED); // Toggle is not Invoke.
    node.role = 2; node.actions = 0; CHECK(zenit_uia_publish(binding, &node, 1));
    CHECK(invoke->Invoke() == (HRESULT)UIA_E_NOTSUPPORTED);
    node.actions = 1; CHECK(zenit_uia_publish(binding, &node, 1));
    bool accepted = true; for (unsigned i = 0; i < 64; ++i) accepted &= invoke->Invoke() == S_OK;
    CHECK(accepted && counter.calls == executed);
    CHECK(invoke->Invoke() == HRESULT_FROM_WIN32(ERROR_NOT_ENOUGH_QUOTA));
    CHECK(zenit_uia_drain(binding) == 64 && counter.calls == executed+64 && !counter.wrong_thread);
    executed = counter.calls;
    CHECK(invoke->Invoke() == S_OK); CHECK(zenit_uia_set_action_handler(binding, nullptr, nullptr));
    CHECK(zenit_uia_drain(binding) == 0 && counter.calls == executed && invoke->Invoke() == (HRESULT)UIA_E_NOTSUPPORTED);
    CHECK(zenit_uia_set_action_handler(binding, &counter, count_invoke)); CHECK(invoke->Invoke() == S_OK);
    node.id = 0x02000002; CHECK(zenit_uia_publish(binding, &node, 1));
    CHECK(zenit_uia_drain(binding) == 0 && counter.calls == executed && invoke->Invoke() == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE);
    zenit_uia_destroy(binding);
    CHECK(invoke->Invoke() == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE && counter.calls == executed);
    invoke->Release(); provider->Release();
    printf("Windows UIA Invoke: %u checks; bounded async queue, owner-thread dispatch and cancellation\n", checks-before);
}
struct WorkerToggle { zenit_uia::Binding *binding; IToggleProvider *pattern; HRESULT result; ToggleState state; };
static DWORD WINAPI toggle_worker(void *opaque) {
    auto *work = (WorkerToggle *)opaque;
    work->result = work->pattern->Toggle();
    if (work->result == S_OK) work->result = work->pattern->get_ToggleState(&work->state);
    return 0;
}
static void a11y_toggle_contract(HWND window) {
    using namespace zenit_uia;
    unsigned before = checks;
    auto *binding = (Binding *)zenit_uia_create(window); CHECK(binding); if (!binding) return;
    InvokeCounter counter{GetCurrentThreadId()};
    InputNode node = {}; node.id = 0x01000006; node.parent_index = no_parent; node.role = 3; node.actions = 3;
    CHECK(zenit_uia_publish(binding, &node, 1));
    auto *provider = new Provider(binding, node.id); CHECK(provider);
    if (!provider) { zenit_uia_destroy(binding); return; }
    IUnknown *unknown = nullptr;
    CHECK(provider->GetPatternProvider(UIA_TogglePatternId, &unknown) == S_OK && !unknown);
    CHECK(zenit_uia_set_action_handler(binding, &counter, count_invoke));
    CHECK(provider->GetPatternProvider(UIA_TogglePatternId, &unknown) == S_OK && unknown);
    IToggleProvider *toggle = nullptr;
    if (unknown) { CHECK(unknown->QueryInterface(IID_IToggleProvider, (void **)&toggle) == S_OK && toggle); unknown->Release(); }
    if (!toggle) { provider->Release(); zenit_uia_destroy(binding); return; }
    void *wrong = (void *)1;
    CHECK(toggle->QueryInterface(IID_IInvokeProvider, &wrong) == E_NOINTERFACE && !wrong);
    CHECK(toggle->get_ToggleState(nullptr) == E_POINTER);
    ToggleState state = ToggleState_Indeterminate;
    CHECK(toggle->get_ToggleState(&state) == S_OK && state == ToggleState_Off);
    VARIANT property = {};
    CHECK(provider->GetPropertyValue(UIA_IsTogglePatternAvailablePropertyId, &property) == S_OK && property.boolVal == VARIANT_TRUE); VariantClear(&property);
    CHECK(provider->GetPropertyValue(UIA_IsInvokePatternAvailablePropertyId, &property) == S_OK && property.boolVal == VARIANT_FALSE); VariantClear(&property);
    CHECK(provider->GetPropertyValue(UIA_ToggleToggleStatePropertyId, &property) == S_OK && property.vt == VT_I4 && property.lVal == ToggleState_Off); VariantClear(&property);
    node.state = 1u << 4; CHECK(zenit_uia_publish(binding, &node, 1));
    CHECK(toggle->get_ToggleState(&state) == S_OK && state == ToggleState_On);
    node.state |= 1u << 5; CHECK(zenit_uia_publish(binding, &node, 1));
    CHECK(toggle->get_ToggleState(&state) == S_OK && state == ToggleState_Indeterminate);
    CHECK(provider->GetPropertyValue(UIA_ToggleToggleStatePropertyId, &property) == S_OK && property.lVal == ToggleState_Indeterminate); VariantClear(&property);
    CHECK(toggle->Toggle() == S_OK && counter.calls == 0);
    CHECK(zenit_uia_drain(binding) == 1 && counter.calls == 1 && counter.last_action == 1 && !counter.wrong_thread);
    WorkerToggle work{binding, toggle, E_FAIL, ToggleState_Off}; HANDLE thread = CreateThread(nullptr, 0, toggle_worker, &work, 0, nullptr);
    CHECK(thread);
    if (thread) {
        DWORD wait = WaitForSingleObject(thread, 5000); CHECK(wait == WAIT_OBJECT_0);
        if (wait != WAIT_OBJECT_0) ExitProcess(2);
        CloseHandle(thread);
        CHECK(work.result == S_OK && work.state == ToggleState_Indeterminate && counter.calls == 1);
        CHECK(zenit_uia_drain(binding) == 1 && counter.calls == 2 && counter.last_action == 1 && !counter.wrong_thread);
    }
    node.state = 1; CHECK(zenit_uia_publish(binding, &node, 1));
    CHECK(toggle->Toggle() == (HRESULT)UIA_E_ELEMENTNOTENABLED);
    CHECK(toggle->get_ToggleState(&state) == S_OK && state == ToggleState_Off); // Disabled remains readable.
    node.state = 0; CHECK(zenit_uia_publish(binding, &node, 1)); CHECK(toggle->Toggle() == S_OK);
    node.state = 1; CHECK(zenit_uia_publish(binding, &node, 1));
    CHECK(zenit_uia_drain(binding) == 0 && counter.calls == 2);
    node.state = 2; CHECK(zenit_uia_publish(binding, &node, 1)); CHECK(toggle->Toggle() == (HRESULT)UIA_E_NOTSUPPORTED);
    node.state = 0; node.role = 4; CHECK(zenit_uia_publish(binding, &node, 1));
    unknown = nullptr; CHECK(provider->GetPatternProvider(UIA_TogglePatternId, &unknown) == S_OK && !unknown);
    CHECK(toggle->Toggle() == (HRESULT)UIA_E_NOTSUPPORTED); // Radio is Selection, never Toggle.
    CHECK(toggle->get_ToggleState(&state) == (HRESULT)UIA_E_NOTSUPPORTED);
    node.role = 26; CHECK(zenit_uia_publish(binding, &node, 1));
    CHECK(toggle->get_ToggleState(&state) == S_OK && state == ToggleState_Off); // Checkable menu item.
    CHECK(binding->enqueue_action(node.id, 9) == (HRESULT)UIA_E_NOTSUPPORTED);
    node.state = 1u << 9; CHECK(zenit_uia_publish(binding, &node, 1));
    CHECK(toggle->get_ToggleState(&state) == S_OK && state == ToggleState_Off);
    CHECK(toggle->Toggle() == (HRESULT)UIA_E_NOTSUPPORTED); // Readonly state remains readable.
    node.state = 0; node.actions = 1; CHECK(zenit_uia_publish(binding, &node, 1));
    CHECK(toggle->Toggle() == (HRESULT)UIA_E_NOTSUPPORTED);
    CHECK(toggle->get_ToggleState(&state) == S_OK && state == ToggleState_Off);
    node.actions = 3; CHECK(zenit_uia_publish(binding, &node, 1)); CHECK(toggle->Toggle() == S_OK);
    CHECK(zenit_uia_set_action_handler(binding, nullptr, nullptr)); CHECK(zenit_uia_drain(binding) == 0 && counter.calls == 2);
    CHECK(toggle->Toggle() == (HRESULT)UIA_E_NOTSUPPORTED);
    CHECK(zenit_uia_set_action_handler(binding, &counter, count_invoke)); CHECK(toggle->Toggle() == S_OK);
    node.id = 0x02000006; CHECK(zenit_uia_publish(binding, &node, 1));
    CHECK(zenit_uia_drain(binding) == 0 && counter.calls == 2);
    CHECK(toggle->get_ToggleState(&state) == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE);
    CHECK(toggle->Toggle() == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE);
    zenit_uia_destroy(binding);
    CHECK(toggle->get_ToggleState(&state) == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE);
    CHECK(toggle->Toggle() == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE && counter.calls == 2);
    toggle->Release(); provider->Release();
    printf("Windows UIA Toggle: %u checks; current state, typed owner-thread actions and retained lifetime\n", checks-before);
}
static void a11y_value_contract(HWND window) {
    using namespace zenit_uia;
    unsigned before = checks;
    auto *binding = (Binding *)zenit_uia_create(window); CHECK(binding); if (!binding) return;
    InvokeCounter counter{GetCurrentThreadId()};
    InputNode node = {}; node.id = 0x01000008; node.parent_index = no_parent; node.role = 10; node.setters = 1;
    node.value = {"中文 🧪", strlen("中文 🧪")};
    CHECK(zenit_uia_publish(binding, &node, 1));
    CHECK(zenit_uia_set_action_handler(binding, &counter, count_invoke));
    auto *provider = new Provider(binding, node.id); CHECK(provider);
    if (!provider) { zenit_uia_destroy(binding); return; }
    IUnknown *unknown = nullptr; CHECK(provider->GetPatternProvider(UIA_ValuePatternId, &unknown) == S_OK && unknown);
    IValueProvider *value = nullptr;
    if (unknown) { CHECK(unknown->QueryInterface(IID_IValueProvider, (void **)&value) == S_OK && value); unknown->Release(); }
    if (!value) { provider->Release(); zenit_uia_destroy(binding); return; }
    BSTR text = nullptr; BOOL readonly = TRUE; VARIANT property = {};
    CHECK(value->get_Value(nullptr) == E_POINTER && value->get_IsReadOnly(nullptr) == E_POINTER);
    CHECK(value->get_Value(&text) == S_OK && text && !wcscmp(text, L"中文 🧪")); SysFreeString(text); text = nullptr;
    CHECK(value->get_IsReadOnly(&readonly) == S_OK && !readonly);
    CHECK(provider->GetPropertyValue(UIA_ValueValuePropertyId, &property) == S_OK && property.vt == VT_BSTR && !wcscmp(property.bstrVal, L"中文 🧪")); VariantClear(&property);
    CHECK(provider->GetPropertyValue(UIA_IsValuePatternAvailablePropertyId, &property) == S_OK && property.boolVal == VARIANT_TRUE); VariantClear(&property);
    wchar_t source[] = L"新值 🧪";
    CHECK(value->SetValue(source) == S_OK && counter.calls == 0);
    source[0] = L'X'; // Queue owns converted bytes, never the COM caller's buffer.
    CHECK(zenit_uia_drain(binding) == 1 && counter.last_action == 4 && !strcmp(counter.text, "新值 🧪") && !counter.wrong_thread);
    CHECK(value->SetValue(L"") == S_OK && zenit_uia_drain(binding) == 1 && counter.text_length == 0);
    CHECK(value->SetValue(nullptr) == E_INVALIDARG);
    wchar_t invalid[] = {0xd800, 0}; CHECK(value->SetValue(invalid) == E_INVALIDARG);
    wchar_t *large = (wchar_t *)calloc(16386, sizeof(wchar_t)); CHECK(large);
    if (large) {
        for (unsigned i = 0; i < 16385; ++i) large[i] = L'a';
        CHECK(value->SetValue(large) == E_INVALIDARG);
        large[16384] = 0;
        for (unsigned i = 0; i < 16; ++i) CHECK(value->SetValue(large) == S_OK);
        CHECK(binding->pending_count == 16 && binding->pending_bytes == max_pending_bytes);
        CHECK(value->SetValue(L"x") == HRESULT_FROM_WIN32(ERROR_NOT_ENOUGH_QUOTA));
        CHECK(zenit_uia_set_action_handler(binding, nullptr, nullptr) && binding->pending_count == 0 && binding->pending_bytes == 0);
        free(large);
    }
    CHECK(zenit_uia_set_action_handler(binding, &counter, count_invoke));
    node.state = 1u << 9; CHECK(zenit_uia_publish(binding, &node, 1));
    CHECK(value->get_IsReadOnly(&readonly) == S_OK && readonly);
    CHECK(value->SetValue(L"readonly") == (HRESULT)UIA_E_NOTSUPPORTED);
    node.state = 1; node.setters = 0; CHECK(zenit_uia_publish(binding, &node, 1));
    CHECK(value->get_IsReadOnly(&readonly) == S_OK && !readonly);
    CHECK(value->get_Value(&text) == S_OK && text); SysFreeString(text); text = nullptr;
    CHECK(value->SetValue(L"disabled") == (HRESULT)UIA_E_ELEMENTNOTENABLED);
    node.state = 0; node.setters = 1; CHECK(zenit_uia_publish(binding, &node, 1)); CHECK(value->SetValue(L"queued") == S_OK);
    unsigned calls = counter.calls;
    node.state = 1; CHECK(zenit_uia_publish(binding, &node, 1));
    CHECK(zenit_uia_drain(binding) == 0 && counter.calls == calls && !binding->pending_bytes);
    node.state = secure_state; CHECK(zenit_uia_publish(binding, &node, 1));
    CHECK(value->get_Value(&text) == E_ACCESSDENIED && !text);
    CHECK(provider->GetPropertyValue(UIA_ValueValuePropertyId, &property) == E_ACCESSDENIED && property.vt == VT_EMPTY);
    CHECK(value->SetValue(L"synthetic-password") == S_OK && zenit_uia_drain(binding) == 1);
    node.state = 2; CHECK(zenit_uia_publish(binding, &node, 1)); CHECK(value->SetValue(L"hidden") == (HRESULT)UIA_E_NOTSUPPORTED);
    node.state = 0; node.role = 2; CHECK(zenit_uia_publish(binding, &node, 1));
    CHECK(value->get_Value(&text) == (HRESULT)UIA_E_NOTSUPPORTED && !text);
    CHECK(value->SetValue(L"button") == (HRESULT)UIA_E_NOTSUPPORTED);
    node.role = 10; CHECK(zenit_uia_publish(binding, &node, 1)); CHECK(value->SetValue(L"old generation") == S_OK);
    node.id = 0x02000008; CHECK(zenit_uia_publish(binding, &node, 1));
    CHECK(zenit_uia_drain(binding) == 0 && !binding->pending_bytes);
    CHECK(value->get_Value(&text) == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE && !text);
    zenit_uia_destroy(binding);
    CHECK(value->SetValue(L"stale") == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE);
    CHECK(value->get_IsReadOnly(&readonly) == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE);
    value->Release(); provider->Release();
    printf("Windows UIA Value: %u checks; Unicode ownership, bounded queue, readonly/secure and retained lifetime\n", checks-before);
}
static void a11y_range_contract(HWND window) {
    using namespace zenit_uia;
    unsigned before = checks;
    auto *binding = (Binding *)zenit_uia_create(window); CHECK(binding); if (!binding) return;
    InvokeCounter counter{GetCurrentThreadId()};
    InputNode node = {}; node.id = 0x01000009; node.parent_index = no_parent; node.role = 6; node.numeric = 1; node.setters = 2;
    node.value_now = 5; node.value_min = 0; node.value_max = 10; node.small_change = .5; node.large_change = NAN;
    CHECK(zenit_uia_publish(binding, &node, 1));
    CHECK(zenit_uia_set_action_handler(binding, &counter, count_invoke));
    auto *provider = new Provider(binding, node.id); CHECK(provider);
    if (!provider) { zenit_uia_destroy(binding); return; }
    IUnknown *unknown = nullptr; CHECK(provider->GetPatternProvider(UIA_RangeValuePatternId, &unknown) == S_OK && unknown);
    IRangeValueProvider *range = nullptr;
    if (unknown) { CHECK(unknown->QueryInterface(IID_IRangeValueProvider, (void **)&range) == S_OK && range); unknown->Release(); }
    if (!range) { provider->Release(); zenit_uia_destroy(binding); return; }
    double value = 0; BOOL readonly = TRUE; VARIANT property = {};
    CHECK(range->get_Value(nullptr) == E_POINTER && range->get_IsReadOnly(nullptr) == E_POINTER);
    CHECK(range->get_Value(&value) == S_OK && value == 5);
    CHECK(range->get_Minimum(&value) == S_OK && value == 0);
    CHECK(range->get_Maximum(&value) == S_OK && value == 10);
    CHECK(range->get_SmallChange(&value) == S_OK && value == .5);
    CHECK(range->get_LargeChange(&value) == S_OK && isnan(value));
    CHECK(range->get_IsReadOnly(&readonly) == S_OK && !readonly);
    CHECK(provider->GetPropertyValue(UIA_RangeValueValuePropertyId, &property) == S_OK && property.vt == VT_R8 && property.dblVal == 5); VariantClear(&property);
    CHECK(provider->GetPropertyValue(UIA_RangeValueLargeChangePropertyId, &property) == S_OK && property.vt == VT_R8 && isnan(property.dblVal)); VariantClear(&property);
    CHECK(range->SetValue(7.25) == S_OK && counter.calls == 0);
    CHECK(zenit_uia_drain(binding) == 1 && counter.calls == 1 && counter.last_action == 5 && counter.number == 7.25 && !counter.wrong_thread);
    CHECK(range->SetValue(-1) == E_INVALIDARG && range->SetValue(11) == E_INVALIDARG);
    CHECK(range->SetValue(NAN) == E_INVALIDARG && range->SetValue(INFINITY) == E_INVALIDARG);
    CHECK(range->SetValue(0) == S_OK && range->SetValue(10) == S_OK && zenit_uia_drain(binding) == 2);
    CHECK(range->SetValue(8) == S_OK);
    node.value_max = 6; CHECK(zenit_uia_publish(binding, &node, 1));
    unsigned calls = counter.calls; CHECK(zenit_uia_drain(binding) == 0 && counter.calls == calls); // Range changed after acceptance.
    node.state = 1; node.setters = 0; CHECK(zenit_uia_publish(binding, &node, 1));
    CHECK(range->get_IsReadOnly(&readonly) == S_OK && !readonly);
    CHECK(range->SetValue(3) == (HRESULT)UIA_E_ELEMENTNOTENABLED);
    node.state = 1u << 9; node.setters = 2; CHECK(zenit_uia_publish(binding, &node, 1));
    CHECK(range->get_IsReadOnly(&readonly) == S_OK && readonly);
    CHECK(range->SetValue(3) == (HRESULT)UIA_E_NOTSUPPORTED);
    node.state = 0; node.role = 8; node.setters = 0; CHECK(zenit_uia_publish(binding, &node, 1));
    CHECK(range->get_Value(&value) == S_OK && value == 5 && range->get_IsReadOnly(&readonly) == S_OK && readonly);
    CHECK(range->SetValue(3) == (HRESULT)UIA_E_NOTSUPPORTED); // ProgressBar readable, not writable.
    node.role = 7; node.setters = 2; CHECK(zenit_uia_publish(binding, &node, 1)); CHECK(range->SetValue(3) == S_OK);
    node.numeric = 0; CHECK(zenit_uia_publish(binding, &node, 1));
    CHECK(zenit_uia_drain(binding) == 0 && range->get_Value(&value) == (HRESULT)UIA_E_NOTSUPPORTED);
    node.numeric = 1; node.state = secure_state; CHECK(zenit_uia_publish(binding, &node, 1));
    CHECK(range->get_Value(&value) == (HRESULT)UIA_E_NOTSUPPORTED); // Numeric secure snapshot is suppressed.
    node.state = 0; CHECK(zenit_uia_publish(binding, &node, 1)); CHECK(range->SetValue(3) == S_OK);
    node.id = 0x02000009; CHECK(zenit_uia_publish(binding, &node, 1));
    CHECK(zenit_uia_drain(binding) == 0 && range->get_Value(&value) == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE);
    zenit_uia_destroy(binding);
    CHECK(range->SetValue(3) == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE);
    range->Release(); provider->Release();
    printf("Windows UIA RangeValue: %u checks; typed numeric actions, valid bounds and retained lifetime\n", checks-before);
}
static void a11y_provider_contract(HWND window) {
    using namespace zenit_uia;
    unsigned before = checks;
    auto *binding = (Binding *)zenit_uia_create(window); CHECK(binding); if (!binding) return;
    InputNode nodes[3] = {};
    nodes[0].id = 0; nodes[0].parent_index = no_parent; nodes[0].role = 37;
    nodes[0].width = 200; nodes[0].height = 100;
    nodes[1].id = 0x01000002; nodes[1].parent_index = 0; nodes[1].role = 2;
    nodes[1].name = {"保存 🧪", strlen("保存 🧪")}; nodes[1].description = {"Help", 4};
    nodes[1].identifier = {"save-action", 11};
    nodes[1].x = 10; nodes[1].y = 10; nodes[1].width = 60; nodes[1].height = 30;
    nodes[1].state = (1u << 12) | (1u << 13);
    nodes[2].id = 3; nodes[2].parent_index = 0; nodes[2].role = 10;
    nodes[2].state = secure_state | 1; nodes[2].x = 90; nodes[2].width = 60; nodes[2].height = 30;
    CHECK(zenit_uia_publish(binding, nodes, 3));
    auto *root = new Provider(binding, no_parent); CHECK(root);
    if (!root) { zenit_uia_destroy(binding); return; }
    IUnknown *identity = nullptr;
    CHECK(root->QueryInterface(IID_IUnknown, (void **)&identity) == S_OK); if (identity) identity->Release();
    ProviderOptions options;
    // Free-threaded: clients read the snapshot on their own threads (no STA hop).
    CHECK(root->get_ProviderOptions(&options) == S_OK && !(options & ProviderOptions_UseComThreading) && !!(options & ProviderOptions_ProviderOwnsSetFocus) == ((Binding *)binding)->preserve_foreground);
    IRawElementProviderFragment *group = nullptr, *button = nullptr, *edit = nullptr;
    CHECK(root->Navigate(NavigateDirection_FirstChild, &group) == S_OK && group);
    if (group) CHECK(group->Navigate(NavigateDirection_FirstChild, &button) == S_OK && button);
    if (button) CHECK(button->Navigate(NavigateDirection_NextSibling, &edit) == S_OK && edit);
    VARIANT property = {}; IRawElementProviderSimple *simple = nullptr;
    if (button) {
        CHECK(button->QueryInterface(IID_IRawElementProviderSimple, (void **)&simple) == S_OK && simple);
        void *invalid = (void *)1;
        CHECK(button->QueryInterface(IID_IRawElementProviderFragmentRoot, &invalid) == E_NOINTERFACE && !invalid);
        if (simple) {
            CHECK(simple->GetPropertyValue(UIA_NamePropertyId, &property) == S_OK && property.vt == VT_BSTR && !wcscmp(property.bstrVal, L"保存 🧪")); VariantClear(&property);
            CHECK(simple->GetPropertyValue(UIA_ControlTypePropertyId, &property) == S_OK && property.lVal == UIA_ButtonControlTypeId); VariantClear(&property);
            CHECK(simple->GetPropertyValue(UIA_AutomationIdPropertyId, &property) == S_OK && !wcscmp(property.bstrVal, L"save-action")); VariantClear(&property);
            CHECK(simple->GetPropertyValue(UIA_HelpTextPropertyId, &property) == S_OK && !wcscmp(property.bstrVal, L"Help")); VariantClear(&property);
            CHECK(simple->GetPropertyValue(UIA_HasKeyboardFocusPropertyId, &property) == S_OK && property.boolVal == VARIANT_FALSE); VariantClear(&property);
            IUnknown *pattern = (IUnknown *)1;
            CHECK(simple->GetPatternProvider(UIA_InvokePatternId, &pattern) == S_OK && !pattern);
            CHECK(simple->GetPropertyValue(UIA_NamePropertyId, nullptr) == E_POINTER);
        }
        SAFEARRAY *runtime = nullptr; CHECK(button->GetRuntimeId(&runtime) == S_OK && runtime);
        if (runtime) { LONG i = 2, raw = 0; CHECK(SafeArrayGetElement(runtime, &i, &raw) == S_OK && (uint32_t)raw == nodes[1].id); SafeArrayDestroy(runtime); }
        UiaRect bounds; CHECK(button->get_BoundingRectangle(&bounds) == S_OK);
        IRawElementProviderFragment *hit = nullptr;
        CHECK(root->ElementProviderFromPoint(bounds.left+1, bounds.top+1, &hit) == S_OK && hit); if (hit) hit->Release();
        IRawElementProviderFragment *focus = nullptr; CHECK(root->GetFocus(&focus) == S_OK && !focus); if (focus) focus->Release();
        CHECK(button->SetFocus() == (HRESULT)UIA_E_NOTSUPPORTED);
    }
    if (edit) {
        IRawElementProviderSimple *secure = nullptr;
        CHECK(edit->QueryInterface(IID_IRawElementProviderSimple, (void **)&secure) == S_OK && secure);
        if (secure) {
            CHECK(secure->GetPropertyValue(UIA_IsPasswordPropertyId, &property) == S_OK && property.boolVal == VARIANT_TRUE); VariantClear(&property);
            CHECK(secure->GetPropertyValue(UIA_IsEnabledPropertyId, &property) == S_OK && property.boolVal == VARIANT_FALSE); VariantClear(&property); secure->Release();
        }
        edit->Release();
    }
    CHECK(zenit_uia_publish(binding, nullptr, 0));
    if (simple) { CHECK(simple->GetPropertyValue(UIA_NamePropertyId, &property) == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE && property.vt == VT_EMPTY); simple->Release(); }
    if (button) { UiaRect r; CHECK(button->get_BoundingRectangle(&r) == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE); button->Release(); }
    if (group) group->Release();
    zenit_uia_destroy(binding);
    CHECK(root->GetPropertyValue(UIA_FrameworkIdPropertyId, &property) == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE);
    root->Release();
    printf("Windows UIA provider: %u checks\n", checks-before);
}

static void a11y_selection_contract(HWND window) {
    using namespace zenit_uia;
    unsigned before = checks;
    auto *binding = (Binding *)zenit_uia_create(window); CHECK(binding); if (!binding) return;
    InvokeCounter counter{GetCurrentThreadId()}; CHECK(zenit_uia_set_action_handler(binding, &counter, count_invoke));
    InputNode nodes[3] = {};
    nodes[0].id = 0x01000001; nodes[0].parent_index = no_parent; nodes[0].role = 5;
    nodes[1].id = 0x01000002; nodes[1].parent_index = 0; nodes[1].role = 4; nodes[1].actions = 1; nodes[1].state = 1u << 4;
    nodes[2].id = 0x01000003; nodes[2].parent_index = 0; nodes[2].role = 4; nodes[2].actions = 1;
    CHECK(zenit_uia_publish(binding, nodes, 3));
    auto *group = new Provider(binding, nodes[0].id); auto *item = new Provider(binding, nodes[2].id);
    BOOL flag = TRUE; CHECK(group->get_CanSelectMultiple(&flag) == S_OK && !flag);
    CHECK(group->get_IsSelectionRequired(&flag) == S_OK && flag);
    CHECK(item->get_IsSelected(&flag) == S_OK && !flag);
    CHECK(item->get_IsSelected(nullptr) == E_POINTER);
    IRawElementProviderSimple *container = nullptr; CHECK(item->get_SelectionContainer(&container) == S_OK && container);
    if (container) { VARIANT property = {}; CHECK(container->GetPropertyValue(UIA_ControlTypePropertyId, &property) == S_OK && property.lVal == UIA_GroupControlTypeId); VariantClear(&property); container->Release(); }
    SAFEARRAY *selected = nullptr; CHECK(group->GetSelection(&selected) == S_OK && selected);
    if (selected) {
        LONG bound = -1; CHECK(SafeArrayGetUBound(selected, 1, &bound) == S_OK && bound == 0);
        LONG index = 0; IUnknown *unknown = nullptr; CHECK(SafeArrayGetElement(selected, &index, &unknown) == S_OK && unknown);
        if (unknown) { IRawElementProviderSimple *simple = nullptr; CHECK(unknown->QueryInterface(IID_IRawElementProviderSimple, (void **)&simple) == S_OK && simple); if (simple) simple->Release(); unknown->Release(); }
        SafeArrayDestroy(selected);
    }
    IUnknown *pattern = nullptr; CHECK(item->GetPatternProvider(UIA_SelectionItemPatternId, &pattern) == S_OK && pattern);
    if (pattern) { ISelectionItemProvider *typed = nullptr; CHECK(pattern->QueryInterface(IID_ISelectionItemProvider, (void **)&typed) == S_OK && typed); if (typed) typed->Release(); pattern->Release(); }
    nodes[0].state = 1; CHECK(zenit_uia_publish(binding, nodes, 3));
    CHECK(item->Select() == (HRESULT)UIA_E_ELEMENTNOTENABLED);
    nodes[0].state = 0; nodes[2].state = 2; CHECK(zenit_uia_publish(binding, nodes, 3));
    CHECK(item->Select() == (HRESULT)UIA_E_NOTSUPPORTED);
    nodes[2].state = 0; CHECK(zenit_uia_publish(binding, nodes, 3));
    CHECK(item->AddToSelection() == (HRESULT)UIA_E_INVALIDOPERATION);
    CHECK(item->RemoveFromSelection() == S_OK);
    CHECK(item->Select() == S_OK && counter.calls == 0);
    CHECK(zenit_uia_drain(binding) == 1 && counter.last_action == 6 && !counter.wrong_thread);
    nodes[1].state = 0; nodes[2].state = 1u << 4; CHECK(zenit_uia_publish(binding, nodes, 3));
    CHECK(item->Select() == S_OK && item->AddToSelection() == S_OK && zenit_uia_drain(binding) == 0);
    CHECK(item->RemoveFromSelection() == (HRESULT)UIA_E_INVALIDOPERATION);
    nodes[2].state = 1; CHECK(zenit_uia_publish(binding, nodes, 3));
    CHECK(item->get_IsSelected(&flag) == S_OK && !flag);
    CHECK(item->Select() == (HRESULT)UIA_E_ELEMENTNOTENABLED);
    nodes[2].state = 1u << 9; CHECK(zenit_uia_publish(binding, nodes, 3)); CHECK(item->Select() == (HRESULT)UIA_E_NOTSUPPORTED);
    nodes[2].state = 0; CHECK(zenit_uia_publish(binding, nodes, 3)); CHECK(item->AddToSelection() == S_OK);
    CHECK(zenit_uia_drain(binding) == 1 && counter.last_action == 7 && !counter.wrong_thread);
    CHECK(item->AddToSelection() == S_OK);
    nodes[1].state = 1u << 4; CHECK(zenit_uia_publish(binding, nodes, 3)); CHECK(zenit_uia_drain(binding) == 0); // Conflict after acceptance.
    CHECK(item->Select() == S_OK); nodes[0].role = 37; CHECK(zenit_uia_publish(binding, nodes, 3)); CHECK(zenit_uia_drain(binding) == 0);
    CHECK(item->get_SelectionContainer(&container) == (HRESULT)UIA_E_NOTSUPPORTED && !container);
    pattern = nullptr; CHECK(item->GetPatternProvider(UIA_SelectionItemPatternId, &pattern) == S_OK && !pattern);
    nodes[0].role = 5; CHECK(zenit_uia_publish(binding, nodes, 3)); CHECK(item->Select() == S_OK);
    nodes[2].id = 0x02000003; CHECK(zenit_uia_publish(binding, nodes, 3)); CHECK(zenit_uia_drain(binding) == 0);
    CHECK(item->get_IsSelected(&flag) == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE);
    zenit_uia_destroy(binding); CHECK(group->GetSelection(&selected) == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE);
    item->Release(); group->Release();
    printf("Windows UIA Selection: %u checks; grouped radio ownership, conflicts and retained lifetime\n", checks-before);
}

static void a11y_multi_selection_contract(HWND window) {
    using namespace zenit_uia; unsigned before = checks;
    auto *binding = (Binding *)zenit_uia_create(window); CHECK(binding); if (!binding) return;
    InvokeCounter counter{GetCurrentThreadId()}; CHECK(zenit_uia_set_action_handler(binding, &counter, count_invoke));
    InputNode nodes[3] = {};
    nodes[0].id = 1; nodes[0].parent_index = no_parent; nodes[0].role = 14; nodes[0].state = 1u << 16;
    for (int i=1;i<3;i++) { nodes[i].id = i+1; nodes[i].parent_index = 0; nodes[i].role = 15; nodes[i].setters = 4; }
    nodes[1].state = 1u << 3; CHECK(zenit_uia_publish(binding, nodes, 3));
    auto *group = new Provider(binding, 1); auto *item = new Provider(binding, 3);
    BOOL flag = FALSE; CHECK(group->get_CanSelectMultiple(&flag) == S_OK && flag);
    CHECK(group->get_IsSelectionRequired(&flag) == S_OK && !flag);
    CHECK(item->AddToSelection() == S_OK && zenit_uia_drain(binding) == 1 && counter.last_action == 7);
    nodes[2].state = 1u << 3; CHECK(zenit_uia_publish(binding, nodes, 3));
    SAFEARRAY *selected = nullptr; CHECK(group->GetSelection(&selected) == S_OK && selected);
    if (selected) { LONG bound=-1; CHECK(SafeArrayGetUBound(selected,1,&bound) == S_OK && bound == 1); SafeArrayDestroy(selected); }
    CHECK(item->Select() == S_OK && zenit_uia_drain(binding) == 1 && counter.last_action == 6); // Already selected still replaces other selections.
    CHECK(item->RemoveFromSelection() == S_OK && zenit_uia_drain(binding) == 1 && counter.last_action == 8);
    nodes[0].state |= 1u << 7; nodes[1].state = 0; CHECK(zenit_uia_publish(binding, nodes, 3));
    CHECK(item->RemoveFromSelection() == (HRESULT)UIA_E_INVALIDOPERATION);
    nodes[0].state = 0; nodes[2].state = 0; CHECK(zenit_uia_publish(binding, nodes, 3));
    CHECK(item->RemoveFromSelection() == S_OK && zenit_uia_drain(binding) == 0);
    nodes[1].state = 1u << 3; CHECK(zenit_uia_publish(binding, nodes, 3)); CHECK(item->AddToSelection() == (HRESULT)UIA_E_INVALIDOPERATION);
    nodes[0].role = 16; nodes[1].role = nodes[2].role = 17; nodes[2].parent_index = 1;
    CHECK(zenit_uia_publish(binding, nodes, 3));
    IRawElementProviderSimple *container=nullptr; CHECK(item->get_SelectionContainer(&container) == S_OK && container); if(container)container->Release();
    CHECK(item->Select() == S_OK && zenit_uia_drain(binding) == 1);
    nodes[2].setters = 0; CHECK(zenit_uia_publish(binding,nodes,3)); CHECK(item->Select() == (HRESULT)UIA_E_NOTSUPPORTED);
    zenit_uia_destroy(binding); CHECK(group->GetSelection(&selected) == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE);
    item->Release(); group->Release(); printf("Windows UIA multi selection: %u checks; List/Tree model actions and selection constraints\n",checks-before);
}

static void a11y_expansion_contract(HWND window) {
    using namespace zenit_uia; unsigned before = checks;
    auto *binding = (Binding *)zenit_uia_create(window); CHECK(binding); if (!binding) return;
    InvokeCounter counter{GetCurrentThreadId()}; CHECK(zenit_uia_set_action_handler(binding, &counter, count_invoke));
    InputNode node = {}; node.id = 1; node.parent_index = no_parent; node.role = 13;
    node.state = 1u << 18; node.setters = 8; CHECK(zenit_uia_publish(binding, &node, 1));
    auto *provider = new Provider(binding, 1);
    IUnknown *pattern = nullptr; CHECK(provider->GetPatternProvider(UIA_ExpandCollapsePatternId, &pattern) == S_OK && pattern);
    IExpandCollapseProvider *expansion = nullptr;
    if (pattern) { CHECK(pattern->QueryInterface(IID_IExpandCollapseProvider, (void **)&expansion) == S_OK && expansion); pattern->Release(); }
    ExpandCollapseState state = ExpandCollapseState_LeafNode;
    CHECK(provider->get_ExpandCollapseState(nullptr) == E_POINTER);
    CHECK(provider->get_ExpandCollapseState(&state) == S_OK && state == ExpandCollapseState_Collapsed);
    CHECK(provider->Expand() == S_OK && zenit_uia_drain(binding) == 1 && counter.last_action == 9);
    node.state |= 1u << 2; CHECK(zenit_uia_publish(binding, &node, 1));
    CHECK(provider->get_ExpandCollapseState(&state) == S_OK && state == ExpandCollapseState_Expanded);
    CHECK(provider->Collapse() == S_OK && zenit_uia_drain(binding) == 1 && counter.last_action == 10);
    CHECK(provider->Expand() == S_OK);
    node.state |= 1; CHECK(zenit_uia_publish(binding, &node, 1));
    CHECK(zenit_uia_drain(binding) == 0); CHECK(provider->Expand() == (HRESULT)UIA_E_ELEMENTNOTENABLED);
    node.state = (1u << 18) | (1u << 9); CHECK(zenit_uia_publish(binding, &node, 1));
    CHECK(provider->Collapse() == (HRESULT)UIA_E_NOTSUPPORTED);
    node.state = 0; node.role = 17; node.setters = 0; CHECK(zenit_uia_publish(binding, &node, 1));
    pattern = nullptr; CHECK(provider->GetPatternProvider(UIA_ExpandCollapsePatternId, &pattern) == S_OK && !pattern);
    CHECK(provider->get_ExpandCollapseState(&state) == (HRESULT)UIA_E_NOTSUPPORTED);
    CHECK(provider->Expand() == (HRESULT)UIA_E_NOTSUPPORTED);
    zenit_uia_destroy(binding);
    if (expansion) { CHECK(expansion->get_ExpandCollapseState(&state) == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE); CHECK(expansion->Collapse() == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE); expansion->Release(); }
    provider->Release();
    printf("Windows UIA ExpandCollapse: %u checks; explicit actions, disabled pending requests, leaf capability and retained lifetime\n", checks-before);
}

struct TextRangeReader { ITextRangeProvider *range; unsigned errors = 0; };
static DWORD WINAPI text_range_reader(void *opaque) {
    auto *reader = (TextRangeReader *)opaque;
    BSTR query = SysAllocString(L"中😀");
    if (!query) { ++reader->errors; return 0; }
    for (unsigned i = 0; i < 200; ++i) {
        BSTR text = nullptr; ITextRangeProvider *clone = nullptr; BOOL equal = FALSE;
        if (reader->range->GetText(-1, &text) != S_OK || !text || wcscmp(text, L"A中😀B")) ++reader->errors;
        SysFreeString(text);
        if (reader->range->Clone(&clone) != S_OK || !clone) ++reader->errors;
        else { if (clone->Compare(reader->range, &equal) != S_OK || !equal) ++reader->errors; clone->Release(); }
        ITextRangeProvider *match = nullptr;
        if (reader->range->FindText(query, FALSE, FALSE, &match) != S_OK || !match) ++reader->errors;
        else {
            text = nullptr;
            if (match->GetText(-1, &text) != S_OK || !text || wcscmp(text, L"中😀")) ++reader->errors;
            SysFreeString(text); match->Release();
        }

    }
    SysFreeString(query);
    return 0;
}
__attribute__((no_sanitize("enum"))) static void a11y_text_range_contract(HWND window) {
    using namespace zenit_uia;
    unsigned before = checks;
    auto *binding = (Binding *)zenit_uia_create(window); CHECK(binding); if (!binding) return;
    InvokeCounter counter{GetCurrentThreadId()};
    CHECK(zenit_uia_set_action_handler(binding, &counter, count_invoke));
    InputNode node = {}; node.id = 0x01000003; node.parent_index = no_parent; node.role = 10;
    node.editable = node.can_set_selection = 1; node.setters = 1;
    node.value = {"A中😀B", 9}; node.visible_end = UINT32_MAX;
    CHECK(zenit_uia_publish(binding, &node, 1));
    ITextRangeProvider *full = nullptr, *part = nullptr, *clone = nullptr;
    CHECK(TextRange::create(binding, node.id, 0, 5, &full) == S_OK && full);
    CHECK(TextRange::create(binding, node.id, 4, 1, &part) == S_OK && part);
    if (!full || !part) { if (full) full->Release(); if (part) part->Release(); zenit_uia_destroy(binding); return; }
    ITextRangeProvider *bad = (ITextRangeProvider *)1;
    CHECK(TextRange::create(binding, node.id, 3, 4, &bad) == E_INVALIDARG && !bad);
    CHECK(TextRange::create(binding, node.id, 0, 6, &bad) == E_INVALIDARG && !bad);
    CHECK(TextRange::create(binding, node.id, 0, 0, nullptr) == E_POINTER);
    BSTR text = nullptr;
    CHECK(full->GetText(-1, &text) == S_OK && text && !wcscmp(text, L"A中😀B")); SysFreeString(text);
    CHECK(full->GetText(3, &text) == S_OK && SysStringLen(text) == 2 && !wcscmp(text, L"A中")); SysFreeString(text);
    CHECK(full->GetText(4, &text) == S_OK && SysStringLen(text) == 4 && !wcscmp(text, L"A中😀")); SysFreeString(text);
    CHECK(part->GetText(-1, &text) == S_OK && !wcscmp(text, L"中😀")); SysFreeString(text);
    CHECK(full->GetText(0, &text) == S_OK && SysStringLen(text) == 0); SysFreeString(text);
    text = (BSTR)1; CHECK(full->GetText(-2, &text) == E_INVALIDARG && !text);
    CHECK(full->GetText(-1, nullptr) == E_POINTER);
    CHECK(part->Clone(&clone) == S_OK && clone);
    if (!clone) { part->Release(); full->Release(); zenit_uia_destroy(binding); return; }
    TextRangeReader readers[2] = {{full}, {full}}; HANDLE threads[2] = {};
    for (unsigned i = 0; i < 2; ++i) { threads[i] = CreateThread(nullptr, 0, text_range_reader, &readers[i], 0, nullptr); CHECK(threads[i]); }
    for (unsigned i = 0; i < 100; ++i) CHECK(zenit_uia_publish(binding, &node, 1));
    for (unsigned i = 0; i < 2; ++i) if (threads[i]) { CHECK(WaitForSingleObject(threads[i], INFINITE) == WAIT_OBJECT_0); CHECK(readers[i].errors == 0); CloseHandle(threads[i]); }
    BOOL equal = FALSE; CHECK(clone && clone->Compare(part, &equal) == S_OK && equal);
    CHECK(part->Compare(full, &equal) == S_OK && !equal);
    CHECK(part->Compare(nullptr, &equal) == E_INVALIDARG && !equal);
    CHECK(part->Compare(full, nullptr) == E_POINTER);
    int delta = 99;
    CHECK(part->CompareEndpoints(TextPatternRangeEndpoint_Start, full, TextPatternRangeEndpoint_End, &delta) == S_OK && delta < 0);
    CHECK(part->CompareEndpoints(TextPatternRangeEndpoint_End, full, TextPatternRangeEndpoint_Start, &delta) == S_OK && delta > 0);
    CHECK(part->CompareEndpoints((TextPatternRangeEndpoint)2, full, TextPatternRangeEndpoint_End, &delta) == E_INVALIDARG && !delta);
    CHECK(part->MoveEndpointByRange(TextPatternRangeEndpoint_Start, full, TextPatternRangeEndpoint_End) == S_OK);
    CHECK(part->GetText(-1, &text) == S_OK && SysStringLen(text) == 0); SysFreeString(text);
    CHECK(part->CompareEndpoints(TextPatternRangeEndpoint_End, full, TextPatternRangeEndpoint_End, &delta) == S_OK && !delta);
    CHECK(part->MoveEndpointByRange(TextPatternRangeEndpoint_End, full, TextPatternRangeEndpoint_Start) == S_OK);
    CHECK(part->CompareEndpoints(TextPatternRangeEndpoint_Start, full, TextPatternRangeEndpoint_Start, &delta) == S_OK && !delta);
    CHECK(clone && clone->GetText(-1, &text) == S_OK && !wcscmp(text, L"中😀")); SysFreeString(text);
    IUnknown *one = nullptr, *two = nullptr; RangeState *state = nullptr;
    CHECK(full->QueryInterface(IID_IUnknown, (void **)&one) == S_OK);
    CHECK(full->QueryInterface(range_state_iid, (void **)&state) == S_OK);
    CHECK(state && state->QueryInterface(IID_IUnknown, (void **)&two) == S_OK && one == two);
    if (one) one->Release(); if (two) two->Release(); if (state) state->Release();
    IRawElementProviderSimple *enclosing = nullptr;
    CHECK(full->GetEnclosingElement(&enclosing) == S_OK && enclosing);
    IUnknown *advertised = (IUnknown *)1;
    CHECK(enclosing && enclosing->GetPatternProvider(UIA_TextPatternId, &advertised) == S_OK && !advertised);
    if (enclosing) enclosing->Release();
    SAFEARRAY *children = nullptr; CHECK(full->GetChildren(&children) == S_OK && children);
    if (children) { VARTYPE type = VT_EMPTY; CHECK(SafeArrayGetVartype(children, &type) == S_OK && type == VT_UNKNOWN); SafeArrayDestroy(children); }
    VARIANT attribute = {}; CHECK(full->GetAttributeValue(UIA_IsReadOnlyAttributeId, &attribute) == S_OK && attribute.vt == VT_BOOL && !attribute.boolVal); VariantClear(&attribute);
    CHECK(full->GetAttributeValue(UIA_FontSizeAttributeId, &attribute) == S_OK && attribute.vt == VT_UNKNOWN && attribute.punkVal); VariantClear(&attribute);
    CHECK(clone && clone->Select() == S_OK && counter.calls == 0);
    CHECK(zenit_uia_drain(binding) == 1 && counter.calls == 1 && counter.last_action == 11 && counter.wrong_thread == 0);
    uint32_t offsets[2] = {}; memcpy(offsets, counter.text, 8);
    CHECK(offsets[0] == 1 && offsets[1] == 8 && counter.text_length == 17 && !memcmp(counter.text+8, "A中😀B", 9));
    CHECK(part->Select() == S_OK); CHECK(zenit_uia_drain(binding) == 1 && counter.calls == 2);
    node.state = 1u << 9; node.can_set_selection = 0;
    CHECK(zenit_uia_publish(binding, &node, 1));
    CHECK(full->GetText(-1, &text) == S_OK); SysFreeString(text);
    CHECK(full->Select() == (HRESULT)UIA_E_NOTSUPPORTED);
    CHECK(full->GetAttributeValue(UIA_IsReadOnlyAttributeId, &attribute) == S_OK && attribute.boolVal); VariantClear(&attribute);
    node.can_set_selection = 1; CHECK(zenit_uia_publish(binding, &node, 1));
    CHECK(full->Select() == S_OK);
    CHECK(zenit_uia_drain(binding) == 1 && counter.calls == 3 && counter.last_action == 11);
    memcpy(offsets, counter.text, 8); CHECK(offsets[0] == 0 && offsets[1] == 9);
    node.state = 0; node.can_set_selection = 1;
    auto *other_binding = (Binding *)zenit_uia_create(window); CHECK(other_binding);
    if (other_binding) {
        CHECK(zenit_uia_publish(other_binding, &node, 1));
        ITextRangeProvider *foreign = nullptr; CHECK(TextRange::create(other_binding, node.id, 0, 5, &foreign) == S_OK);
        if (foreign) { CHECK(full->Compare(foreign, &equal) == E_INVALIDARG); CHECK(full->MoveEndpointByRange(TextPatternRangeEndpoint_Start, foreign, TextPatternRangeEndpoint_End) == E_INVALIDARG); foreign->Release(); }
        zenit_uia_destroy(other_binding);
    }
    node.value = {"A中😁B", 9}; CHECK(zenit_uia_publish(binding, &node, 1));
    text = (BSTR)1; CHECK(full->GetText(-1, &text) == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE && !text);
    CHECK(full->Select() == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE);
    CHECK(binding->enqueue_selection(node.id, 1, 4, L"A中😀B") == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE);
    node.state = secure_state; CHECK(zenit_uia_publish(binding, &node, 1));
    CHECK(TextRange::create(binding, node.id, 0, 0, &bad) == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE && !bad);
    CHECK(full->GetEnclosingElement(&enclosing) == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE && !enclosing);
    zenit_uia_destroy(binding);
    CHECK(full->Clone(&bad) == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE && !bad);
    CHECK(full->Select() == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE);
    CHECK(full->GetChildren(&children) == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE && !children);
    if (clone) clone->Release(); part->Release(); full->Release();
    printf("Windows UIA TextRange core: %u checks; Unicode reads, COM identity, clone, endpoints, queued selection, concurrent reads and stale/disconnected ownership\n", checks-before);
}

static void a11y_text_search_contract(HWND window) {
    using namespace zenit_uia;
    unsigned before = checks;
    auto *binding = (Binding *)zenit_uia_create(window); CHECK(binding); if (!binding) return;
    InputNode node = {}; node.id = 0x01000004; node.parent_index = no_parent; node.role = 10;
    node.editable = node.can_set_selection = 1; node.setters = 1; node.visible_end = UINT32_MAX;
    const char sample[] = "Ab中😀 ab中😀 AB中😀"; node.value = {sample, sizeof(sample)-1};
    CHECK(zenit_uia_publish(binding, &node, 1));
    ITextRangeProvider *full = nullptr, *part = nullptr;
    CHECK(TextRange::create(binding, node.id, 0, 17, &full) == S_OK && full);
    CHECK(TextRange::create(binding, node.id, 6, 11, &part) == S_OK && part);
    if (!full || !part) { if (full) full->Release(); if (part) part->Release(); zenit_uia_destroy(binding); return; }
    auto find = [&](ITextRangeProvider *source, const wchar_t *needle, BOOL backward, BOOL insensitive, int expected_first, int expected_last) {
        BSTR query = SysAllocString(needle); CHECK(query); if (!query) return;
        ITextRangeProvider *match = (ITextRangeProvider *)1;
        CHECK(source->FindText(query, backward, insensitive, &match) == S_OK);
        SysFreeString(query);
        if (expected_first < 0) { CHECK(!match); if (match && match != (ITextRangeProvider *)1) match->Release(); return; }
        CHECK(match && match != (ITextRangeProvider *)1); if (!match || match == (ITextRangeProvider *)1) return;
        RangeState *state = nullptr; CHECK(match->QueryInterface(range_state_iid, (void **)&state) == S_OK && state);
        if (state) { LONG identity = 0; uint32_t id = 0, first = 0, last = 0;
            CHECK(state->Read(&identity, &id, &first, &last) == S_OK && first == (uint32_t)expected_first && last == (uint32_t)expected_last);
            state->Release(); }
        BSTR text = nullptr; CHECK(match->GetText(-1, &text) == S_OK && text && SysStringLen(text) == (UINT)(expected_last-expected_first)); SysFreeString(text);
        match->Release();
    };
    find(full, L"ab中😀", FALSE, FALSE, 6, 11);
    find(full, L"ab中😀", FALSE, TRUE, 0, 5);
    find(full, L"ab中😀", TRUE, TRUE, 12, 17);
    find(full, L"中😀", FALSE, FALSE, 2, 5);
    find(full, L"中😀", TRUE, FALSE, 14, 17);
    find(part, L"AB", FALSE, TRUE, 6, 8);
    find(part, L"Ab", FALSE, FALSE, -1, -1);
    find(part, L"😀 ab", FALSE, FALSE, -1, -1);
    find(full, L"missing", FALSE, FALSE, -1, -1);
    ITextRangeProvider *match = (ITextRangeProvider *)1;
    CHECK(full->FindText(nullptr, FALSE, FALSE, &match) == E_INVALIDARG && !match);
    BSTR query = SysAllocString(L""); CHECK(query);
    CHECK(full->FindText(query, FALSE, FALSE, &match) == E_INVALIDARG && !match); SysFreeString(query);
    const wchar_t broken[] = {0xdc00}; query = SysAllocStringLen(broken, 1); CHECK(query);
    CHECK(full->FindText(query, FALSE, FALSE, &match) == E_INVALIDARG && !match); SysFreeString(query);
    const wchar_t embedded[] = {L'a', L'b', 0, L'中'}; query = SysAllocStringLen(embedded, 4); CHECK(query);
    CHECK(full->FindText(query, FALSE, FALSE, &match) == S_OK && !match); SysFreeString(query);
    query = SysAllocString(L"中"); CHECK(query);
    CHECK(full->FindText(query, FALSE, FALSE, nullptr) == E_POINTER);
    ITextRangeProvider *caret = nullptr; CHECK(TextRange::create(binding, node.id, 1, 1, &caret) == S_OK && caret);
    if (caret) { CHECK(caret->FindText(query, FALSE, FALSE, &match) == S_OK && !match); caret->Release(); }
    VARIANT attribute = {}; attribute.vt = VT_BOOL; attribute.boolVal = VARIANT_FALSE;
    CHECK(part->FindAttribute(UIA_IsReadOnlyAttributeId, attribute, TRUE, &match) == S_OK && match);
    if (match) { BOOL equal = FALSE; CHECK(match->Compare(part, &equal) == S_OK && equal); match->Release(); }
    attribute.boolVal = VARIANT_TRUE;
    CHECK(full->FindAttribute(UIA_IsReadOnlyAttributeId, attribute, FALSE, &match) == S_OK && !match);
    attribute.vt = VT_I4; attribute.lVal = 0;
    CHECK(full->FindAttribute(UIA_IsReadOnlyAttributeId, attribute, FALSE, &match) == E_INVALIDARG && !match);
    CHECK(full->FindAttribute(UIA_FontSizeAttributeId, attribute, FALSE, &match) == S_OK && !match);
    CHECK(full->FindAttribute(UIA_IsReadOnlyAttributeId, attribute, FALSE, nullptr) == E_POINTER);
    node.state = 1u << 9; node.can_set_selection = 0; CHECK(zenit_uia_publish(binding, &node, 1));
    attribute.vt = VT_BOOL; attribute.boolVal = VARIANT_TRUE;
    CHECK(full->FindAttribute(UIA_IsReadOnlyAttributeId, attribute, FALSE, &match) == S_OK && match);
    if (match) match->Release();
    node.value = {"aaaa", 4}; CHECK(zenit_uia_publish(binding, &node, 1));
    CHECK(full->FindText(query, FALSE, FALSE, &match) == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE && !match);
    CHECK(full->FindAttribute(UIA_IsReadOnlyAttributeId, attribute, FALSE, &match) == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE && !match);
    ITextRangeProvider *overlap = nullptr; CHECK(TextRange::create(binding, node.id, 0, 4, &overlap) == S_OK && overlap);
    if (overlap) { find(overlap, L"aaa", FALSE, FALSE, 0, 3); find(overlap, L"aaa", TRUE, FALSE, 1, 4); overlap->Release(); }
    const char accents[] = "e\u0301 É"; node.value = {accents, sizeof(accents)-1}; CHECK(zenit_uia_publish(binding, &node, 1));
    ITextRangeProvider *accent = nullptr; CHECK(TextRange::create(binding, node.id, 0, 4, &accent) == S_OK && accent);
    if (accent) { find(accent, L"é", FALSE, TRUE, 3, 4); find(accent, L"e\u0301", FALSE, TRUE, 0, 2); accent->Release(); }
    zenit_uia_destroy(binding);
    CHECK(part->FindText(query, FALSE, FALSE, &match) == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE && !match);
    CHECK(part->FindAttribute(UIA_IsReadOnlyAttributeId, attribute, FALSE, &match) == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE && !match);
    SysFreeString(query); part->Release(); full->Release();
    printf("Windows UIA TextRange search: %u checks; forward/backward, case, Unicode, subrange, overlap, attributes and stale ownership\n", checks-before);
}

__attribute__((no_sanitize("enum"))) static void a11y_character_contract(HWND window) {
    using namespace zenit_uia;
    unsigned before = checks;
    auto *binding = (Binding *)zenit_uia_create(window); CHECK(binding); if (!binding) return;
    InputNode node = {}; node.id = 0x01000005; node.parent_index = no_parent; node.role = 10;
    node.editable = node.can_set_selection = 1; node.setters = 1; node.visible_end = UINT32_MAX;
    const char value[] = "e\u0301👩‍💻🇨🇳\r\n"; node.value = {value, sizeof(value)-1};
    uint32_t boundaries[] = {0,3,14,22,24}; node.characters = {boundaries, 5};
    CHECK(zenit_uia_publish(binding, &node, 1));
    auto *snapshot = binding->context->acquire(); CHECK(snapshot);
    if (snapshot) { const Node *n = snapshot->find(node.id); const uint32_t expected[] = {0,2,7,11,13}; CHECK(n && n->character_count == 5 && !memcmp(n->characters, expected, sizeof(expected))); snapshot->release(); }
    ITextRangeProvider *range = nullptr; CHECK(TextRange::create(binding, node.id, 1, 1, &range) == S_OK && range);
    if (!range) { zenit_uia_destroy(binding); return; }
    auto positions = [&](uint32_t first, uint32_t last) {
        RangeState *state = nullptr; CHECK(range->QueryInterface(range_state_iid, (void **)&state) == S_OK && state);
        if (state) { LONG identity; uint32_t id, a, b; CHECK(state->Read(&identity, &id, &a, &b) == S_OK && a == first && b == last); state->Release(); }
    };
    CHECK(range->ExpandToEnclosingUnit(TextUnit_Character) == S_OK); positions(0,2);
    int moved = 99;
    CHECK(range->MoveEndpointByUnit(TextPatternRangeEndpoint_Start, TextUnit_Character, 2, &moved) == S_OK && moved == 2); positions(7,7);
    CHECK(range->ExpandToEnclosingUnit(TextUnit_Character) == S_OK); positions(7,11);
    BSTR text = nullptr; CHECK(range->GetText(-1, &text) == S_OK && text && !wcscmp(text, L"🇨🇳")); SysFreeString(text);
    CHECK(range->MoveEndpointByUnit(TextPatternRangeEndpoint_End, TextUnit_Character, INT_MAX, &moved) == S_OK && moved == 1); positions(7,13);
    CHECK(range->MoveEndpointByUnit(TextPatternRangeEndpoint_End, TextUnit_Character, 1, &moved) == S_OK && moved == 0);
    CHECK(range->MoveEndpointByUnit(TextPatternRangeEndpoint_Start, TextUnit_Character, INT_MIN, &moved) == S_OK && moved == -2); positions(0,13);
    CHECK(range->MoveEndpointByUnit(TextPatternRangeEndpoint_Start, TextUnit_Character, -1, &moved) == S_OK && moved == 0);
    CHECK(range->MoveEndpointByUnit(TextPatternRangeEndpoint_End, TextUnit_Document, -1, &moved) == S_OK && moved == -1); positions(0,0);
    CHECK(range->MoveEndpointByUnit(TextPatternRangeEndpoint_Start, TextUnit_Document, 1, &moved) == S_OK && moved == 1); positions(13,13);
    CHECK(range->ExpandToEnclosingUnit(TextUnit_Character) == S_OK); positions(11,13);
    CHECK(range->GetText(-1, &text) == S_OK && !wcscmp(text, L"\r\n")); SysFreeString(text);
    CHECK(range->ExpandToEnclosingUnit(TextUnit_Document) == S_OK); positions(0,13);
    CHECK(range->MoveEndpointByUnit(TextPatternRangeEndpoint_End, TextUnit_Character, 0, &moved) == S_OK && moved == 0); positions(0,13);
    CHECK(range->MoveEndpointByUnit((TextPatternRangeEndpoint)2, TextUnit_Character, 1, &moved) == E_INVALIDARG && moved == 0);
    CHECK(range->ExpandToEnclosingUnit((TextUnit)8) == E_INVALIDARG);
    CHECK(range->MoveEndpointByUnit(TextPatternRangeEndpoint_End, (TextUnit)8, 1, &moved) == E_INVALIDARG && moved == 0);
    CHECK(range->MoveEndpointByUnit(TextPatternRangeEndpoint_End, TextUnit_Character, 1, nullptr) == E_POINTER);
    // Owned boundary data survives mutation of the borrowed input table.
    boundaries[1] = 1; CHECK(range->ExpandToEnclosingUnit(TextUnit_Character) == S_OK); positions(0,2);
    boundaries[1] = 2; CHECK(!zenit_uia_publish(binding, &node, 1)); // Inside combining scalar.
    boundaries[1] = 0; CHECK(!zenit_uia_publish(binding, &node, 1));
    boundaries[1] = 3; boundaries[4] = 25; CHECK(!zenit_uia_publish(binding, &node, 1)); boundaries[4] = 24;
    node.characters = {nullptr,5}; CHECK(!zenit_uia_publish(binding, &node, 1));
    node.characters = {boundaries,26}; CHECK(!zenit_uia_publish(binding, &node, 1));
    CHECK(range->ExpandToEnclosingUnit(TextUnit_Character) == S_OK); positions(0,2);
    node.value = {"",0}; uint32_t empty[] = {0}; node.characters = {empty,1}; CHECK(zenit_uia_publish(binding, &node, 1));
    ITextRangeProvider *blank = nullptr; CHECK(TextRange::create(binding, node.id, 0, 0, &blank) == S_OK && blank);
    if (blank) { CHECK(blank->ExpandToEnclosingUnit(TextUnit_Character) == S_OK); CHECK(blank->MoveEndpointByUnit(TextPatternRangeEndpoint_End, TextUnit_Character, INT_MAX, &moved) == S_OK && moved == 0); blank->Release(); }
    node.state = secure_state; node.characters = {nullptr,SIZE_MAX}; CHECK(zenit_uia_publish(binding, &node, 1));
    snapshot = binding->context->acquire(); CHECK(snapshot);
    if (snapshot) { const Node *n = snapshot->find(node.id); CHECK(n && !n->character_count && !n->characters); snapshot->release(); }
    CHECK(range->ExpandToEnclosingUnit(TextUnit_Character) == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE);
    zenit_uia_destroy(binding);
    CHECK(range->MoveEndpointByUnit(TextPatternRangeEndpoint_End, TextUnit_Document, 1, &moved) == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE && moved == 0);
    range->Release();
    printf("Windows UIA Character units: %u checks; owned graphemes, combining/ZWJ/flag/CRLF, bounds, collapse, empty and redaction\n", checks-before);
}

__attribute__((no_sanitize("enum"))) static void a11y_text_move_contract(HWND window) {
    using namespace zenit_uia;
    unsigned before = checks;
    auto *binding = (Binding *)zenit_uia_create(window); CHECK(binding); if (!binding) return;
    InputNode node = {}; node.id = 0x01000006; node.parent_index = no_parent; node.role = 10;
    node.editable = node.can_set_selection = 1; node.setters = 1; node.visible_end = UINT32_MAX;
    const char value[] = "e\u0301👩‍💻🇨🇳\r\n"; node.value = {value, sizeof(value)-1};
    const uint32_t boundaries[] = {0,3,14,22,24}; node.characters = {boundaries,5};
    CHECK(zenit_uia_publish(binding, &node, 1));
    ITextRangeProvider *range = nullptr;
    CHECK(TextRange::create(binding, node.id, 0, 13, &range) == S_OK && range);
    if (!range) { zenit_uia_destroy(binding); return; }
    auto positions = [&](uint32_t first, uint32_t last) {
        RangeState *state = nullptr; CHECK(range->QueryInterface(range_state_iid, (void **)&state) == S_OK && state);
        if (state) { LONG identity; uint32_t id, a, b; CHECK(state->Read(&identity, &id, &a, &b) == S_OK && a == first && b == last); state->Release(); }
    };
    int moved = 99;
    CHECK(range->Move(TextUnit_Character, 0, &moved) == S_OK && moved == 0); positions(0,13);
    CHECK(range->Move(TextUnit_Character, -1, &moved) == S_OK && moved == 0); positions(0,13); // No partial normalization on failure.
    CHECK(range->Move(TextUnit_Document, 1, &moved) == S_OK && moved == 0); positions(0,13);
    CHECK(range->Move(TextUnit_Character, 1, &moved) == S_OK && moved == 1); positions(2,7);
    BSTR text = nullptr; CHECK(range->GetText(-1, &text) == S_OK && text && !wcscmp(text,L"👩‍💻")); SysFreeString(text);
    CHECK(range->Move(TextUnit_Character, 1, &moved) == S_OK && moved == 1); positions(7,11);
    CHECK(range->Move(TextUnit_Character, INT_MAX, &moved) == S_OK && moved == 1); positions(11,13);
    CHECK(range->Move(TextUnit_Character, 1, &moved) == S_OK && moved == 0); positions(11,13);
    CHECK(range->Move(TextUnit_Character, INT_MIN, &moved) == S_OK && moved == -3); positions(0,2);
    range->Release(); range = nullptr;
    CHECK(TextRange::create(binding, node.id, 1,11,&range) == S_OK && range);
    if (range) {
        CHECK(range->Move(TextUnit_Character,0,&moved) == S_OK && moved == 0); positions(1,11);
        CHECK(range->Move(TextUnit_Document,-1,&moved) == S_OK && moved == 0); positions(1,11);
        CHECK(range->Move(TextUnit_Character,1,&moved) == S_OK && moved == 1); positions(2,7);
        range->Release();
    }
    range = nullptr; CHECK(TextRange::create(binding,node.id,1,1,&range) == S_OK && range);
    if (range) {
        CHECK(range->Move(TextUnit_Character,1,&moved) == S_OK && moved == 1); positions(2,2);
        CHECK(range->Move(TextUnit_Character,-1,&moved) == S_OK && moved == -1); positions(0,0);
        CHECK(range->Move(TextUnit_Character,INT_MAX,&moved) == S_OK && moved == 4); positions(13,13);
        CHECK(range->Move(TextUnit_Character,1,&moved) == S_OK && moved == 0); positions(13,13);
        CHECK(range->Move(TextUnit_Character,INT_MIN,&moved) == S_OK && moved == -4); positions(0,0);
        CHECK(range->Move(TextUnit_Document,INT_MAX,&moved) == S_OK && moved == 1); positions(13,13);
        CHECK(range->Move(TextUnit_Document,INT_MIN,&moved) == S_OK && moved == -1); positions(0,0);
        CHECK(range->Move((TextUnit)8,1,&moved) == E_INVALIDARG && moved == 0); positions(0,0);
        CHECK(range->Move(TextUnit_Character,1,nullptr) == E_POINTER); positions(0,0);
    }
    node.value = {"",0}; const uint32_t empty[] = {0}; node.characters = {empty,1}; CHECK(zenit_uia_publish(binding,&node,1));
    if (range) { CHECK(range->Move(TextUnit_Character,1,&moved) == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE && moved == 0); range->Release(); }
    range = nullptr; CHECK(TextRange::create(binding,node.id,0,0,&range) == S_OK && range);
    if (range) { CHECK(range->Move(TextUnit_Character,INT_MAX,&moved) == S_OK && moved == 0); positions(0,0); CHECK(range->Move(TextUnit_Document,INT_MIN,&moved) == S_OK && moved == 0); }
    zenit_uia_destroy(binding);
    if (range) { CHECK(range->Move(TextUnit_Character,0,&moved) == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE && moved == 0); range->Release(); }
    printf("Windows UIA whole-range Move: %u checks; normalization, preserved failures, graphemes, caret, limits and stale ownership\n", checks-before);
}

static void a11y_text_selection_operations_contract(HWND window) {
    using namespace zenit_uia;
    unsigned before = checks;
    auto *binding = (Binding *)zenit_uia_create(window); CHECK(binding); if (!binding) return;
    InputNode node = {}; node.id = 0x01000007; node.parent_index = no_parent; node.role = 10;
    node.editable = node.can_set_selection = 1; node.setters = 1; node.visible_end = UINT32_MAX;
    node.value = {"A中😀B",9}; node.selection_start = 1; node.selection_end = node.caret = 8;
    CHECK(zenit_uia_publish(binding,&node,1));
    ITextRangeProvider *span = nullptr, *caret = nullptr;
    CHECK(TextRange::create(binding,node.id,1,4,&span) == S_OK && span);
    CHECK(TextRange::create(binding,node.id,2,2,&caret) == S_OK && caret);
    if (!span || !caret) { if (span) span->Release(); if (caret) caret->Release(); zenit_uia_destroy(binding); return; }
    CHECK(span->AddToSelection() == (HRESULT)UIA_E_NOTSUPPORTED); // No owner handler yet.
    CHECK(caret->RemoveFromSelection() == (HRESULT)UIA_E_NOTSUPPORTED);
    InvokeCounter counter{GetCurrentThreadId()}; CHECK(zenit_uia_set_action_handler(binding,&counter,count_invoke));
    CHECK(span->AddToSelection() == (HRESULT)UIA_E_INVALIDOPERATION);
    CHECK(span->RemoveFromSelection() == (HRESULT)UIA_E_INVALIDOPERATION);
    CHECK(zenit_uia_drain(binding) == 0 && counter.calls == 0);
    auto *snapshot = binding->context->acquire(); CHECK(snapshot);
    if (snapshot) { const Node *n = snapshot->find(node.id); CHECK(n && n->selection_start == 1 && n->selection_end == 4 && n->caret == 4); snapshot->release(); }
    CHECK(caret->AddToSelection() == S_OK && counter.calls == 0);
    CHECK(zenit_uia_drain(binding) == 1 && counter.calls == 1 && counter.last_action == 11 && counter.wrong_thread == 0);
    uint32_t offsets[2] = {}; memcpy(offsets,counter.text,8); CHECK(offsets[0] == 4 && offsets[1] == 4 && counter.text_length == 17);
    CHECK(caret->RemoveFromSelection() == S_OK && counter.calls == 1);
    CHECK(zenit_uia_drain(binding) == 1 && counter.calls == 2);
    memcpy(offsets,counter.text,8); CHECK(offsets[0] == 4 && offsets[1] == 4);
    node.state = 1u << 9; node.can_set_selection = 0; CHECK(zenit_uia_publish(binding,&node,1));
    CHECK(span->AddToSelection() == (HRESULT)UIA_E_NOTSUPPORTED);
    CHECK(caret->RemoveFromSelection() == (HRESULT)UIA_E_NOTSUPPORTED);
    node.state = 0; node.can_set_selection = 1; CHECK(zenit_uia_publish(binding,&node,1));
    CHECK(caret->AddToSelection() == S_OK);
    node.state = 1; CHECK(zenit_uia_publish(binding,&node,1));
    CHECK(zenit_uia_drain(binding) == 0 && counter.calls == 2);
    CHECK(span->RemoveFromSelection() == (HRESULT)UIA_E_ELEMENTNOTENABLED);
    CHECK(caret->AddToSelection() == (HRESULT)UIA_E_ELEMENTNOTENABLED);
    node.state = 0; node.value = {"A中😁B",9}; CHECK(zenit_uia_publish(binding,&node,1));
    CHECK(span->AddToSelection() == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE);
    CHECK(caret->RemoveFromSelection() == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE);
    zenit_uia_destroy(binding);
    CHECK(span->RemoveFromSelection() == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE);
    CHECK(caret->AddToSelection() == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE);
    span->Release(); caret->Release();
    printf("Windows UIA single text-selection operations: %u checks; nonempty rejection, caret queue, capabilities and retained lifetime\n", checks-before);
}

static void a11y_logical_units_contract(HWND window) {
    using namespace zenit_uia;
    unsigned before = checks;
    auto *binding = (Binding *)zenit_uia_create(window); CHECK(binding); if (!binding) return;
    InputNode node = {}; node.id = 0x01000005; node.parent_index = no_parent; node.role = 10;
    node.editable = node.can_set_selection = 1; node.setters = 1; node.visible_end = UINT32_MAX;
    const char value[] = "ab 中😀\r\nx"; node.value = {value,sizeof(value)-1};
    uint32_t words[] = {0,3,6,12,13}, paragraphs[] = {0,12,13};
    node.words = {words,5}; node.paragraphs = {paragraphs,3};
    CHECK(zenit_uia_publish(binding,&node,1));
    ITextRangeProvider *range = nullptr; CHECK(TextRange::create(binding,node.id,1,1,&range) == S_OK && range);
    if (!range) { zenit_uia_destroy(binding); return; }
    auto positions = [&](uint32_t first, uint32_t last) {
        RangeState *state = nullptr; CHECK(range->QueryInterface(range_state_iid,(void **)&state) == S_OK && state);
        if (state) { LONG identity; uint32_t id,a,b; CHECK(state->Read(&identity,&id,&a,&b) == S_OK && a == first && b == last); state->Release(); }
    };
    int moved = 99; BSTR text = nullptr;
    CHECK(range->ExpandToEnclosingUnit(TextUnit_Word) == S_OK); positions(0,3);
    CHECK(range->GetText(-1,&text) == S_OK && !wcscmp(text,L"ab ")); SysFreeString(text);
    CHECK(range->Move(TextUnit_Word,1,&moved) == S_OK && moved == 1); positions(3,4);
    CHECK(range->Move(TextUnit_Word,1,&moved) == S_OK && moved == 1); positions(4,8);
    CHECK(range->GetText(-1,&text) == S_OK && !wcscmp(text,L"😀\r\n")); SysFreeString(text);
    CHECK(range->Move(TextUnit_Word,INT_MAX,&moved) == S_OK && moved == 1); positions(8,9);
    CHECK(range->Move(TextUnit_Word,1,&moved) == S_OK && moved == 0); positions(8,9);
    CHECK(range->Move(TextUnit_Word,INT_MIN,&moved) == S_OK && moved == -3); positions(0,3);
    CHECK(range->MoveEndpointByUnit(TextPatternRangeEndpoint_End,TextUnit_Word,INT_MAX,&moved) == S_OK && moved == 3); positions(0,9);
    CHECK(range->MoveEndpointByUnit(TextPatternRangeEndpoint_Start,TextUnit_Word,2,&moved) == S_OK && moved == 2); positions(4,9);
    CHECK(range->ExpandToEnclosingUnit(TextUnit_Paragraph) == S_OK); positions(0,8);
    CHECK(range->Move(TextUnit_Paragraph,1,&moved) == S_OK && moved == 1); positions(8,9);
    CHECK(range->Move(TextUnit_Paragraph,1,&moved) == S_OK && moved == 0); positions(8,9);
    CHECK(range->MoveEndpointByUnit(TextPatternRangeEndpoint_End,TextUnit_Paragraph,-1,&moved) == S_OK && moved == -1); positions(8,8);
    CHECK(range->Move(TextUnit_Paragraph,-1,&moved) == S_OK && moved == -1); positions(0,0);
    CHECK(range->MoveEndpointByUnit(TextPatternRangeEndpoint_Start,TextUnit_Paragraph,INT_MAX,&moved) == S_OK && moved == 2); positions(9,9);
    CHECK(range->ExpandToEnclosingUnit(TextUnit_Paragraph) == S_OK); positions(8,9);
    words[1] = 1; paragraphs[1] = 1; // Borrowed mutation does not alter old ranges.
    CHECK(range->ExpandToEnclosingUnit(TextUnit_Word) == S_OK); positions(8,9);
    words[1] = 4; CHECK(!zenit_uia_publish(binding,&node,1)); // Inside Han scalar.
    words[1] = 3; paragraphs[1] = 7; CHECK(!zenit_uia_publish(binding,&node,1)); // Inside emoji scalar.
    paragraphs[1] = 12;
    node.words = {nullptr,5}; CHECK(!zenit_uia_publish(binding,&node,1)); node.words = {words,5};
    node.paragraphs = {paragraphs,15}; CHECK(!zenit_uia_publish(binding,&node,1)); node.paragraphs = {paragraphs,3};
    CHECK(range->ExpandToEnclosingUnit(TextUnit_Paragraph) == S_OK); positions(8,9);
    node.value = {"",0}; const uint32_t empty[] = {0}; node.words = node.paragraphs = {empty,1};
    CHECK(zenit_uia_publish(binding,&node,1));
    ITextRangeProvider *blank = nullptr; CHECK(TextRange::create(binding,node.id,0,0,&blank) == S_OK && blank);
    if (blank) {
        const TextUnit units[] = {TextUnit_Word,TextUnit_Paragraph};
        for (TextUnit unit: units) {
            CHECK(blank->ExpandToEnclosingUnit(unit) == S_OK);
            CHECK(blank->Move(unit,INT_MAX,&moved) == S_OK && moved == 0);
            CHECK(blank->MoveEndpointByUnit(TextPatternRangeEndpoint_End,unit,INT_MIN,&moved) == S_OK && moved == 0);
        }
        blank->Release();
    }
    CHECK(range->Move(TextUnit_Word,1,&moved) == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE && moved == 0);
    node.state = secure_state; node.words = node.paragraphs = {nullptr,SIZE_MAX}; CHECK(zenit_uia_publish(binding,&node,1));
    auto *snapshot = binding->context->acquire(); CHECK(snapshot);
    if (snapshot) { const Node *n = snapshot->find(node.id); CHECK(n && !n->words && !n->word_count && !n->paragraphs && !n->paragraph_count); snapshot->release(); }
    zenit_uia_destroy(binding);
    CHECK(range->ExpandToEnclosingUnit(TextUnit_Paragraph) == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE);
    range->Release();
    printf("Windows UIA Word/Paragraph units: %u checks; navigation, UTF16, ownership, rejection, empty and secure redaction\n",checks-before);
}

static void a11y_line_units_contract(HWND window) {
    using namespace zenit_uia;
    unsigned before = checks;
    auto *binding = (Binding *)zenit_uia_create(window); CHECK(binding); if (!binding) return;
    InputNode node = {}; node.id = 0x01000005; node.parent_index = no_parent; node.role = 10;
    node.editable = node.can_set_selection = 1; node.setters = 1; node.visible_end = UINT32_MAX;
    const char value[] = "ab 中😀\r\nx"; node.value = {value,sizeof(value)-1};
    uint32_t lines[] = {0,6,12,13}; node.lines = {lines,4};
    CHECK(zenit_uia_publish(binding,&node,1));
    ITextRangeProvider *range = nullptr; CHECK(TextRange::create(binding,node.id,1,1,&range) == S_OK && range);
    if (!range) { zenit_uia_destroy(binding); return; }
    auto positions = [&](uint32_t first, uint32_t last) {
        RangeState *state = nullptr; CHECK(range->QueryInterface(range_state_iid,(void **)&state) == S_OK && state);
        if (state) { LONG identity; uint32_t id,a,b; CHECK(state->Read(&identity,&id,&a,&b) == S_OK && a == first && b == last); state->Release(); }
    };
    int moved = 99; BSTR text = nullptr;
    CHECK(range->ExpandToEnclosingUnit(TextUnit_Line) == S_OK); positions(0,4);
    CHECK(range->Move(TextUnit_Line,1,&moved) == S_OK && moved == 1); positions(4,8);
    CHECK(range->GetText(-1,&text) == S_OK && !wcscmp(text,L"😀\r\n")); SysFreeString(text);
    CHECK(range->Move(TextUnit_Line,INT_MAX,&moved) == S_OK && moved == 1); positions(8,9);
    CHECK(range->Move(TextUnit_Line,1,&moved) == S_OK && moved == 0); positions(8,9);
    CHECK(range->MoveEndpointByUnit(TextPatternRangeEndpoint_End,TextUnit_Line,INT_MIN,&moved) == S_OK && moved == -3); positions(0,0);
    CHECK(range->MoveEndpointByUnit(TextPatternRangeEndpoint_Start,TextUnit_Line,1,&moved) == S_OK && moved == 1); positions(4,4);
    lines[1] = 3; // Mutating the borrowed table alone cannot change native rows.
    CHECK(range->ExpandToEnclosingUnit(TextUnit_Line) == S_OK); positions(4,8);
    uint32_t wide[] = {0,12,13}; node.lines = {wide,3}; CHECK(zenit_uia_publish(binding,&node,1));
    // Existing ranges use current layout after reflow while text stays identical.
    CHECK(range->ExpandToEnclosingUnit(TextUnit_Line) == S_OK); positions(0,8);
    CHECK(range->MoveEndpointByUnit(TextPatternRangeEndpoint_End,TextUnit_Line,1,&moved) == S_OK && moved == 1); positions(0,9);
    CHECK(range->Move(TextUnit_Line,1,&moved) == S_OK && moved == 1); positions(8,9);
    wide[1] = 7; CHECK(!zenit_uia_publish(binding,&node,1)); // Inside emoji UTF-8.
    CHECK(range->ExpandToEnclosingUnit(TextUnit_Line) == S_OK); positions(8,9);
    node.lines = {nullptr,3}; CHECK(!zenit_uia_publish(binding,&node,1));
    node.lines = {wide,15}; CHECK(!zenit_uia_publish(binding,&node,1));
    node.value = {value,12}; node.state = 1u << 15; const uint32_t trailing[] = {0,12}; node.lines = {trailing,2};
    CHECK(zenit_uia_publish(binding,&node,1));
    ITextRangeProvider *last = nullptr; CHECK(TextRange::create(binding,node.id,8,8,&last) == S_OK && last);
    if (last) {
        CHECK(last->ExpandToEnclosingUnit(TextUnit_Line) == S_OK);
        CHECK(last->GetText(-1,&text) == S_OK && SysStringLen(text) == 0); SysFreeString(text);
        CHECK(last->Move(TextUnit_Line,-1,&moved) == S_OK && moved == -1);
        CHECK(last->ExpandToEnclosingUnit(TextUnit_Line) == S_OK);
        CHECK(last->Move(TextUnit_Line,1,&moved) == S_OK && moved == 1);
        CHECK(last->GetText(-1,&text) == S_OK && SysStringLen(text) == 0); SysFreeString(text);
        CHECK(last->Move(TextUnit_Line,1,&moved) == S_OK && moved == 0);
        last->Release();
    }
    node.state = 0;
    node.value = {"",0}; const uint32_t empty[] = {0}; node.lines = {empty,1}; CHECK(zenit_uia_publish(binding,&node,1));
    ITextRangeProvider *blank = nullptr; CHECK(TextRange::create(binding,node.id,0,0,&blank) == S_OK && blank);
    if (blank) {
        CHECK(blank->ExpandToEnclosingUnit(TextUnit_Line) == S_OK);
        CHECK(blank->Move(TextUnit_Line,INT_MAX,&moved) == S_OK && moved == 0);
        CHECK(blank->MoveEndpointByUnit(TextPatternRangeEndpoint_End,TextUnit_Line,INT_MIN,&moved) == S_OK && moved == 0);
        blank->Release();
    }
    CHECK(range->Move(TextUnit_Line,1,&moved) == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE && moved == 0);
    node.state = secure_state; node.lines = {nullptr,SIZE_MAX}; CHECK(zenit_uia_publish(binding,&node,1));
    auto *snapshot = binding->context->acquire(); CHECK(snapshot);
    if (snapshot) { const Node *n = snapshot->find(node.id); CHECK(n && !n->lines && !n->line_count); snapshot->release(); }
    zenit_uia_destroy(binding);
    CHECK(range->ExpandToEnclosingUnit(TextUnit_Line) == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE);
    range->Release();
    printf("Windows UIA visual Line units: %u checks; reflow, UTF16, ownership, navigation, stale/empty and redaction\n",checks-before);
}

static void a11y_unit_resolution_contract(HWND window) {
    using namespace zenit_uia;
    unsigned before = checks;
    auto *binding = (Binding *)zenit_uia_create(window); CHECK(binding); if (!binding) return;
    InputNode node = {}; node.id = 0x01000005; node.parent_index = no_parent; node.role = 10;
    node.editable = node.can_set_selection = node.uniform_format = 1; node.setters = 1; node.visible_end = UINT32_MAX;
    node.value = {"ab cd!",6}; const uint32_t words[] = {0,3,6}; node.words = {words,3};
    CHECK(zenit_uia_publish(binding,&node,1));
    auto positions = [&](ITextRangeProvider *range, uint32_t first, uint32_t last) {
        RangeState *state = nullptr; CHECK(range->QueryInterface(range_state_iid,(void **)&state) == S_OK && state);
        if (state) { LONG identity; uint32_t id,a,b; CHECK(state->Read(&identity,&id,&a,&b) == S_OK && a == first && b == last); state->Release(); }
    };
    ITextRangeProvider *retained = nullptr;
    const TextUnit single[] = {TextUnit_Format,TextUnit_Page,TextUnit_Document};
    for (TextUnit unit: single) {
        ITextRangeProvider *range = nullptr; CHECK(TextRange::create(binding,node.id,1,2,&range) == S_OK && range);
        if (!range) continue;
        int moved = 99;
        CHECK(range->Move(unit,1,&moved) == S_OK && moved == 0); positions(range,1,2);
        CHECK(range->Move(unit,0,&moved) == S_OK && moved == 0); positions(range,1,2);
        CHECK(range->ExpandToEnclosingUnit(unit) == S_OK); positions(range,0,6);
        CHECK(range->MoveEndpointByUnit(TextPatternRangeEndpoint_End,unit,INT_MIN,&moved) == S_OK && moved == -1); positions(range,0,0);
        CHECK(range->Move(unit,INT_MAX,&moved) == S_OK && moved == 1); positions(range,6,6);
        CHECK(range->Move(unit,1,&moved) == S_OK && moved == 0); positions(range,6,6);
        CHECK(range->Move(unit,INT_MIN,&moved) == S_OK && moved == -1); positions(range,0,0);
        CHECK(range->ExpandToEnclosingUnit(unit) == S_OK); positions(range,0,6);
        if (unit == TextUnit_Format) retained = range; else range->Release();
    }
    if (!retained) { zenit_uia_destroy(binding); return; }
    node.uniform_format = 0; CHECK(zenit_uia_publish(binding,&node,1));
    CHECK(retained->ExpandToEnclosingUnit(TextUnit_Format) == S_OK); positions(retained,0,3);
    int moved = 99;
    CHECK(retained->Move(TextUnit_Format,1,&moved) == S_OK && moved == 1); positions(retained,3,6);
    CHECK(retained->MoveEndpointByUnit(TextPatternRangeEndpoint_End,TextUnit_Format,-1,&moved) == S_OK && moved == -1); positions(retained,3,3);
    CHECK(retained->Move(TextUnit_Format,-1,&moved) == S_OK && moved == -1); positions(retained,0,0);
    // Missing Character -> missing Format -> Word, not immediate Document.
    CHECK(retained->ExpandToEnclosingUnit(TextUnit_Character) == S_OK); positions(retained,0,3);
    node.words = {}; const uint32_t paragraphs[] = {0,3,6}; node.paragraphs = {paragraphs,3};
    CHECK(zenit_uia_publish(binding,&node,1));
    // A retained text range sees current capability tables when text matches.
    // Missing Character/Format/Word/Line must defer to Paragraph.
    CHECK(retained->ExpandToEnclosingUnit(TextUnit_Character) == S_OK); positions(retained,0,3);
    CHECK(retained->Move(TextUnit_Character,1,&moved) == S_OK && moved == 1); positions(retained,3,6);
    ITextRangeProvider *fresh = nullptr; CHECK(TextRange::create(binding,node.id,1,1,&fresh) == S_OK && fresh);
    if (fresh) {
        CHECK(fresh->ExpandToEnclosingUnit(TextUnit_Line) == S_OK); positions(fresh,0,3);
        CHECK(fresh->Move(TextUnit_Line,1,&moved) == S_OK && moved == 1); positions(fresh,3,6);
        fresh->Release();
    }
    node.paragraphs = {}; CHECK(zenit_uia_publish(binding,&node,1));
    for (int requested = TextUnit_Character; requested <= TextUnit_Document; ++requested) {
        ITextRangeProvider *range = nullptr; CHECK(TextRange::create(binding,node.id,1,1,&range) == S_OK && range);
        if (range) {
            CHECK(range->ExpandToEnclosingUnit((TextUnit)requested) == S_OK); positions(range,0,6);
            range->Release();
        }
    }
    node.uniform_format = 2; CHECK(!zenit_uia_publish(binding,&node,1)); node.uniform_format = 1;
    node.value = {"",0}; CHECK(zenit_uia_publish(binding,&node,1));
    for (TextUnit unit: single) {
        ITextRangeProvider *range = nullptr; CHECK(TextRange::create(binding,node.id,0,0,&range) == S_OK && range);
        if (range) {
            CHECK(range->ExpandToEnclosingUnit(unit) == S_OK); positions(range,0,0);
            CHECK(range->Move(unit,INT_MAX,&moved) == S_OK && moved == 0);
            range->Release();
        }
    }
    node.state = secure_state; CHECK(zenit_uia_publish(binding,&node,1));
    auto *snapshot = binding->context->acquire(); CHECK(snapshot);
    if (snapshot) { const Node *n = snapshot->find(node.id); CHECK(n && !n->uniform_format && !n->editable); snapshot->release(); }
    CHECK(retained->ExpandToEnclosingUnit(TextUnit_Format) == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE);
    zenit_uia_destroy(binding);
    CHECK(retained->Move(TextUnit_Page,1,&moved) == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE && moved == 0);
    retained->Release();
    printf("Windows UIA unit resolution: %u checks; uniform Format, Page fallback, next-supported units, count bounds, empty, stale and redaction\n",checks-before);
}

static void check_text_rectangles(ITextRangeProvider *range, const double *expected, size_t length) {
    SAFEARRAY *array = nullptr;
    CHECK(range->GetBoundingRectangles(&array) == S_OK && array);
    if (!array) return;
    VARTYPE type = VT_EMPTY; LONG lower = -1, upper = -2;
    CHECK(SafeArrayGetVartype(array,&type) == S_OK && type == VT_R8 && SafeArrayGetDim(array) == 1);
    CHECK(SafeArrayGetLBound(array,1,&lower) == S_OK && lower == 0);
    CHECK(SafeArrayGetUBound(array,1,&upper) == S_OK && upper+1 == (LONG)length);
    if (length && upper+1 == (LONG)length) {
        double *data = nullptr; CHECK(SafeArrayAccessData(array,(void **)&data) == S_OK && data);
        if (data) {
            bool equal = true; for (size_t i = 0; i < length; ++i) equal &= fabs(data[i]-expected[i]) < 0.00001;
            CHECK(equal); CHECK(SafeArrayUnaccessData(array) == S_OK);
        }
    }
    CHECK(SafeArrayDestroy(array) == S_OK);
}

static void a11y_bounding_rectangles_contract(HWND window) {
    using namespace zenit_uia;
    unsigned before = checks;
    auto *binding = (Binding *)zenit_uia_create(window); CHECK(binding); if (!binding) return;
    InputNode node = {}; node.id = 1; node.parent_index = no_parent; node.role = 10;
    node.editable = node.geometry_ready = 1; node.visible_end = UINT32_MAX; node.value = {"A中😀B",9};
    node.x = 10; node.y = 20; node.width = 60; node.height = 40;
    ZenitA11yGeometrySegment pieces[] = {{0,1,0,20,15,10},{1,4,15,20,10,10},{4,8,40,20,10,10},{8,9,10,35,80,40}};
    node.geometry = {pieces,4};
    Viewport vp{100,200,175,140,1.75};
    CHECK(binding->context->publish(&node,1,vp));
    ITextRangeProvider *full = nullptr, *emoji = nullptr, *caret = nullptr;
    CHECK(TextRange::create(binding,1,0,5,&full) == S_OK && full);
    CHECK(TextRange::create(binding,1,2,4,&emoji) == S_OK && emoji);
    CHECK(TextRange::create(binding,1,2,2,&caret) == S_OK && caret);
    if (!full || !emoji || !caret) { if (full) full->Release(); if (emoji) emoji->Release(); if (caret) caret->Release(); zenit_uia_destroy(binding); return; }
    CHECK(full->GetBoundingRectangles(nullptr) == E_POINTER);
    const double initial[] = {117.5,235,26.25,17.5, 170,235,17.5,17.5, 117.5,261.25,105,43.75};
    const double emoji_box[] = {170,235,17.5,17.5};
    check_text_rectangles(full,initial,12); check_text_rectangles(emoji,emoji_box,4); check_text_rectangles(caret,nullptr,0);
    node.state = 1 | (1u<<9); CHECK(binding->context->publish(&node,1,vp));
    check_text_rectangles(emoji,emoji_box,4); // Reading is allowed for disabled/readonly text.
    node.state = 0;
    pieces[2].x = 45; CHECK(binding->context->publish(&node,1,vp));
    const double reflow[] = {178.75,235,17.5,17.5};
    check_text_rectangles(emoji,reflow,4); // Same range, current geometry rather than original snapshot.
    vp.x = -300; vp.scale = 2; CHECK(binding->context->publish(&node,1,vp));
    const double moved[] = {-210,240,20,20};
    check_text_rectangles(emoji,moved,4);
    node.x = 200; CHECK(binding->context->publish(&node,1,vp));
    check_text_rectangles(full,nullptr,0); // Control outside the client viewport.
    node.x = 10;
    node.geometry = {}; CHECK(binding->context->publish(&node,1,vp));
    check_text_rectangles(full,nullptr,0); // Known empty layout.
    node.geometry_ready = 0; CHECK(binding->context->publish(&node,1,vp));
    SAFEARRAY *array = (SAFEARRAY *)1;
    CHECK(full->GetBoundingRectangles(&array) == (HRESULT)UIA_E_NOTSUPPORTED && !array);
    check_text_rectangles(caret,nullptr,0); // Empty range needs no shaped pieces.
    node.geometry_ready = 1; node.value = {"ab",2}; node.x = node.y = 0;
    ZenitA11yGeometrySegment fractional[] = {{0,1,.1f,0,.2f,10},{1,2,.3f,0,.1f,10}};
    node.geometry = {fractional,2}; vp = {100,200,175,140,1.75};
    CHECK(binding->context->publish(&node,1,vp));
    ITextRangeProvider *fractional_range = nullptr;
    CHECK(TextRange::create(binding,1,0,2,&fractional_range) == S_OK && fractional_range);
    if (fractional_range) {
        const double joined[] = {100.175,200,.525,17.5};
        check_text_rectangles(fractional_range,joined,4); fractional_range->Release();
    }
    node.value = {"A中😀B",9}; node.x = 10; node.y = 20;
    node.geometry_ready = 1; node.geometry = {pieces,4};
    node.state = 2; CHECK(binding->context->publish(&node,1,vp));
    array = (SAFEARRAY *)1; CHECK(full->GetBoundingRectangles(&array) == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE && !array);
    node.state = 0; node.value = {"A中😁B",9}; CHECK(binding->context->publish(&node,1,vp));
    array = (SAFEARRAY *)1; CHECK(full->GetBoundingRectangles(&array) == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE && !array);
    node.value = {"A中😀B",9}; node.state = secure_state; CHECK(binding->context->publish(&node,1,vp));
    array = (SAFEARRAY *)1; CHECK(full->GetBoundingRectangles(&array) == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE && !array);
    zenit_uia_destroy(binding);
    array = (SAFEARRAY *)1; CHECK(full->GetBoundingRectangles(&array) == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE && !array);
    full->Release(); emoji->Release(); caret->Release();
    printf("Windows UIA bounding rectangles: %u checks; typed arrays, disjoint visual pieces, line merging, client/control clipping, DPI, current layout, empty/unknown, readonly/disabled and stale lifetime\n",checks-before);
}

static void a11y_scroll_contract(HWND window) {
    using namespace zenit_uia;
    unsigned before = checks;
    auto *binding = (Binding *)zenit_uia_create(window); CHECK(binding); if (!binding) return;
    InvokeCounter counter{GetCurrentThreadId()};
    CHECK(zenit_uia_set_action_handler(binding,&counter,count_invoke));
    InputNode node = {}; node.id = 0x01000005; node.parent_index = no_parent; node.role = 10;
    node.editable = node.can_scroll = 1; node.visible_end = UINT32_MAX;
    node.value = {"A中😀B",9}; node.selection_start = node.selection_end = node.caret = 0;
    CHECK(zenit_uia_publish(binding,&node,1));
    ITextRangeProvider *range = nullptr; CHECK(TextRange::create(binding,node.id,1,4,&range) == S_OK && range);
    if (!range) { zenit_uia_destroy(binding); return; }
    CHECK(range->ScrollIntoView(TRUE) == S_OK && counter.calls == 0);
    CHECK(zenit_uia_drain(binding) == 1 && counter.calls == 1 && counter.last_action == 12 && counter.number == 1 && !counter.wrong_thread);
    const uint32_t offsets[] = {1,8};
    CHECK(counter.text_length == 17 && !memcmp(counter.text,offsets,8) && !memcmp(counter.text+8,node.value.bytes,9));
    CHECK(range->ScrollIntoView(FALSE) == S_OK);
    CHECK(zenit_uia_drain(binding) == 1 && counter.number == 0 && counter.calls == 2);
    node.state = 1u << 9; CHECK(zenit_uia_publish(binding,&node,1));
    CHECK(range->ScrollIntoView(TRUE) == S_OK); CHECK(zenit_uia_drain(binding) == 1 && counter.calls == 3);
    CHECK(range->Select() == (HRESULT)UIA_E_NOTSUPPORTED);
    CHECK(range->ScrollIntoView(TRUE) == S_OK);
    node.state |= 1; CHECK(zenit_uia_publish(binding,&node,1));
    CHECK(zenit_uia_drain(binding) == 0 && counter.calls == 3);
    CHECK(range->ScrollIntoView(TRUE) == (HRESULT)UIA_E_ELEMENTNOTENABLED);
    // Match real projection: disabling the widget also removes capabilities.
    node.can_scroll = node.can_set_selection = 0; CHECK(zenit_uia_publish(binding,&node,1));
    CHECK(range->ScrollIntoView(FALSE) == (HRESULT)UIA_E_ELEMENTNOTENABLED);
    CHECK(range->Select() == (HRESULT)UIA_E_ELEMENTNOTENABLED);
    CHECK(range->AddToSelection() == (HRESULT)UIA_E_ELEMENTNOTENABLED);
    CHECK(range->RemoveFromSelection() == (HRESULT)UIA_E_ELEMENTNOTENABLED);
    CHECK(zenit_uia_drain(binding) == 0 && counter.calls == 3);
    ITextRangeProvider *disabled_caret = nullptr;
    CHECK(TextRange::create(binding,node.id,0,0,&disabled_caret) == S_OK && disabled_caret);
    if (disabled_caret) {
        CHECK(disabled_caret->AddToSelection() == (HRESULT)UIA_E_ELEMENTNOTENABLED);
        CHECK(disabled_caret->RemoveFromSelection() == (HRESULT)UIA_E_ELEMENTNOTENABLED);
        disabled_caret->Release();
    }
    node.state = 0; node.can_scroll = node.can_set_selection = 1; CHECK(zenit_uia_publish(binding,&node,1));
    CHECK(EnableWindow(window,FALSE) == 0);
    CHECK(range->ScrollIntoView(TRUE) == (HRESULT)UIA_E_ELEMENTNOTENABLED);
    CHECK(range->Select() == (HRESULT)UIA_E_ELEMENTNOTENABLED);
    EnableWindow(window,TRUE);
    CHECK(IsWindowEnabled(window) && zenit_uia_drain(binding) == 0 && counter.calls == 3);
    node.state = 0; node.can_scroll = 0; CHECK(zenit_uia_publish(binding,&node,1));
    CHECK(range->ScrollIntoView(FALSE) == (HRESULT)UIA_E_NOTSUPPORTED);
    node.can_scroll = 2; CHECK(!zenit_uia_publish(binding,&node,1)); node.can_scroll = 1;
    CHECK(zenit_uia_publish(binding,&node,1));
    CHECK(zenit_uia_set_action_handler(binding,nullptr,nullptr));
    CHECK(range->ScrollIntoView(TRUE) == (HRESULT)UIA_E_NOTSUPPORTED);
    CHECK(zenit_uia_set_action_handler(binding,&counter,count_invoke));
    node.value = {"A中😁B",9}; CHECK(zenit_uia_publish(binding,&node,1));
    CHECK(range->ScrollIntoView(TRUE) == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE);
    range->Release(); range = nullptr;
    CHECK(TextRange::create(binding,node.id,0,0,&range) == S_OK && range);
    if (range) {
        CHECK(range->ScrollIntoView(TRUE) == S_OK);
        node.state = secure_state; CHECK(zenit_uia_publish(binding,&node,1));
        CHECK(zenit_uia_drain(binding) == 0 && counter.calls == 3);
        auto *snapshot = binding->context->acquire(); CHECK(snapshot);
        if (snapshot) { const Node *n = snapshot->find(node.id); CHECK(n && !n->can_scroll && !n->editable); snapshot->release(); }
        CHECK(range->ScrollIntoView(FALSE) == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE);
    }
    zenit_uia_destroy(binding);
    if (range) { CHECK(range->ScrollIntoView(TRUE) == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE); range->Release(); }
    printf("Windows UIA text scrolling: %u checks; typed UTF8 queue, readonly, capability, owner dispatch, disabled/secure/stale and disconnect\n",checks-before);
}

static void a11y_text_read_view_contract(HWND window) {
    using namespace zenit_uia;
    unsigned before = checks;
    auto *binding = (Binding *)zenit_uia_create(window); CHECK(binding); if (!binding) return;
    InputNode node = {}; node.id = 0x01000043; node.parent_index = no_parent; node.role = 10;
    node.editable = 1; node.value = {"A中😀B", 9}; node.visible_end = UINT32_MAX;
    node.selection_start = 1; node.selection_end = node.caret = 8;
    CHECK(zenit_uia_publish(binding, &node, 1));
    ITextRangeProvider *document = nullptr;
    CHECK(TextReadView::document(binding, node.id, &document) == S_OK && document);
    BSTR text = nullptr;
    if (document) {
        CHECK(document->GetText(-1, &text) == S_OK && text && !wcscmp(text, L"A中😀B")); SysFreeString(text);
    }
    auto selection = [&](const wchar_t *expected, uint32_t first, uint32_t last) {
        SAFEARRAY *array = nullptr;
        CHECK(TextReadView::selection(binding, node.id, &array) == S_OK && array);
        if (!array) return;
        VARTYPE type = VT_EMPTY; LONG low = -1, high = -1, index = 0;
        CHECK(SafeArrayGetVartype(array, &type) == S_OK && type == VT_UNKNOWN);
        CHECK(SafeArrayGetLBound(array, 1, &low) == S_OK && low == 0);
        CHECK(SafeArrayGetUBound(array, 1, &high) == S_OK && high == 0);
        IUnknown *unknown = nullptr;
        CHECK(SafeArrayGetElement(array, &index, &unknown) == S_OK && unknown);
        ITextRangeProvider *range = nullptr;
        if (unknown) { CHECK(unknown->QueryInterface(__uuidof(ITextRangeProvider), (void **)&range) == S_OK && range); unknown->Release(); }
        SafeArrayDestroy(array);
        if (!range) return;
        // The retrieved COM reference remains valid after its SAFEARRAY dies.
        BSTR selected = nullptr;
        CHECK(range->GetText(-1, &selected) == S_OK && selected && !wcscmp(selected, expected)); SysFreeString(selected);
        RangeState *state = nullptr;
        CHECK(range->QueryInterface(range_state_iid, (void **)&state) == S_OK && state);
        if (state) {
            LONG identity = 0; uint32_t id = 0, start = 99, end = 99;
            CHECK(state->Read(&identity, &id, &start, &end) == S_OK && id == node.id && start == first && end == last);
            state->Release();
        }
        range->Release();
    };
    selection(L"中😀", 1, 4);
    // Reads do not require action capabilities, enabled state, or layout/geometry.
    node.state = 1 | (1u << 9); node.can_set_selection = 0;
    CHECK(zenit_uia_publish(binding, &node, 1)); selection(L"中😀", 1, 4);
    node.state = 0; node.selection_start = node.selection_end = node.caret = 8;
    CHECK(zenit_uia_publish(binding, &node, 1)); selection(L"", 4, 4);
    {
        View pinned(binding);
        node.value = {"short", 5}; node.selection_start = node.selection_end = node.caret = 0;
        CHECK(zenit_uia_publish(binding, &node, 1));
        ITextRangeProvider *stale = nullptr;
        CHECK(TextRange::create_owned(binding, pinned.snapshot, node.id, 1, 4, &stale) == S_OK && stale);
        if (stale) {
            text = (BSTR)1;
            CHECK(stale->GetText(-1, &text) == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE && !text);
            stale->Release();
        }
    }
    if (document) { text = (BSTR)1; CHECK(document->GetText(-1, &text) == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE && !text); document->Release(); document = nullptr; }
    CHECK(TextReadView::document(binding, node.id, &document) == S_OK && document);
    if (document) { CHECK(document->GetText(-1, &text) == S_OK && !wcscmp(text, L"short")); SysFreeString(text); document->Release(); document = nullptr; }
    node.value = {"", 0};
    CHECK(zenit_uia_publish(binding, &node, 1)); selection(L"", 0, 0);
    CHECK(TextReadView::document(binding, node.id, &document) == S_OK && document);
    if (document) { CHECK(document->GetText(-1, &text) == S_OK && SysStringLen(text) == 0); SysFreeString(text); }
    CHECK(TextReadView::document(binding, node.id, nullptr) == E_POINTER);
    CHECK(TextReadView::selection(binding, node.id, nullptr) == E_POINTER);
    const uint32_t unavailable_states[] = {2u, secure_state};
    for (uint32_t state : unavailable_states) {
        node.state = state; CHECK(zenit_uia_publish(binding, &node, 1));
        ITextRangeProvider *bad = (ITextRangeProvider *)1; SAFEARRAY *array = (SAFEARRAY *)1;
        CHECK(TextReadView::document(binding, node.id, &bad) == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE && !bad);
        CHECK(TextReadView::selection(binding, node.id, &array) == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE && !array);
    }
    CHECK(zenit_uia_publish(binding, nullptr, 0));
    ITextRangeProvider *bad = (ITextRangeProvider *)1; SAFEARRAY *array = (SAFEARRAY *)1;
    CHECK(TextReadView::document(binding, node.id, &bad) == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE && !bad);
    CHECK(TextReadView::selection(binding, node.id, &array) == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE && !array);
    binding->retain();
    zenit_uia_destroy(binding);
    CHECK(TextReadView::document(binding, node.id, &bad) == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE && !bad);
    CHECK(TextReadView::selection(binding, node.id, &array) == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE && !array);
    if (document) document->Release();
    binding->release();
    printf("  UIA document/selection owned read view: %u checks\n", checks-before);
}

static void a11y_visible_ranges_contract(HWND window) {
    using namespace zenit_uia;
    unsigned before = checks;
    auto *binding = (Binding *)zenit_uia_create(window); CHECK(binding); if (!binding) return;
    InputNode node = {}; node.id = 0x01000044; node.parent_index = no_parent; node.role = 10;
    node.editable = node.geometry_ready = 1; node.visible_end = UINT32_MAX; node.value = {"A中😀B",9};
    node.selection_start = node.selection_end = node.caret = 8;
    node.x = 10; node.y = 20; node.width = 60; node.height = 40;
    // Reversed visual order, clipped A, fully hidden, and off-client B.
    ZenitA11yGeometrySegment pieces[] = {{4,8,40,20,10,10},{0,1,0,20,15,10},{1,4,-10,20,5,10},{8,9,150,35,10,10}};
    node.geometry = {pieces,4}; Viewport vp{100,200,175,140,1.75};
    auto check = [&](const uint32_t *endpoints, size_t count) {
        SAFEARRAY *array = nullptr;
        CHECK(TextReadView::visible(binding,node.id,&array) == S_OK && array);
        if (!array) return;
        VARTYPE type = VT_EMPTY; LONG low = -1, high = -1;
        CHECK(SafeArrayGetVartype(array,&type) == S_OK && type == VT_UNKNOWN);
        CHECK(SafeArrayGetLBound(array,1,&low) == S_OK && low == 0);
        CHECK(SafeArrayGetUBound(array,1,&high) == S_OK && high+1 == (LONG)count);
        if (high+1 == (LONG)count) for (LONG i = 0; i <= high; ++i) {
            IUnknown *unknown = nullptr;
            CHECK(SafeArrayGetElement(array,&i,&unknown) == S_OK && unknown);
            RangeState *state = nullptr;
            if (unknown) { CHECK(unknown->QueryInterface(range_state_iid,(void **)&state) == S_OK && state); unknown->Release(); }
            if (state) {
                LONG identity = 0; uint32_t id = 0, first = 99, last = 99;
                CHECK(state->Read(&identity,&id,&first,&last) == S_OK && id == node.id && first == endpoints[2*i] && last == endpoints[2*i+1]);
                state->Release();
            }
        }
        CHECK(SafeArrayDestroy(array) == S_OK);
    };
    CHECK(binding->context->publish(&node,1,vp));
    const uint32_t split[] = {0,1,2,4}; check(split,2);
    pieces[2].x = 15; pieces[2].width = 10;
    CHECK(binding->context->publish(&node,1,vp));
    const uint32_t contiguous[] = {0,4}; check(contiguous,1);
    pieces[3].x = 10; pieces[3].width = 80; pieces[3].height = 40;
    CHECK(binding->context->publish(&node,1,vp));
    const uint32_t all[] = {0,5}; check(all,1);
    vp.width = 70; CHECK(binding->context->publish(&node,1,vp));
    const uint32_t clipped[] = {0,2,4,5}; check(clipped,2);
    vp.width = 0; CHECK(binding->context->publish(&node,1,vp));
    const uint32_t caret[] = {4,4}; check(caret,1);
    vp.width = 175; node.geometry = {}; CHECK(binding->context->publish(&node,1,vp)); check(caret,1);
    node.geometry_ready = 0; CHECK(binding->context->publish(&node,1,vp));
    SAFEARRAY *bad = (SAFEARRAY *)1;
    CHECK(TextReadView::visible(binding,node.id,&bad) == (HRESULT)UIA_E_NOTSUPPORTED && !bad);
    node.value = {"",0}; node.caret = node.selection_start = node.selection_end = 0;
    CHECK(binding->context->publish(&node,1,vp));
    const uint32_t empty[] = {0,0}; check(empty,1);
    node.value = {"A\nB",3}; node.geometry_ready = 1;
    ZenitA11yGeometrySegment rows[] = {{0,1,10,20,10,10},{2,3,10,35,10,10}}; node.geometry = {rows,2};
    CHECK(binding->context->publish(&node,1,vp));
    const uint32_t newline[] = {0,3}; check(newline,1);
    node.value = {"A\r\nB",4}; rows[1].start = 3; rows[1].end = 4;
    node.state = 1 | (1u<<9); CHECK(binding->context->publish(&node,1,vp)); check(contiguous,1);
    node.state = 0; node.value = {"A\n\n",3}; node.caret = node.selection_start = node.selection_end = 0;
    ZenitA11yGeometrySegment row_regions[] = {{0,2,10,0,80,20},{2,3,10,20,80,20},{3,3,10,40,80,20}};
    ZenitA11yGeometrySegment a_piece[] = {{0,1,10,0,10,20}};
    node.rows_ready = 1; node.rows = {row_regions,3}; node.geometry = {a_piece,1};
    node.x = 50; node.y = 25; node.width = node.height = 10;
    CHECK(binding->context->publish(&node,1,vp)); const uint32_t blank_row[] = {2,3}; check(blank_row,1);
    node.y = 45; CHECK(binding->context->publish(&node,1,vp)); const uint32_t terminal_row[] = {3,3}; check(terminal_row,1);
    node.x = node.y = 0; node.width = 100; node.height = 60;
    CHECK(binding->context->publish(&node,1,vp)); check(newline,1);
    node.geometry = {}; CHECK(binding->context->publish(&node,1,vp));
    const uint32_t separators[] = {1,3}; check(separators,1); // Row regions alone never expose ordinary hidden glyphs.
    node.state = 2; CHECK(binding->context->publish(&node,1,vp));
    bad = (SAFEARRAY *)1; CHECK(TextReadView::visible(binding,node.id,&bad) == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE && !bad);
    node.state = secure_state; CHECK(binding->context->publish(&node,1,vp));
    bad = (SAFEARRAY *)1; CHECK(TextReadView::visible(binding,node.id,&bad) == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE && !bad);
    CHECK(TextReadView::visible(binding,node.id,nullptr) == E_POINTER);
    binding->retain(); zenit_uia_destroy(binding);
    bad = (SAFEARRAY *)1; CHECK(TextReadView::visible(binding,node.id,&bad) == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE && !bad);
    binding->release();
    printf("Windows UIA visible range reads: %u checks; disjoint Unicode, clips, DPI, newline spans, unknown layout and redaction\n",checks-before);
}

static void a11y_point_range_contract(HWND window) {
    using namespace zenit_uia;
    unsigned before = checks;
    auto *binding = (Binding *)zenit_uia_create(window); CHECK(binding); if (!binding) return;
    InputNode node = {}; node.id = 0x01000045; node.parent_index = no_parent; node.role = 10;
    node.editable = node.carets_ready = node.geometry_ready = 1; node.visible_end = UINT32_MAX;
    node.value = {"A中😀B",9}; node.caret = node.selection_start = node.selection_end = 8;
    node.width = 100; node.height = 80;
    ZenitA11yCaretCandidate carets[] = {
        {8,30,20,30,40,0,0,0,0,1,0},
        {4,10,20,10,40,0,0,0,0,0,0},
        {1,80,60,80,80,80,60,80,80,1,1}
    };
    ZenitA11yGeometrySegment pieces[] = {{4,8,18,25,4,10}};
    node.carets = {carets,3}; node.geometry = {pieces,1};
    Viewport vp{100,200,175,140,1.75};
    auto check = [&](double x, double y, uint32_t expected) {
        ITextRangeProvider *range = nullptr;
        CHECK(TextReadView::point(binding,node.id,{vp.x+x*vp.scale,vp.y+y*vp.scale},&range) == S_OK && range);
        if (!range) return;
        RangeState *state = nullptr;
        CHECK(range->QueryInterface(range_state_iid,(void **)&state) == S_OK && state);
        if (state) {
            LONG identity = 0; uint32_t id = 0, first = 99, last = 99;
            CHECK(state->Read(&identity,&id,&first,&last) == S_OK && id == node.id && first == expected && last == expected);
            state->Release();
        }
        range->Release();
    };
    CHECK(binding->context->publish(&node,1,vp));
    check(18,30,2); check(22,30,4); check(20,30,4); // Tie follows source visual order.
    check(-500,30,2); check(500,30,1); // Outside control chooses nearest visible text.
    check(80,70,1); // Visible caret line without neighboring glyph ink.
    node.state = 1 | (1u<<9); CHECK(binding->context->publish(&node,1,vp)); check(18,30,2);
    node.state = 0;
    // Affine caret: nearest point may lie inside the segment, not at its ends.
    carets[0] = {8,30,0,0,30,30,0,0,30,1,1};
    carets[1] = {4,0,0,0,30,0,0,0,30,0,1}; node.carets.count = 2;
    CHECK(binding->context->publish(&node,1,vp)); check(15,15,4); check(2,15,2);
    node.geometry = {}; carets[0].visible = carets[1].visible = 0;
    CHECK(binding->context->publish(&node,1,vp)); check(15,15,4); // Known invisible fallback is current caret.
    node.carets = {}; node.carets_ready = 0;
    CHECK(binding->context->publish(&node,1,vp));
    ITextRangeProvider *bad = (ITextRangeProvider *)1;
    CHECK(TextReadView::point(binding,node.id,{100,200},&bad) == (HRESULT)UIA_E_NOTSUPPORTED && !bad);
    node.value = {"\n\n",2}; node.caret = node.selection_start = node.selection_end = 0;
    ZenitA11yGeometrySegment blank_rows[] = {{0,1,10,0,80,20},{1,2,10,20,80,20},{2,2,10,40,80,20}};
    ZenitA11yCaretCandidate blank_carets[] = {
        {1,10,20,10,40,0,0,0,0,1,0}, {2,10,40,10,60,0,0,0,0,1,0}
    };
    node.rows_ready = node.carets_ready = 1; node.rows = {blank_rows,3}; node.carets = {blank_carets,1};
    node.x = 50; node.y = 25; node.width = node.height = 10;
    CHECK(binding->context->publish(&node,1,vp)); check(55,30,1);
    node.y = 45; node.carets = {blank_carets+1,1};
    CHECK(binding->context->publish(&node,1,vp)); check(55,50,2);
    node.rows = {}; node.rows_ready = 0; node.carets = {}; node.carets_ready = 0;
    node.value = {"",0}; node.caret = node.selection_start = node.selection_end = 0;
    CHECK(binding->context->publish(&node,1,vp)); check(500,500,0);
    vp.scale = 0; CHECK(binding->context->publish(&node,1,vp));
    bad = (ITextRangeProvider *)1; CHECK(TextReadView::point(binding,node.id,{100,200},&bad) == E_FAIL && !bad);
    vp.scale = 1.75; CHECK(binding->context->publish(&node,1,vp));
    bad = (ITextRangeProvider *)1; CHECK(TextReadView::point(binding,node.id,{NAN,200},&bad) == E_INVALIDARG && !bad);
    bad = (ITextRangeProvider *)1; CHECK(TextReadView::point(binding,node.id,{100,INFINITY},&bad) == E_INVALIDARG && !bad);
    CHECK(TextReadView::point(binding,node.id,{100,200},nullptr) == E_POINTER);
    node.state = 2; CHECK(binding->context->publish(&node,1,vp));
    bad = (ITextRangeProvider *)1; CHECK(TextReadView::point(binding,node.id,{100,200},&bad) == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE && !bad);
    node.state = secure_state; CHECK(binding->context->publish(&node,1,vp));
    bad = (ITextRangeProvider *)1; CHECK(TextReadView::point(binding,node.id,{100,200},&bad) == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE && !bad);
    binding->retain(); zenit_uia_destroy(binding);
    bad = (ITextRangeProvider *)1; CHECK(TextReadView::point(binding,node.id,{100,200},&bad) == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE && !bad);
    binding->release();
    printf("Windows UIA point range reads: %u checks; affine lines, partial Unicode glyphs, screen DPI, empty/unknown, readonly/disabled and redaction\n",checks-before);
}

static void a11y_text_pattern_contract(HWND window) {
    using namespace zenit_uia;
    unsigned before = checks;
    auto *binding = (Binding *)zenit_uia_create(window); CHECK(binding); if (!binding) return;
    InputNode node = {}; node.id = 0x01000046; node.parent_index = no_parent; node.role = 10;
    node.editable = node.uniform_format = node.can_set_selection = 1; node.visible_end = UINT32_MAX;
    node.value = {"A中😀B",9}; node.selection_start = 1; node.selection_end = node.caret = 8;
    node.width = node.height = 100;
    ZenitA11yGeometrySegment pieces[] = {{0,1,10,20,10,20},{1,4,20,20,10,20},{4,8,30,20,10,20},{8,9,40,20,10,20}};
    ZenitA11yCaretCandidate carets[] = {{0,10,20,10,40,10,20,10,40,1,1},{1,20,20,20,40,20,20,20,40,1,1},
        {4,30,20,30,40,30,20,30,40,1,1},{8,40,20,40,40,40,20,40,40,1,1},{9,50,20,50,40,50,20,50,40,1,1}};
    node.geometry_ready = node.carets_ready = 1; node.geometry = {pieces,4}; node.carets = {carets,5};
    Viewport vp{100,200,175,175,1.75}; CHECK(binding->context->publish(&node,1,vp));
    auto *provider = new Provider(binding,node.id); CHECK(provider); if (!provider) { zenit_uia_destroy(binding); return; }
    VARIANT available = {}; CHECK(provider->GetPropertyValue(UIA_IsTextPatternAvailablePropertyId,&available) == S_OK && available.vt == VT_BOOL && available.boolVal); VariantClear(&available);
    IUnknown *unknown = nullptr; CHECK(provider->GetPatternProvider(UIA_TextPatternId,&unknown) == S_OK && unknown);
    ITextProvider *pattern = nullptr;
    if (unknown) { CHECK(unknown->QueryInterface(IID_ITextProvider,(void **)&pattern) == S_OK && pattern); unknown->Release(); }
    if (!pattern) { provider->Release(); zenit_uia_destroy(binding); return; }
    IUnknown *identity = nullptr; CHECK(pattern->QueryInterface(IID_IUnknown,(void **)&identity) == S_OK && identity == static_cast<IUnknown *>(pattern)); if (identity) identity->Release();
    void *unsupported = (void *)1; CHECK(pattern->QueryInterface(IID_IValueProvider,&unsupported) == E_NOINTERFACE && !unsupported);
    CHECK(pattern->QueryInterface(IID_ITextProvider,nullptr) == E_POINTER);
    SupportedTextSelection selection = SupportedTextSelection_None;
    CHECK(pattern->get_SupportedTextSelection(&selection) == S_OK && selection == SupportedTextSelection_Single);
    CHECK(pattern->get_SupportedTextSelection(nullptr) == E_POINTER);
    auto endpoints = [&](ITextRangeProvider *range, uint32_t first, uint32_t last) {
        RangeState *state = nullptr; CHECK(range && range->QueryInterface(range_state_iid,(void **)&state) == S_OK && state);
        if (state) { LONG identity = 0; uint32_t id = 0, a = 99, b = 99;
            CHECK(state->Read(&identity,&id,&a,&b) == S_OK && id == node.id && a == first && b == last); state->Release(); }
    };
    auto array_range = [&](SAFEARRAY *array, uint32_t first, uint32_t last) {
        CHECK(array); if (!array) return;
        LONG high = -1, index = 0; CHECK(SafeArrayGetUBound(array,1,&high) == S_OK && high == 0);
        IUnknown *element = nullptr; CHECK(SafeArrayGetElement(array,&index,&element) == S_OK && element);
        ITextRangeProvider *range = nullptr;
        if (element) { CHECK(element->QueryInterface(IID_ITextRangeProvider,(void **)&range) == S_OK && range); element->Release(); }
        if (range) { endpoints(range,first,last); range->Release(); }
        CHECK(SafeArrayDestroy(array) == S_OK);
    };
    ITextRangeProvider *document = nullptr; CHECK(pattern->get_DocumentRange(&document) == S_OK && document);
    if (document) { endpoints(document,0,5); BSTR text = nullptr; CHECK(document->GetText(-1,&text) == S_OK && text && !wcscmp(text,L"A中😀B")); SysFreeString(text); }
    SAFEARRAY *array = nullptr; CHECK(pattern->GetSelection(&array) == S_OK); array_range(array,1,4);
    array = nullptr; CHECK(pattern->GetVisibleRanges(&array) == S_OK); array_range(array,0,5);
    ITextRangeProvider *point = nullptr; CHECK(pattern->RangeFromPoint({152.5,252.5},&point) == S_OK && point);
    if (point) { endpoints(point,2,2); point->Release(); }
    point = (ITextRangeProvider *)1; CHECK(pattern->RangeFromChild(provider,&point) == E_INVALIDARG && !point);
    point = (ITextRangeProvider *)1; CHECK(pattern->RangeFromChild(nullptr,&point) == E_INVALIDARG && !point);
    CHECK(pattern->GetSelection(nullptr) == E_POINTER && pattern->GetVisibleRanges(nullptr) == E_POINTER);
    CHECK(pattern->get_DocumentRange(nullptr) == E_POINTER && pattern->RangeFromPoint({0,0},nullptr) == E_POINTER);
    const uint32_t states_readonly[] = {1u,1u<<9};
    for (uint32_t state : states_readonly) {
        node.state = state; node.can_set_selection = 0; CHECK(binding->context->publish(&node,1,vp));
        CHECK(pattern->get_SupportedTextSelection(&selection) == S_OK && selection == SupportedTextSelection_Single);
        array = nullptr; CHECK(pattern->GetSelection(&array) == S_OK); array_range(array,1,4);
    }
    node.state = 0; node.geometry_ready = node.carets_ready = 0; node.geometry = {}; node.carets = {};
    CHECK(binding->context->publish(&node,1,vp));
    point = nullptr; CHECK(pattern->get_DocumentRange(&point) == S_OK && point); if (point) point->Release();
    array = (SAFEARRAY *)1; CHECK(pattern->GetVisibleRanges(&array) == (HRESULT)UIA_E_NOTSUPPORTED && !array);
    point = (ITextRangeProvider *)1; CHECK(pattern->RangeFromPoint({152.5,252.5},&point) == (HRESULT)UIA_E_NOTSUPPORTED && !point);
    const uint32_t states_denied[] = {2u,secure_state};
    for (uint32_t state : states_denied) {
        node.state = state; CHECK(binding->context->publish(&node,1,vp));
        CHECK(provider->GetPropertyValue(UIA_IsTextPatternAvailablePropertyId,&available) == S_OK && !available.boolVal); VariantClear(&available);
        unknown = (IUnknown *)1; CHECK(provider->GetPatternProvider(UIA_TextPatternId,&unknown) == S_OK && !unknown);
        point = (ITextRangeProvider *)1; CHECK(pattern->get_DocumentRange(&point) == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE && !point);
    }
    node.state = 0; node.uniform_format = 0; CHECK(binding->context->publish(&node,1,vp));
    point = (ITextRangeProvider *)1; CHECK(pattern->get_DocumentRange(&point) == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE && !point);
    binding->retain(); zenit_uia_destroy(binding);
    point = (ITextRangeProvider *)1; CHECK(pattern->RangeFromPoint({0,0},&point) == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE && !point);
    selection = SupportedTextSelection_Single; CHECK(pattern->get_SupportedTextSelection(&selection) == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE && selection == SupportedTextSelection_None);
    if (document) { BSTR text = (BSTR)1; CHECK(document->GetText(-1,&text) == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE && !text); document->Release(); }
    pattern->Release(); provider->Release(); binding->release();
    printf("Windows public TextPattern: %u checks; COM identity, Unicode, document/selection/visible/point reads, child rejection, pending layout, readonly/disabled and retained revocation\n",checks-before);
}
