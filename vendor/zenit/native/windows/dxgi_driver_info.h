#pragma once
#include "d3d12_resources.h"
#include <windows.h>
#include <dxgi1_2.h>

static ZenitD12DriverInfo zenit_dxgi_driver_info(IDXGIAdapter *adapter) {
    ZenitD12DriverInfo info={};
    IDXGIAdapter1 *adapter1=nullptr;
    if (SUCCEEDED(adapter->QueryInterface(IID_IDXGIAdapter1,(void **)&adapter1))) {
        DXGI_ADAPTER_DESC1 desc={};
        if (SUCCEEDED(adapter1->GetDesc1(&desc))) {
            info.vendor_id=desc.VendorId; info.device_id=desc.DeviceId;
            info.software=bool(desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE);
        }
        adapter1->Release();
    }
    LARGE_INTEGER version={};
    if (SUCCEEDED(adapter->CheckInterfaceSupport(__uuidof(IDXGIDevice),&version))) {
        uint64_t value=uint64_t(version.QuadPart);
        for (unsigned i=0;i<4;++i) info.driver_version[i]=uint16_t(value>>(48-16*i));
        info.driver_version_known=1;
    }
    return info;
}
