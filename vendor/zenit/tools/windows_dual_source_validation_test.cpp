#include "../native/windows/dual_source_validation.h"
#include <assert.h>
#include <initializer_list>
extern "C" int zenit_test_dual_source_signature() {
    ZenitDualSourceSignature signature;
    signature.target(0,3,15);
    assert(!signature.valid(1,true));
    signature.target(1,3,15);
    assert(signature.valid(1,true));
    assert(!signature.valid(2,true)); assert(!signature.valid(1,false));
    for (auto index : {1u,2u}) {
        ZenitDualSourceSignature bad; bad.target(0,3,15); bad.target(index,2,15);
        assert(!bad.valid(1,true));
    }
    ZenitDualSourceSignature narrow; narrow.target(0,3,15); narrow.target(1,3,7);
    assert(!narrow.valid(1,true));
    return 0;
}
#ifndef ZENIT_TEST_ZIG_ENTRY
int main() { return zenit_test_dual_source_signature(); }
#endif
