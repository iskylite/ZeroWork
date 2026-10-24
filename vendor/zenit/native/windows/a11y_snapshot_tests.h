#pragma once
#include "a11y_snapshot.h"

static void a11y_geometry_contract() {
    using namespace zenit_a11y;
    unsigned before = checks;
    InputNode input = {}; input.id = 1; input.parent_index = no_parent; input.role = 10;
    input.editable = input.geometry_ready = 1; input.visible_end = UINT32_MAX;
    input.value = {"A中😀B", 9};
    ZenitA11yGeometrySegment pieces[] = {{4,8,10,20,30,16},{1,4,40,20,10,16},{8,9,50,20,8,16}};
    input.geometry = {pieces,3};
    auto *context = new Context; CHECK(context); if (!context) return;
    CHECK(context->publish(&input,1));
    auto *retained = context->acquire(); CHECK(retained);
    if (retained) {
        const auto *n = retained->find(1);
        CHECK(n && n->geometry_ready && n->geometry_count == 3);
        if (n && n->geometry_count == 3) {
            CHECK(n->geometry[0].start == 2 && n->geometry[0].end == 4);
            CHECK(n->geometry[1].start == 1 && n->geometry[1].end == 2);
            CHECK(n->geometry[2].start == 4 && n->geometry[2].end == 5);
            CHECK(n->geometry[0].x == 10 && n->geometry[0].width == 30);
        }
    }
    pieces[0].x = 99;
    CHECK(retained && retained->find(1)->geometry[0].x == 10); // No borrowed array.
    const InputNode valid = input;
    input.geometry_ready = 2; CHECK(!context->publish(&input,1)); input = valid;
    input.geometry_ready = 0; CHECK(!context->publish(&input,1)); input = valid;
    input.geometry.segments = nullptr; CHECK(!context->publish(&input,1)); input = valid;
    input.geometry.count = max_geometry_segments+1; CHECK(!context->publish(&input,1)); input = valid;
    const auto original = pieces[0];
    pieces[0].start = 5; CHECK(!context->publish(&input,1)); pieces[0] = original; // UTF-8 continuation.
    pieces[0].end = 7; CHECK(!context->publish(&input,1)); pieces[0] = original;
    pieces[0].end = 10; CHECK(!context->publish(&input,1)); pieces[0] = original;
    pieces[0].start = pieces[0].end; CHECK(!context->publish(&input,1)); pieces[0] = original;
    pieces[0].width = -1; CHECK(!context->publish(&input,1)); pieces[0] = original;
    pieces[0].height = INFINITY; CHECK(!context->publish(&input,1)); pieces[0] = original;
    pieces[0].x = NAN; CHECK(!context->publish(&input,1)); pieces[0] = original;
    auto *unchanged = context->acquire(); CHECK(unchanged == retained); if (unchanged) unchanged->release();
    input.geometry = {}; CHECK(context->publish(&input,1));
    auto *empty = context->acquire(); CHECK(empty && empty->find(1)->geometry_ready && !empty->find(1)->geometry_count);
    if (empty) empty->release();
    input.geometry_ready = 0; CHECK(context->publish(&input,1));
    auto *unavailable = context->acquire(); CHECK(unavailable && !unavailable->find(1)->geometry_ready);
    if (unavailable) unavailable->release();
    input = valid; input.state = secure_state;
    input.value = {(const char *)1, max_string_bytes};
    input.geometry = {(const ZenitA11yGeometrySegment *)1, SIZE_MAX};
    CHECK(context->publish(&input,1)); // Secure geometry/value must never be dereferenced.
    auto *secure = context->acquire();
    CHECK(secure && !secure->find(1)->geometry_ready && !secure->find(1)->geometry_count && !secure->find(1)->geometry);
    if (secure) secure->release();
    context->disconnect(); CHECK(!context->acquire()); context->release();
    CHECK(retained && retained->find(1)->geometry[0].start == 2 && retained->find(1)->geometry[0].x == 10);
    if (retained) retained->release();

    // Reverse visual order across a long Unicode source exercises the sorted
    // endpoint conversion rather than quadratic full-prefix conversions.
    constexpr size_t repetitions = 10000;
    char *text = (char *)malloc(9*repetitions);
    auto *many = (ZenitA11yGeometrySegment *)malloc(repetitions*sizeof(ZenitA11yGeometrySegment));
    CHECK(text && many);
    if (text && many) {
        for (size_t i = 0; i < repetitions; ++i) {
            memcpy(text+9*i,"A中😀B",9);
            const uint32_t at = (uint32_t)(repetitions-1-i);
            many[i] = {9*at+4,9*at+8,(float)i,20,1,16};
        }
        input = valid; input.value = {text,9*repetitions}; input.geometry = {many,repetitions};
        auto *large = Snapshot::create(&input,1); CHECK(large);
        if (large) {
            const auto *n = large->find(1); CHECK(n && n->geometry_count == repetitions);
            bool converted = n != nullptr;
            if (n) for (size_t i = 0; i < repetitions; ++i) {
                const uint32_t at = (uint32_t)(repetitions-1-i);
                converted &= n->geometry[i].start == 5*at+2 && n->geometry[i].end == 5*at+4;
            }
            CHECK(converted); large->release();
        }
    }
    free(text); free(many);
    auto *quota_pieces = (ZenitA11yGeometrySegment *)malloc(max_geometry_segments*sizeof(ZenitA11yGeometrySegment));
    CHECK(quota_pieces);
    if (quota_pieces) {
        for (size_t i = 0; i < max_geometry_segments; ++i) quota_pieces[i] = {0,1,0,0,1,16};
        InputNode nodes[6] = {};
        for (uint32_t i = 0; i < 6; ++i) {
            nodes[i] = valid; nodes[i].id = i;
            nodes[i].geometry = {quota_pieces,max_geometry_segments};
        }
        auto *within = Snapshot::create(nodes,5); CHECK(within); if (within) within->release();
        CHECK(!Snapshot::create(nodes,6)); // Aggregate geometry budget, not just per-node quota.
        free(quota_pieces);
    }
    printf("Windows accessibility geometry snapshot: %u checks; owned visual order, UTF16, rejection, known-empty, redaction, retained lifetime and 10000 reversed Unicode pieces\n",checks-before);
}

static void a11y_caret_contract() {
    using namespace zenit_a11y;
    unsigned before = checks;
    InputNode input = {}; input.id = 1; input.parent_index = no_parent; input.role = 10;
    input.editable = input.carets_ready = 1; input.visible_end = UINT32_MAX;
    input.value = {"A中😀B",9};
    ZenitA11yCaretCandidate pieces[] = {
        {8,30,20,30,40,30,25,30,35,1,1},
        {4,10,20,10,40,0,0,0,0,0,0},
        {4,40,20,20,40,0,0,0,0,1,0},
        {9,50,20,50,40,0,0,0,0,1,0}
    };
    input.carets = {pieces,4};
    auto *context = new Context; CHECK(context); if (!context) return;
    CHECK(context->publish(&input,1));
    auto *retained = context->acquire(); CHECK(retained);
    const auto *n = retained ? retained->find(1) : nullptr;
    CHECK(n && n->carets_ready && n->caret_count == 4);
    if (n && n->caret_count == 4) {
        CHECK(n->carets[0].offset == 4 && n->carets[1].offset == 2);
        CHECK(n->carets[2].offset == 2 && n->carets[3].offset == 5);
        CHECK(n->carets[1].downstream == 0 && n->carets[2].downstream == 1);
        CHECK(n->carets[0].visible && n->carets[0].visible_first_y == 25);
        CHECK(!n->carets[1].visible && n->carets[2].first_x == 40 && n->carets[2].last_x == 20);
    }
    pieces[0].first_x = 99;
    CHECK(n && n->carets[0].first_x == 30); pieces[0].first_x = 30;
    const InputNode valid = input; const auto original = pieces[0];
    input.carets_ready = 2; CHECK(!context->publish(&input,1)); input = valid;
    input.carets_ready = 0; CHECK(!context->publish(&input,1)); input = valid;
    input.carets.candidates = nullptr; CHECK(!context->publish(&input,1)); input = valid;
    input.carets.count = max_geometry_segments+1; CHECK(!context->publish(&input,1)); input = valid;
    pieces[0].offset = 5; CHECK(!context->publish(&input,1)); pieces[0] = original;
    pieces[0].offset = 10; CHECK(!context->publish(&input,1)); pieces[0] = original;
    pieces[0].downstream = 2; CHECK(!context->publish(&input,1)); pieces[0] = original;
    pieces[0].visible = 2; CHECK(!context->publish(&input,1)); pieces[0] = original;
    pieces[0].first_x = NAN; CHECK(!context->publish(&input,1)); pieces[0] = original;
    pieces[0].last_y = INFINITY; CHECK(!context->publish(&input,1)); pieces[0] = original;
    pieces[0].last_y = 20; CHECK(!context->publish(&input,1)); pieces[0] = original;
    pieces[0].visible_first_y = NAN; CHECK(!context->publish(&input,1)); pieces[0] = original;
    pieces[0].visible_last_y = 25; CHECK(!context->publish(&input,1)); pieces[0] = original;
    auto *unchanged = context->acquire(); CHECK(unchanged == retained); if (unchanged) unchanged->release();
    input.value = {nullptr,0}; input.carets = {}; CHECK(context->publish(&input,1));
    auto *empty = context->acquire(); CHECK(empty && empty->find(1)->carets_ready && !empty->find(1)->caret_count);
    if (empty) empty->release();
    input.carets_ready = 0; CHECK(context->publish(&input,1));
    auto *unknown = context->acquire(); CHECK(unknown && !unknown->find(1)->carets_ready);
    if (unknown) unknown->release();
    input = valid; input.state = secure_state; input.value = {(const char *)1,SIZE_MAX};
    input.carets = {(const ZenitA11yCaretCandidate *)1,SIZE_MAX};
    CHECK(context->publish(&input,1));
    auto *secure = context->acquire(); CHECK(secure && !secure->find(1)->carets_ready && !secure->find(1)->carets);
    if (secure) secure->release();
    context->disconnect(); CHECK(!context->acquire()); context->release();
    CHECK(n && n->carets[0].offset == 4 && n->carets[0].first_x == 30);
    if (retained) retained->release();
    constexpr size_t repetitions = 10000;
    char *text = (char *)malloc(9*repetitions);
    auto *many = (ZenitA11yCaretCandidate *)calloc(max_geometry_segments,sizeof(ZenitA11yCaretCandidate));
    CHECK(text && many);
    if (text && many) {
        for (size_t i = 0; i < repetitions; ++i) {
            memcpy(text+9*i,"A中😀B",9);
            many[i] = original; many[i].offset = 9*(uint32_t)(repetitions-1-i)+4;
        }
        input = valid; input.value = {text,9*repetitions}; input.carets = {many,repetitions};
        auto *large = Snapshot::create(&input,1); CHECK(large);
        bool converted = large != nullptr;
        if (large) {
            n = large->find(1);
            for (size_t i = 0; i < repetitions; ++i) converted &= n->carets[i].offset == 5*(repetitions-1-i)+2;
            large->release();
        }
        CHECK(converted);
        for (size_t i = 0; i < max_geometry_segments; ++i) { many[i] = original; many[i].offset = 0; }
        InputNode nodes[4] = {};
        for (uint32_t i = 0; i < 4; ++i) { nodes[i] = valid; nodes[i].id = i; nodes[i].carets = {many,max_geometry_segments}; }
        auto *within = Snapshot::create(nodes,3); CHECK(within); if (within) within->release();
        CHECK(!Snapshot::create(nodes,4));
    }
    free(text); free(many);
    printf("Windows accessibility caret snapshot: %u checks; owned affine lines, repeated offsets, UTF16, redaction, quotas and retained lifetime\n",checks-before);
}

static void a11y_rows_contract() {
    using namespace zenit_a11y;
    unsigned before = checks;
    InputNode input = {}; input.id = 1; input.parent_index = no_parent; input.role = 10;
    input.editable = input.rows_ready = 1; input.visible_end = UINT32_MAX; input.value = {"😀\n\n",6};
    ZenitA11yGeometrySegment rows[] = {{0,5,10,20,100,20},{5,6,10,40,100,20},{6,6,10,60,100,20}};
    input.rows = {rows,3};
    auto *context = new Context; CHECK(context); if (!context) return;
    CHECK(context->publish(&input,1)); auto *retained = context->acquire(); CHECK(retained);
    const auto *node = retained ? retained->find(1) : nullptr;
    CHECK(node && node->rows_ready && node->row_count == 3);
    if (node && node->row_count == 3) {
        CHECK(node->rows[0].start == 0 && node->rows[0].end == 3);
        CHECK(node->rows[1].start == 3 && node->rows[1].end == 4);
        CHECK(node->rows[2].start == 4 && node->rows[2].end == 4);
    }
    const auto valid = input; const auto original = rows[0];
    rows[0].x = 99; CHECK(node && node->rows[0].x == 10); rows[0] = original;
    rows[0].start = 1; CHECK(!context->publish(&input,1)); rows[0] = original;
    rows[0].end = 7; CHECK(!context->publish(&input,1)); rows[0] = original;
    rows[0].start = 6; CHECK(!context->publish(&input,1)); rows[0] = original;
    rows[0].height = 0; CHECK(!context->publish(&input,1)); rows[0] = original;
    rows[1].start = 0; CHECK(!context->publish(&input,1)); rows[1].start = 5;
    rows[0].x = NAN; CHECK(!context->publish(&input,1)); rows[0] = original;
    input.rows_ready = 0; CHECK(!context->publish(&input,1)); input = valid;
    input.rows_ready = 2; CHECK(!context->publish(&input,1)); input = valid;
    input.rows.segments = nullptr; CHECK(!context->publish(&input,1)); input = valid;
    input.rows.count = max_geometry_segments+1; CHECK(!context->publish(&input,1)); input = valid;
    auto *unchanged = context->acquire(); CHECK(unchanged == retained); if (unchanged) unchanged->release();
    input.rows = {}; CHECK(context->publish(&input,1));
    auto *empty = context->acquire(); CHECK(empty && empty->find(1)->rows_ready && !empty->find(1)->row_count);
    if (empty) empty->release();
    input.rows_ready = 0; CHECK(context->publish(&input,1));
    auto *unknown = context->acquire(); CHECK(unknown && !unknown->find(1)->rows_ready);
    if (unknown) unknown->release();
    input = valid; input.state = secure_state;
    input.value = {(const char *)1,SIZE_MAX}; input.rows = {(const ZenitA11yGeometrySegment *)1,SIZE_MAX};
    CHECK(context->publish(&input,1));
    auto *secure = context->acquire(); CHECK(secure && !secure->find(1)->rows_ready && !secure->find(1)->rows);
    if (secure) secure->release();
    context->disconnect(); context->release();
    CHECK(node && node->rows[1].start == 3 && node->rows[1].y == 40);
    if (retained) retained->release();
    printf("Windows accessibility row snapshot: %u checks; owned UTF16 rows, terminal offsets, validation, redaction and retained lifetime\n",checks-before);
}

struct A11yReadState {
    zenit_a11y::Context *context;
    HANDLE started;
    volatile LONG stop = 0, errors = 0, reads = 0;
};
static DWORD WINAPI a11y_reader(void *opaque) {
    auto *state = (A11yReadState *)opaque;
    while (!InterlockedCompareExchange(&state->stop, 0, 0)) {
        auto *snapshot = state->context->acquire();
        if (!snapshot) { SwitchToThread(); continue; }
        const auto *node = snapshot->find(0x01000002);
        if (snapshot->count() != 2 || !node || wcscmp(node->name, L"中文 🧪") ||
                wcscmp(node->value, L"frame value") || node->parent_index != 0)
            InterlockedIncrement(&state->errors);
        InterlockedIncrement(&state->reads);
        SetEvent(state->started);
        snapshot->release();
    }
    state->context->release();
    return 0;
}
static void a11y_snapshot_contract() {
    using namespace zenit_a11y;
    unsigned before = checks;
    InputNode input[2] = {};
    input[0].id = 0; input[0].parent_index = no_parent; input[0].role = 1;
    input[1].id = 0x01000002; input[1].parent_index = 0; input[1].role = 10;
    input[1].width = 100; input[1].height = 30;
    char borrowed[] = "中文 🧪";
    input[1].name = {borrowed, sizeof(borrowed)-1};
    input[1].value = {"frame value", 11};
    auto *context = new Context;
    CHECK(context); if (!context) return;
    CHECK(context->publish(input, 2));
    auto *first = context->acquire(); CHECK(first);
    memset(borrowed, 'x', sizeof(borrowed)-1);
    if (first) {
        CHECK(first->count() == 2 && first->at(2) == nullptr);
        CHECK(first->find(2) == nullptr); // Same slot, wrong generation.
        const auto *node = first->find(0x01000002);
        CHECK(node && wcscmp(node->name, L"中文 🧪") == 0);
    }
    input[1].name = {"中文 🧪", strlen("中文 🧪")};
    const InputNode valid = input[1];
    input[1].parent_index = 1; CHECK(!context->publish(input, 2)); // Cycle/self.
    input[1] = valid; input[1].id = 0; CHECK(!context->publish(input, 2)); // Duplicate.
    input[1] = valid; input[1].width = -1; CHECK(!context->publish(input, 2));
    input[1] = valid; input[1].x = NAN; CHECK(!context->publish(input, 2));
    input[1] = valid; input[1].state = 1u << 19; CHECK(!context->publish(input, 2));
    input[1] = valid; input[1].small_change = -1; CHECK(!context->publish(input, 2));
    input[1] = valid; input[1].large_change = INFINITY; CHECK(!context->publish(input, 2));
    input[1] = valid; input[1].setters = 16; CHECK(!context->publish(input, 2));
    input[1] = valid; input[1].actions = 16; CHECK(!context->publish(input, 2));
    input[1] = valid; input[1].name = {"\xff", 1}; CHECK(!context->publish(input, 2));
    input[1] = valid; input[1].name = {"a\0b", 3}; CHECK(!context->publish(input, 2));
    input[1] = valid; input[1].name = {nullptr, 1}; CHECK(!context->publish(input, 2));
    input[1] = valid; input[1].name = {"x", max_string_bytes+1}; CHECK(!context->publish(input, 2));
    input[1] = valid; input[1].numeric = true; input[1].value_min = 2;
    CHECK(!context->publish(input, 2));
    CHECK(!context->publish(nullptr, 1)); CHECK(!context->publish(input, max_nodes+1));
    auto *unchanged = context->acquire(); CHECK(unchanged == first);
    if (unchanged) unchanged->release();
    // A role value never rejects the tree: roles added after the UIA mapping
    // (52-54 once did) must not take down the whole snapshot every frame.
    const uint16_t roles[] = {52, 54, 0xffff};
    for (uint16_t role : roles) {
        input[1] = valid; input[1].role = role; CHECK(context->publish(input, 2));
        auto *published = context->acquire(); CHECK(published && published->find(valid.id));
        if (published) published->release();
    }
    input[1] = valid; input[1].state = secure_state; input[1].numeric = true;
    input[1].value_now = 5; input[1].value_min = 0; input[1].value_max = 10;
    CHECK(context->publish(input, 2));
    auto *secure = context->acquire(); CHECK(secure);
    if (secure) {
        const auto *node = secure->find(valid.id);
        CHECK(node && !node->value[0] && !node->numeric && node->value_now == 0);
        secure->release();
    }
    if (first) { CHECK(wcscmp(first->find(valid.id)->value, L"frame value") == 0); first->release(); }
    input[1] = valid;
    char editable_text[] = "A中😀B";
    input[1].value = {editable_text, sizeof(editable_text)-1};
    input[1].editable = 1; input[1].can_set_selection = 1;
    input[1].selection_start = 8; input[1].selection_end = 1; input[1].caret = 8;
    input[1].visible_start = 1; input[1].visible_end = 8;
    CHECK(context->publish(input, 2));
    auto *editing = context->acquire(); CHECK(editing);
    if (editing) {
        const Node *node = editing->find(valid.id);
        CHECK(node && node->editable && node->can_set_selection && node->text_length == 5);
        CHECK(node && node->selection_start == 4 && node->selection_end == 1 && node->caret == 4);
        CHECK(node && node->visible_start == 1 && node->visible_end == 4);
        const InputNode valid_editing = input[1];
        input[1].caret = 2; CHECK(!context->publish(input, 2)); // Inside Han UTF-8 scalar.
        input[1] = valid_editing; input[1].selection_end = 5; CHECK(!context->publish(input, 2)); // Inside emoji.
        input[1] = valid_editing; input[1].selection_start = 10; CHECK(!context->publish(input, 2));
        input[1] = valid_editing; input[1].visible_start = 8; input[1].visible_end = 1; CHECK(!context->publish(input, 2));
        input[1] = valid_editing; input[1].editable = 2; CHECK(!context->publish(input, 2));
        input[1] = valid_editing; input[1].can_set_selection = 2; CHECK(!context->publish(input, 2));
        input[1] = valid_editing; input[1].editable = 0; CHECK(!context->publish(input, 2));
        auto *same = context->acquire(); CHECK(same == editing); if (same) same->release();
        input[1] = valid_editing; input[1].visible_start = 0; input[1].visible_end = UINT32_MAX;
        CHECK(context->publish(input, 2));
        auto *full = context->acquire(); CHECK(full);
        if (full) { const Node *all = full->find(valid.id); CHECK(all && all->visible_end == 5); full->release(); }
        input[1] = valid_editing; input[1].state = secure_state; input[1].caret = UINT32_MAX;
        CHECK(context->publish(input, 2));
        auto *password = context->acquire(); CHECK(password);
        if (password) {
            const Node *hidden = password->find(valid.id);
            CHECK(hidden && !hidden->editable && !hidden->can_set_selection && hidden->text_length == 0 && !hidden->value[0]);
            CHECK(hidden && !hidden->selection_start && !hidden->selection_end && !hidden->caret && !hidden->visible_start && !hidden->visible_end);
            password->release();
        }
        memset(editable_text, 'x', sizeof(editable_text)-1);
        CHECK(wcscmp(editing->find(valid.id)->value, L"A中😀B") == 0 && editing->find(valid.id)->caret == 4);
        editing->release();
    }
    input[1] = valid; CHECK(context->publish(input, 2));
    A11yReadState readers[4] = {}; HANDLE threads[4] = {};
    for (unsigned i = 0; i < 4; ++i) {
        readers[i].context = context; readers[i].started = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        CHECK(readers[i].started);
        context->retain(); threads[i] = CreateThread(nullptr, 0, a11y_reader, &readers[i], 0, nullptr);
        CHECK(threads[i]);
        if (threads[i]) CHECK(WaitForSingleObject(readers[i].started, 5000) == WAIT_OBJECT_0);
        else context->release();
    }
    bool published = true;
    for (unsigned i = 0; i < 1000; ++i) {
        input[1].x = (float)i;
        published &= context->publish(input, 2);
        SwitchToThread();
    }
    CHECK(published);
    auto *survivor = context->acquire(); CHECK(survivor);
    context->disconnect(); context->disconnect();
    CHECK(!context->acquire()); CHECK(!context->publish(input, 2));
    for (unsigned i = 0; i < 4; ++i) InterlockedExchange(&readers[i].stop, 1);
    for (unsigned i = 0; i < 4; ++i) {
        if (threads[i]) {
            DWORD wait = WaitForSingleObject(threads[i], 10000); CHECK(wait == WAIT_OBJECT_0);
            // Stack reader state must never outlive this function on failure.
            if (wait != WAIT_OBJECT_0) ExitProcess(2);
            CHECK(readers[i].errors == 0 && readers[i].reads > 0); CloseHandle(threads[i]);
        }
        if (readers[i].started) CloseHandle(readers[i].started);
    }
    context->release();
    if (survivor) { CHECK(survivor->find(valid.id)->x == 999); survivor->release(); }
    auto *empty = Snapshot::create(nullptr, 0); CHECK(empty && !empty->count() && !empty->find(0));
    if (empty) empty->release();
    auto *many = (InputNode *)calloc(max_nodes, sizeof(InputNode)); CHECK(many);
    if (many) {
        for (size_t i = 0; i < max_nodes; ++i) {
            many[i].id = (uint32_t)i; many[i].parent_index = i ? (uint32_t)i-1 : no_parent;
        }
        auto *maximum = Snapshot::create(many, max_nodes); CHECK(maximum && maximum->count() == max_nodes);
        if (maximum) { CHECK(maximum->find((uint32_t)max_nodes-1)); maximum->release(); }
        free(many);
    }
    char *large = (char *)malloc(max_string_bytes/2); CHECK(large);
    if (large) {
        memset(large, 'a', max_string_bytes/2);
        input[1] = valid; input[1].name = {large, max_string_bytes/2};
        input[1].description = {large, max_string_bytes/2}; input[1].value = {};
        auto *budget = Snapshot::create(input, 2); CHECK(budget);
        if (budget) budget->release();
        input[1].value = {"x", 1}; CHECK(!Snapshot::create(input, 2));
        free(large);
    }
    printf("Windows accessibility snapshot: %u checks; 1000 publications, 4 concurrent readers\n", checks-before);
}
