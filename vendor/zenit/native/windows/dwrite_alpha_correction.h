#pragma once
// DirectWrite alpha correction coefficients from Microsoft Windows Terminal.
// Source: https://github.com/microsoft/terminal/blob/e90f9a534cae047fccddacc1ee813a82929662d5/src/renderer/atlas/dwrite_helpers.cpp
// Copyright (c) Microsoft Corporation. Licensed under the MIT license.
// See dwrite_alpha_correction.LICENSE for attribution and license terms.
static void dwrite_gamma_ratios(float gamma, float out[4]) {
    static const float ratios[13][4] = {
        {0,0,0,0}, {.0166f,-.0807f,.2227f,-.0751f},
        {.0350f,-.1760f,.4325f,-.1370f}, {.0543f,-.2821f,.6302f,-.1876f},
        {.0739f,-.3963f,.8167f,-.2287f}, {.0933f,-.5161f,.9926f,-.2616f},
        {.1121f,-.6395f,1.1588f,-.2877f}, {.1300f,-.7649f,1.3159f,-.3080f},
        {.1469f,-.8911f,1.4644f,-.3234f}, {.1627f,-1.0170f,1.6051f,-.3347f},
        {.1773f,-1.1420f,1.7385f,-.3426f}, {.1908f,-1.2652f,1.8650f,-.3476f},
        {.2031f,-1.3864f,1.9851f,-.3501f},
    };
    int index=(int)(gamma*10+.5f); if(index<10) index=10; if(index>22) index=22;
    for(int i=0;i<4;i++) out[i]=ratios[index-10][i]*(i%2 ? 256.f/255.f : 65536.f/(255.f*255.f));
}
static float dwrite_correct_alpha(float a, float foreground, const float ratios[4], float contrast) {
    float adjustment=3-4*foreground;
    if(adjustment<0) adjustment=0; if(adjustment>1) adjustment=1;
    float k=contrast*adjustment;
    a=a*(1+k)/(1+a*k);
    a+=a*(1-a)*((ratios[0]*foreground+ratios[1])*a+(ratios[2]*foreground+ratios[3]));
    return a<0 ? 0 : a>1 ? 1 : a;
}
