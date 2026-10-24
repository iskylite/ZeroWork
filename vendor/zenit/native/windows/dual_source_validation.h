#pragma once
#include <stdint.h>

// SV_Target0/1 must both carry float4 when one attachment uses LCD weights.
struct ZenitDualSourceSignature {
    bool primary = false;
    bool secondary = false;
    bool invalid = false;
    void target(uint32_t index, uint32_t component_type, uint32_t mask) {
        if (index > 1 || component_type != 3 || mask != 15) { invalid = true; return; }
        if (index == 0) primary = true; else secondary = true;
    }
    bool valid(uint32_t target_count, bool blended) const {
        return target_count == 1 && blended && primary && secondary && !invalid;
    }
};
