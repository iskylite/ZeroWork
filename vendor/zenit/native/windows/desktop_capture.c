/* Included by d3d11_probe.c. Opt-in diagnostic desktop duplication readback.
   It does not draw, advance Cx, activate windows or fall back to GDI surfaces.
   The duplicator persists for the owned monitor; bounded readback and
   DwmFlush still change pacing. */
static int stamp_desktop_frame(ZenitD3D11Probe *probe) {
    if (!probe->context1 || probe->frame>0xffffff) return 0;
    unsigned sequence=probe->frame;
    const float serial[4]={(sequence&255)/255.0f,((sequence>>8)&255)/255.0f,((sequence>>16)&255)/255.0f,1};
    const float magic[4]={53/255.0f,199/255.0f,107/255.0f,1};
    D3D11_RECT a={1,1,4,4},b={5,1,8,4};
    ID3D11DeviceContext1_ClearView(probe->context1,(ID3D11View *)probe->target,serial,&a,1);
    ID3D11DeviceContext1_ClearView(probe->context1,(ID3D11View *)probe->target,magic,&b,1);
    return 1;
}

static int capture_desktop_bmp(ZenitD3D11Probe *probe, unsigned index, LONGLONG present_not_before) {
    wchar_t directory[MAX_PATH], path[MAX_PATH];
    DWORD n=GetEnvironmentVariableW(L"ZENIT_WINDOWS_FRAME_CAPTURE_DIR",directory,MAX_PATH);
    if (!n || n>=MAX_PATH-40) return 0;
    if (IsIconic(probe->hwnd) || GetForegroundWindow()!=probe->hwnd) {
        fprintf(stderr,"[windows-desktop-unavailable] minimized=%d foreground=%d\n",
            IsIconic(probe->hwnd),GetForegroundWindow()==probe->hwnd);
        return 0;
    }
    HMODULE dwm=LoadLibraryExW(L"dwmapi.dll",NULL,LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!dwm) return 0;
    HRESULT (WINAPI *flush)(void)=(HRESULT (WINAPI *)(void))GetProcAddress(dwm,"DwmFlush");
    HRESULT flush_result=flush ? flush() : E_FAIL;
    FreeLibrary(dwm);
    if (FAILED(flush_result)) {
        fprintf(stderr,"[windows-desktop-unavailable] index=%u stage=dwm-flush hr=0x%08lx\n",index,(unsigned long)flush_result);
        return 0;
    }
    HDESK input=OpenInputDesktop(0,FALSE,DESKTOP_READOBJECTS);
    wchar_t input_name[128]={0}, thread_name[128]={0}; DWORD needed=0;
    if (input) {
        GetUserObjectInformationW(input,UOI_NAME,input_name,sizeof(input_name),&needed);
        CloseDesktop(input);
    }
    GetUserObjectInformationW(GetThreadDesktop(GetCurrentThreadId()),UOI_NAME,thread_name,sizeof(thread_name),&needed);
    DWORD process_session=0;
    ProcessIdToSessionId(GetCurrentProcessId(),&process_session);
    fprintf(stderr,"[windows-desktop-session] index=%u input=%ls thread=%ls accessible=%d process_session=%lu console_session=%lu\n",
        index,input_name,thread_name,input!=NULL,(unsigned long)process_session,(unsigned long)WTSGetActiveConsoleSessionId());
    RECT client; POINT origin={0,0};
    if (!GetClientRect(probe->hwnd,&client) || !ClientToScreen(probe->hwnd,&origin)) return 0;
    LONG w=client.right, h=client.bottom;
    if (w<=0 || h<=0 || (uint64_t)w*h*4>UINT32_MAX-54) return 0;

    IDXGIDevice *device=NULL;
    IDXGIAdapter *adapter=NULL;
    IDXGIOutput *output=NULL;
    IDXGIOutput1 *output1=NULL;
    IDXGIOutputDuplication *duplication=NULL;
    IDXGIResource *resource=NULL;
    ID3D11Texture2D *texture=NULL, *staging=NULL;
    HANDLE file=INVALID_HANDLE_VALUE;
    BYTE *pixels=NULL;
    int acquired=0, mapped=0, created=0, ok=0;
    const char *stage="device";
    HRESULT hr=S_OK;
    HMONITOR monitor=MonitorFromWindow(probe->hwnd,MONITOR_DEFAULTTONEAREST);
    if (probe->desktop_duplication && probe->desktop_monitor!=monitor) {
        IDXGIOutputDuplication_Release(probe->desktop_duplication);
        probe->desktop_duplication=NULL;
    }
    duplication=probe->desktop_duplication;
    DXGI_OUTPUT_DESC output_desc={0};
    if (duplication) {
        output_desc.DesktopCoordinates=probe->desktop_output_rect;
        output_desc.Rotation=DXGI_MODE_ROTATION_IDENTITY;
    } else {
        hr=ID3D11Device_QueryInterface(probe->device,&IID_IDXGIDevice,(void **)&device);
        if (FAILED(hr)) goto done;
        stage="adapter";
        hr=IDXGIDevice_GetAdapter(device,&adapter);
        if (FAILED(hr)) goto done;
        stage="output";
        for (UINT i=0;;++i) {
            hr=IDXGIAdapter_EnumOutputs(adapter,i,&output);
            if (FAILED(hr)) goto done;
            hr=IDXGIOutput_GetDesc(output,&output_desc);
            if (FAILED(hr)) goto done;
            if (output_desc.Monitor==monitor) break;
            IDXGIOutput_Release(output); output=NULL;
        }
    }
    // Rotated/multi-output stitching is intentionally outside this fixture
    // capture. The logged visible region limits all subsequent pixel samples.
    if (output_desc.Rotation!=DXGI_MODE_ROTATION_IDENTITY &&
        output_desc.Rotation!=DXGI_MODE_ROTATION_UNSPECIFIED) { hr=E_NOTIMPL; goto done; }
    LONG sx=output_desc.DesktopCoordinates.left, sy=output_desc.DesktopCoordinates.top;
    LONG ex=output_desc.DesktopCoordinates.right, ey=output_desc.DesktopCoordinates.bottom;
    LONG vx=origin.x<sx ? sx-origin.x : 0, vy=origin.y<sy ? sy-origin.y : 0;
    LONG vw=(origin.x+w>ex ? ex-origin.x : w)-vx;
    LONG vh=(origin.y+h>ey ? ey-origin.y : h)-vy;
    if (vw<=0 || vh<=0) { hr=E_INVALIDARG; goto done; }
    if (!duplication) {
        stage="output1";
        hr=IDXGIOutput_QueryInterface(output,&IID_IDXGIOutput1,(void **)&output1);
        if (FAILED(hr)) goto done;
        stage="duplicate-output";
        hr=IDXGIOutput1_DuplicateOutput(output1,(IUnknown *)probe->device,&duplication);
        if (FAILED(hr)) goto done;
        probe->desktop_duplication=duplication;
        probe->desktop_output_rect=output_desc.DesktopCoordinates;
        probe->desktop_monitor=monitor;
    }
    DXGI_OUTDUPL_FRAME_INFO frame_info={0};
    stage="acquire-frame";
    ULONGLONG deadline=GetTickCount64()+300;
retry_image:
    stage="acquire-frame";
    for (;;) {
        hr=IDXGIOutputDuplication_AcquireNextFrame(duplication,50,&frame_info,&resource);
        if (SUCCEEDED(hr)) {
            acquired=1;
            // Duplication can return a pending desktop update from before this
            // Present even after DwmFlush. Never label that image as this frame.
            if (frame_info.LastPresentTime.QuadPart>=present_not_before) break;
            fprintf(stderr,"[windows-desktop-discard] index=%u present_time=%lld present_not_before=%lld\n",
                index,(long long)frame_info.LastPresentTime.QuadPart,(long long)present_not_before);
            IDXGIResource_Release(resource); resource=NULL;
            hr=IDXGIOutputDuplication_ReleaseFrame(duplication);
            acquired=0;
            if (FAILED(hr)) goto done;
        } else if (hr!=DXGI_ERROR_WAIT_TIMEOUT) goto done;
        if (GetTickCount64()>=deadline) {
            stage="no-current-desktop-image-update";
            hr=DXGI_ERROR_WAIT_TIMEOUT;
            goto done;
        }
    }
    stage="texture";
    hr=IDXGIResource_QueryInterface(resource,&IID_ID3D11Texture2D,(void **)&texture);
    if (FAILED(hr)) goto done;
    D3D11_TEXTURE2D_DESC desc;
    ID3D11Texture2D_GetDesc(texture,&desc);
    if (desc.Format!=DXGI_FORMAT_B8G8R8A8_UNORM ||
        origin.x+vx-sx<0 || origin.y+vy-sy<0 ||
        (uint64_t)(origin.x+vx-sx+vw)>desc.Width ||
        (uint64_t)(origin.y+vy-sy+vh)>desc.Height) { hr=E_INVALIDARG; goto done; }
    desc.Width=(UINT)vw; desc.Height=(UINT)vh;
    desc.Usage=D3D11_USAGE_STAGING; desc.BindFlags=0;
    desc.CPUAccessFlags=D3D11_CPU_ACCESS_READ; desc.MiscFlags=0;
    stage="staging";
    hr=ID3D11Device_CreateTexture2D(probe->device,&desc,NULL,&staging);
    if (FAILED(hr)) goto done;
    D3D11_BOX box={(UINT)(origin.x+vx-sx),(UINT)(origin.y+vy-sy),0,
        (UINT)(origin.x+vx-sx+vw),(UINT)(origin.y+vy-sy+vh),1};
    ID3D11DeviceContext_CopySubresourceRegion(probe->context,(ID3D11Resource *)staging,0,0,0,0,
        (ID3D11Resource *)texture,0,&box);
    D3D11_MAPPED_SUBRESOURCE data={0};
    stage="map";
    hr=ID3D11DeviceContext_Map(probe->context,(ID3D11Resource *)staging,0,D3D11_MAP_READ,0,&data);
    if (FAILED(hr)) goto done;
    mapped=1;
    // LastPresentTime also advances for unrelated compositor updates. Require
    // the submitted scene's diagnostic serial, never a content-based match:
    // panel/shadow corruption must still be visible to the independent audit.
    stage="frame-serial";
    if (vx!=0 || vy!=0 || vw<8 || vh<4) { hr=E_INVALIDARG; goto done; }
    const BYTE *serial_pixel=(BYTE *)data.pData+2*data.RowPitch+2*4;
    const BYTE *magic_pixel=(BYTE *)data.pData+2*data.RowPitch+6*4;
    unsigned observed=serial_pixel[2]+((unsigned)serial_pixel[1]<<8)+((unsigned)serial_pixel[0]<<16);
    int magic_ok=magic_pixel[2]==53 && magic_pixel[1]==199 && magic_pixel[0]==107;
    if (!magic_ok || observed!=probe->frame) {
        fprintf(stderr,"[windows-desktop-discard-serial] index=%u observed=%u magic=%d\n",index,observed,magic_ok);
        ID3D11DeviceContext_Unmap(probe->context,(ID3D11Resource *)staging,0); mapped=0;
        ID3D11Texture2D_Release(staging); staging=NULL;
        ID3D11Texture2D_Release(texture); texture=NULL;
        IDXGIResource_Release(resource); resource=NULL;
        hr=IDXGIOutputDuplication_ReleaseFrame(duplication); acquired=0;
        if (FAILED(hr)) goto done;
        if (GetTickCount64()>=deadline) { hr=DXGI_ERROR_WAIT_TIMEOUT; goto done; }
        goto retry_image;
    }
    pixels=(BYTE *)calloc((size_t)w*h,4);
    if (!pixels) { hr=E_OUTOFMEMORY; goto done; }
    for (LONG y=0;y<vh;++y)
        memcpy(pixels+((size_t)(vy+y)*w+vx)*4,(BYTE *)data.pData+(size_t)y*data.RowPitch,(size_t)vw*4);
    swprintf(path,MAX_PATH,L"%ls\\desktop-%04u.bmp",directory,index);
    stage="write";
    file=CreateFileW(path,GENERIC_WRITE,0,NULL,CREATE_ALWAYS,FILE_ATTRIBUTE_NORMAL,NULL);
    if (file==INVALID_HANDLE_VALUE) { hr=HRESULT_FROM_WIN32(GetLastError()); goto done; }
    created=1;
    BITMAPFILEHEADER header={0}; BITMAPINFOHEADER info={0}; DWORD written;
    info.biSize=sizeof(info); info.biWidth=w; info.biHeight=-h;
    info.biPlanes=1; info.biBitCount=32; info.biSizeImage=(DWORD)((uint64_t)w*h*4);
    header.bfType=0x4d42; header.bfOffBits=sizeof(header)+sizeof(info);
    header.bfSize=header.bfOffBits+info.biSizeImage;
    ok=WriteFile(file,&header,sizeof(header),&written,NULL) && written==sizeof(header) &&
        WriteFile(file,&info,sizeof(info),&written,NULL) && written==sizeof(info) &&
        WriteFile(file,pixels,info.biSizeImage,&written,NULL) && written==info.biSizeImage;
    if (!ok) { hr=HRESULT_FROM_WIN32(GetLastError()); goto done; }
    fprintf(stderr,"[windows-desktop-visible] index=%u rect=(%ld,%ld,%ld,%ld) source=dxgi-duplication present_time=%lld present_not_before=%lld frame_serial=%u\n",
        index,vx,vy,vw,vh,(long long)frame_info.LastPresentTime.QuadPart,(long long)present_not_before,observed);
done:
    if (!ok) fprintf(stderr,"[windows-desktop-unavailable] index=%u stage=%s hr=0x%08lx\n",index,stage,(unsigned long)hr);
    if (file!=INVALID_HANDLE_VALUE) CloseHandle(file);
    if (!ok && created) DeleteFileW(path);
    free(pixels);
    if (mapped) ID3D11DeviceContext_Unmap(probe->context,(ID3D11Resource *)staging,0);
    if (staging) ID3D11Texture2D_Release(staging);
    if (texture) ID3D11Texture2D_Release(texture);
    if (resource) IDXGIResource_Release(resource);
    if (acquired) IDXGIOutputDuplication_ReleaseFrame(duplication);
    if (FAILED(hr) && hr!=DXGI_ERROR_WAIT_TIMEOUT && probe->desktop_duplication) {
        IDXGIOutputDuplication_Release(probe->desktop_duplication);
        probe->desktop_duplication=NULL;
    }
    if (output1) IDXGIOutput1_Release(output1);
    if (output) IDXGIOutput_Release(output);
    if (adapter) IDXGIAdapter_Release(adapter);
    if (device) IDXGIDevice_Release(device);
    return ok;
}
