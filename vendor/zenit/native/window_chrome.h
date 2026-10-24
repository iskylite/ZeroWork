#ifndef ZENIT_WINDOW_CHROME_H
#define ZENIT_WINDOW_CHROME_H
#include <stdint.h>
typedef struct { float x,y,w,h; } ZenitChromeRect;
/* corner_radius: logical radius of the four window corners the client must paint itself
   (Wayland client-side decoration); 0 when the platform shapes the window. */
typedef struct { uint32_t flags, capabilities; int32_t controls_count; uint32_t state_generation; ZenitChromeRect controls[3]; uint32_t appearance, button_layout[6], caption_hover, caption_pressed; float corner_radius; } ZenitChromeState;
/* capabilities: custom, frameless, minimize, maximize, fullscreen, move, resize */
#endif
