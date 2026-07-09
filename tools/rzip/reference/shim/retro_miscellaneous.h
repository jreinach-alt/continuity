/* shim: minimal stand-in for libretro-common's retro_miscellaneous.h */
#ifndef SHIM_RETRO_MISC_H
#define SHIM_RETRO_MISC_H
#ifndef MIN
#define MIN(a, b) ((a) < (b) ? (a) : (b))
#endif
#ifndef MAX
#define MAX(a, b) ((a) > (b) ? (a) : (b))
#endif
#endif
