/* bst_dump — bsnes .bst save-state decode oracle (Spike T2.0, P0).
 *
 * Read-only field-inventory tool for the pilot's ENCODE target: validates
 * the .bst container, RLE<1>-decodes the serializer stream, checks the
 * stream header gates exactly as bsnes unserialize does, then walks the
 * positional plain-cart block sequence field by field, printing every
 * field in stream order. The walk is a line-for-line transcription of the
 * pinned serialize functions — it IS the executable inventory.
 *
 * Format truth: vendored bsnes @ 7d5aa1e656b9171524d01b1b22917197d8121cb4
 *   container: bsnes/target-bsnes/program/states.cpp:1,55-100
 *   rle:       nall/encode/rle.hpp + nall/decode/rle.hpp (S=1, M=4)
 *   header:    bsnes/sfc/system/serialization.cpp:1-48
 *   blocks:    serializeAll order, serialization.cpp:52-98
 *   fields:    sfc/{cpu,smp,dsp}/serialization.cpp, processor/wdc65816 +
 *              processor/spc700 serialization.cpp, sfc/ppu/serialization.cpp
 *              (3-int display prefix + fastPPU dispatch), sfc/ppu-fast/
 *              serialization.cpp; widths from the corresponding .hpp files
 *              per nall rules (Natural<N> at utype width, bool = 1 byte).
 *
 * Scope: fastPPU=true streams (the default build and the only layout the
 * pilot pipeline produces or consumes). fastPPU=0 and synchronize=0 are
 * detected and reported, not walked. Coprocessor carts are refused
 * mechanically: after the plain-cart walk, leftover bytes mean chip
 * blocks were present (their fields sit between dsp and the (empty)
 * controller ports, so the walk itself also derails — either way != 0).
 *
 * Usage: bst_dump [-s sram_bytes] [-H] file.bst   (default sram 0)
 * Output: "path = value" scalars / "path : N bytes crc32=..." arrays,
 * in exact stream order. Deterministic for byte-identical input.
 * Exit: 0 clean, 2 refused (sync=0 / fastppu=0 / residual bytes), 1 malformed.
 * Desktop-tier x86_64 tool; C99 + zlib (crc32 only). Never ships to a device.
 */

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

static void die(const char *msg)
{
    fprintf(stderr, "bst_dump: %s\n", msg);
    exit(1);
}

/* ---- stream cursor ---- */
static const uint8_t *g_data;
static size_t g_size, g_pos;

/* Offset-map mode (-O): emit "offset\tlength\tname" for every field instead
 * of decoded values, so an encoder (transmute_snes.c / the Python encoder)
 * can locate each architectural domain's byte range in the payload without
 * duplicating this positional walk. Additive: default output is unchanged. */
static int g_offmode = 0;

static const uint8_t *take(size_t n, const char *path)
{
    if (g_pos + n > g_size) {
        fprintf(stderr, "bst_dump: stream underrun at %s (want %zu, have %zu)\n",
                path, n, g_size - g_pos);
        exit(1);
    }
    const uint8_t *p = g_data + g_pos;
    g_pos += n;
    return p;
}

static uint64_t uint_field(const char *path, unsigned bytes)
{
    size_t off = g_pos;
    const uint8_t *p = take(bytes, path);
    uint64_t v = 0;
    for (unsigned i = 0; i < bytes; i++)
        v |= (uint64_t)p[i] << (8 * i);
    if (g_offmode)
        printf("%zu\t%u\t%s\n", off, bytes, path);
    else
        printf("%s = 0x%llx (%llu)\n", path, (unsigned long long)v,
               (unsigned long long)v);
    return v;
}

static void array_field(const char *path, size_t bytes)
{
    size_t off = g_pos;
    const uint8_t *p = take(bytes, path);
    if (g_offmode) {
        printf("%zu\t%zu\t%s\n", off, bytes, path);
        return;
    }
    uLong crc = crc32(0L, p, bytes);
    printf("%s : %zu bytes crc32=%08lx\n", path, bytes, (unsigned long)crc);
}

/* table-driven scalar runs: {name, width}, name NULL terminates */
struct field { const char *name; unsigned bytes; };

static void run_fields(const char *prefix, const struct field *t)
{
    char path[256];
    for (; t->name; t++) {
        snprintf(path, sizeof(path), "%s.%s", prefix, t->name);
        uint_field(path, t->bytes);
    }
}

/* ---- shared sub-blocks ---- */

/* sfc/sfc.hpp:95-100 — uint32 frequency, int64 clock */
static const struct field thread_fields[] = {
    { "thread.frequency", 4 }, { "thread.clock", 8 }, { NULL, 0 }
};

/* sfc/ppu/counter/serialization.cpp — bool,bool,uint x4; uint x2 */
static const struct field ppucounter_fields[] = {
    { "counter.time.interlace", 1 }, { "counter.time.field", 1 },
    { "counter.time.vperiod", 4 },   { "counter.time.hperiod", 4 },
    { "counter.time.vcounter", 4 },  { "counter.time.hcounter", 4 },
    { "counter.last.vperiod", 4 },   { "counter.last.hperiod", 4 },
    { NULL, 0 }
};

/* ---- cpu block (sfc/cpu/serialization.cpp:1-107) ---- */
static void walk_cpu(void)
{
    /* processor/wdc65816/serialization.cpp; widths wdc65816.hpp:25-289 */
    static const struct field wdc[] = {
        { "wdc.pc", 4 },
        { "wdc.a", 2 }, { "wdc.x", 2 }, { "wdc.y", 2 }, { "wdc.z", 2 },
        { "wdc.s", 2 }, { "wdc.d", 2 }, { "wdc.b", 1 },
        { "wdc.p.c", 1 }, { "wdc.p.z", 1 }, { "wdc.p.i", 1 }, { "wdc.p.d", 1 },
        { "wdc.p.x", 1 }, { "wdc.p.m", 1 }, { "wdc.p.v", 1 }, { "wdc.p.n", 1 },
        { "wdc.e", 1 }, { "wdc.irq", 1 }, { "wdc.wai", 1 }, { "wdc.stp", 1 },
        { "wdc.vector", 2 }, { "wdc.mar", 4 }, { "wdc.mdr", 1 },
        { "wdc.u", 4 }, { "wdc.v", 4 }, { "wdc.w", 4 },
        { NULL, 0 }
    };
    run_fields("cpu", wdc);
    run_fields("cpu", thread_fields);
    run_fields("cpu", ppucounter_fields);

    array_field("cpu.wram", 128 * 1024);

    /* widths sfc/cpu/cpu.hpp:83-260 */
    static const struct field tail[] = {
        { "version", 4 },
        { "counter.cpu", 4 }, { "counter.dma", 4 },
        { "status.clockCount", 4 },
        { "status.irqLock", 1 },
        { "status.dramRefreshPosition", 4 }, { "status.dramRefresh", 4 },
        { "status.hdmaSetupPosition", 4 }, { "status.hdmaSetupTriggered", 1 },
        { "status.hdmaPosition", 4 }, { "status.hdmaTriggered", 1 },
        { "status.nmiValid", 1 }, { "status.nmiLine", 1 },
        { "status.nmiTransition", 1 }, { "status.nmiPending", 1 },
        { "status.nmiHold", 1 },
        { "status.irqValid", 1 }, { "status.irqLine", 1 },
        { "status.irqTransition", 1 }, { "status.irqPending", 1 },
        { "status.irqHold", 1 },
        { "status.resetPending", 1 }, { "status.interruptPending", 1 },
        { "status.dmaActive", 1 }, { "status.dmaPending", 1 },
        { "status.hdmaPending", 1 }, { "status.hdmaMode", 1 },
        { "status.autoJoypadCounter", 4 },
        { "status.autoJoypadPort1", 1 }, { "status.autoJoypadPort2", 1 },
        { "status.cpuLatch", 1 }, { "status.autoJoypadLatch", 1 },
        { "io.wramAddress", 4 },
        { "io.hirqEnable", 1 }, { "io.virqEnable", 1 }, { "io.irqEnable", 1 },
        { "io.nmiEnable", 1 }, { "io.autoJoypadPoll", 1 },
        { "io.pio", 1 },
        { "io.wrmpya", 1 }, { "io.wrmpyb", 1 },
        { "io.wrdiva", 2 }, { "io.wrdivb", 1 },
        { "io.htime", 2 }, { "io.vtime", 2 },
        { "io.fastROM", 1 },
        { "io.rddiv", 2 }, { "io.rdmpy", 2 },
        { "io.joy1", 2 }, { "io.joy2", 2 }, { "io.joy3", 2 }, { "io.joy4", 2 },
        { "alu.mpyctr", 4 }, { "alu.divctr", 4 }, { "alu.shift", 4 },
        { NULL, 0 }
    };
    run_fields("cpu", tail);

    static const struct field chan[] = {
        { "dmaEnable", 1 }, { "hdmaEnable", 1 }, { "direction", 1 },
        { "indirect", 1 }, { "unused", 1 }, { "reverseTransfer", 1 },
        { "fixedTransfer", 1 }, { "transferMode", 1 },
        { "targetAddress", 1 }, { "sourceAddress", 2 }, { "sourceBank", 1 },
        { "transferSize", 2 }, { "indirectBank", 1 }, { "hdmaAddress", 2 },
        { "lineCounter", 1 }, { "unknown", 1 },
        { "hdmaCompleted", 1 }, { "hdmaDoTransfer", 1 },
        { NULL, 0 }
    };
    for (int i = 0; i < 8; i++) {
        char prefix[32];
        snprintf(prefix, sizeof(prefix), "cpu.channel[%d]", i);
        run_fields(prefix, chan);
    }
}

/* ---- smp block (sfc/smp/serialization.cpp:1-55) ---- */
static void walk_smp(void)
{
    /* processor/spc700/serialization.cpp */
    static const struct field spc700[] = {
        { "spc700.pc", 2 }, { "spc700.ya", 2 }, { "spc700.x", 1 },
        { "spc700.s", 1 },
        { "spc700.p.c", 1 }, { "spc700.p.z", 1 }, { "spc700.p.i", 1 },
        { "spc700.p.h", 1 }, { "spc700.p.b", 1 }, { "spc700.p.p", 1 },
        { "spc700.p.v", 1 }, { "spc700.p.n", 1 },
        { "spc700.wait", 1 }, { "spc700.stop", 1 },
        { NULL, 0 }
    };
    run_fields("smp", spc700);
    run_fields("smp", thread_fields);

    /* widths sfc/smp/smp.hpp:24-91 */
    static const struct field io[] = {
        { "io.clockCounter", 4 }, { "io.dspCounter", 4 },
        { "io.apu0", 1 }, { "io.apu1", 1 }, { "io.apu2", 1 }, { "io.apu3", 1 },
        { "io.timersDisable", 1 }, { "io.ramWritable", 1 },
        { "io.ramDisable", 1 }, { "io.timersEnable", 1 },
        { "io.externalWaitStates", 1 }, { "io.internalWaitStates", 1 },
        { "io.iplromEnable", 1 },
        { "io.dspAddr", 1 },
        { "io.cpu0", 1 }, { "io.cpu1", 1 }, { "io.cpu2", 1 }, { "io.cpu3", 1 },
        { "io.aux4", 1 }, { "io.aux5", 1 },
        { NULL, 0 }
    };
    run_fields("smp", io);

    static const struct field timer[] = {
        { "stage0", 1 }, { "stage1", 1 }, { "stage2", 1 }, { "stage3", 1 },
        { "line", 1 }, { "enable", 1 }, { "target", 1 },
        { NULL, 0 }
    };
    for (int i = 0; i < 3; i++) {
        char prefix[32];
        snprintf(prefix, sizeof(prefix), "smp.timer%d", i);
        run_fields(prefix, timer);
    }
}

/* ---- ppu block, fastPPU=true layout ----
 * sfc/ppu/serialization.cpp:1-8 (display prefix, dispatch) +
 * sfc/ppu-fast/serialization.cpp:1-166; widths sfc/ppu-fast/ppu.hpp:10-290 */
static void walk_ppu_fast(void)
{
    static const struct field display[] = {
        { "display.interlace", 1 }, { "display.overscan", 1 },
        { "display.vdisp", 4 },
        { NULL, 0 }
    };
    run_fields("ppu", display);
    run_fields("ppufast", thread_fields);
    run_fields("ppufast", ppucounter_fields);

    static const struct field latch[] = {
        { "latch.interlace", 1 }, { "latch.overscan", 1 }, { "latch.hires", 1 },
        { "latch.hd", 1 }, { "latch.ss", 1 },
        { "latch.vram", 2 }, { "latch.oam", 1 }, { "latch.cgram", 1 },
        { "latch.oamAddress", 2 }, { "latch.cgramAddress", 1 },
        { "latch.mode7", 1 }, { "latch.counters", 1 },
        { "latch.hcounter", 1 }, { "latch.vcounter", 1 },
        { "latch.ppu1.mdr", 1 }, { "latch.ppu1.bgofs", 1 },
        { "latch.ppu2.mdr", 1 }, { "latch.ppu2.bgofs", 1 },
        { NULL, 0 }
    };
    run_fields("ppufast", latch);

    static const struct field io[] = {
        { "io.displayDisable", 1 }, { "io.displayBrightness", 1 },
        { "io.oamBaseAddress", 2 }, { "io.oamAddress", 2 },
        { "io.oamPriority", 1 },
        { "io.bgPriority", 1 }, { "io.bgMode", 1 },
        { "io.vramIncrementMode", 1 }, { "io.vramMapping", 1 },
        { "io.vramIncrementSize", 1 }, { "io.vramAddress", 2 },
        { "io.cgramAddress", 1 }, { "io.cgramAddressLatch", 1 },
        { "io.hcounter", 2 }, { "io.vcounter", 2 },
        { "io.interlace", 1 }, { "io.overscan", 1 },
        { "io.pseudoHires", 1 }, { "io.extbg", 1 },
        { "io.mosaic.size", 1 }, { "io.mosaic.counter", 1 },
        { "io.mode7.hflip", 1 }, { "io.mode7.vflip", 1 },
        { "io.mode7.repeat", 4 },
        { "io.mode7.a", 2 }, { "io.mode7.b", 2 }, { "io.mode7.c", 2 },
        { "io.mode7.d", 2 }, { "io.mode7.x", 2 }, { "io.mode7.y", 2 },
        { "io.mode7.hoffset", 2 }, { "io.mode7.voffset", 2 },
        { "io.window.oneLeft", 1 }, { "io.window.oneRight", 1 },
        { "io.window.twoLeft", 1 }, { "io.window.twoRight", 1 },
        { NULL, 0 }
    };
    run_fields("ppufast", io);

    /* WindowLayer: 4 bools + uint mask + 2 bools (ppu.hpp:136-147) */
    static const struct field winlayer[] = {
        { "window.oneEnable", 1 }, { "window.oneInvert", 1 },
        { "window.twoEnable", 1 }, { "window.twoInvert", 1 },
        { "window.mask", 4 },
        { "window.aboveEnable", 1 }, { "window.belowEnable", 1 },
        { NULL, 0 }
    };
    static const struct field bg[] = {
        { "aboveEnable", 1 }, { "belowEnable", 1 }, { "mosaicEnable", 1 },
        { "tiledataAddress", 2 }, { "screenAddress", 2 },
        { "screenSize", 1 }, { "tileSize", 1 },
        { "hoffset", 2 }, { "voffset", 2 },
        { "tileMode", 1 },
        { "priority[0]", 1 }, { "priority[1]", 1 },
        { NULL, 0 }
    };
    for (int i = 1; i <= 4; i++) {
        char prefix[32];
        snprintf(prefix, sizeof(prefix), "ppufast.io.bg%d", i);
        run_fields(prefix, winlayer);
        run_fields(prefix, bg);
    }

    static const struct field obj[] = {
        { "aboveEnable", 1 }, { "belowEnable", 1 }, { "interlace", 1 },
        { "baseSize", 1 }, { "nameselect", 1 }, { "tiledataAddress", 2 },
        { "first", 1 }, { "rangeOver", 1 }, { "timeOver", 1 },
        { "priority[0]", 1 }, { "priority[1]", 1 }, { "priority[2]", 1 },
        { "priority[3]", 1 },
        { NULL, 0 }
    };
    run_fields("ppufast.io.obj", winlayer);
    run_fields("ppufast.io.obj", obj);

    /* WindowColor: 4 bools + 3 uint masks (ppu.hpp:149-160) */
    static const struct field wincolor[] = {
        { "window.oneEnable", 1 }, { "window.oneInvert", 1 },
        { "window.twoEnable", 1 }, { "window.twoInvert", 1 },
        { "window.mask", 4 }, { "window.aboveMask", 4 },
        { "window.belowMask", 4 },
        { NULL, 0 }
    };
    static const struct field col[] = {
        { "enable[0]", 1 }, { "enable[1]", 1 }, { "enable[2]", 1 },
        { "enable[3]", 1 }, { "enable[4]", 1 }, { "enable[5]", 1 },
        { "enable[6]", 1 },
        { "directColor", 1 }, { "blendMode", 1 }, { "halve", 1 },
        { "mathMode", 1 }, { "fixedColor", 2 },
        { NULL, 0 }
    };
    run_fields("ppufast.io.col", wincolor);
    run_fields("ppufast.io.col", col);

    array_field("ppufast.vram", 64 * 1024);
    array_field("ppufast.cgram", 512);

    static const struct field object[] = {
        { "x", 2 }, { "y", 1 }, { "character", 1 }, { "nameselect", 1 },
        { "vflip", 1 }, { "hflip", 1 }, { "priority", 1 }, { "palette", 1 },
        { "size", 1 },
        { NULL, 0 }
    };
    for (int i = 0; i < 128; i++) {
        char prefix[40];
        snprintf(prefix, sizeof(prefix), "ppufast.object[%d]", i);
        run_fields(prefix, object);
    }
}

/* ---- dsp block (sfc/dsp/serialization.cpp:1-28) ---- */
static void walk_dsp(void)
{
    array_field("dsp.apuram", 64 * 1024);
    /* int16 samplebuffer[8192] (sfc/dsp/dsp.hpp:22) -> 16384 bytes */
    array_field("dsp.samplebuffer", 8192 * 2);
    uint_field("dsp.clock", 8);
    /* fixed SPC_DSP::state_size buffer (SPC_DSP.h:61, serialization.cpp:16) */
    array_field("dsp.spc_dsp_blob", 640);
}

int main(int argc, char **argv)
{
    size_t sram = 0;
    int header_only = 0;
    const char *path = NULL;

    for (int a = 1; a < argc; a++) {
        if (strcmp(argv[a], "-s") == 0 && a + 1 < argc) {
            sram = (size_t)strtoul(argv[++a], NULL, 0);
        } else if (strcmp(argv[a], "-H") == 0) {
            header_only = 1;
        } else if (strcmp(argv[a], "-O") == 0) {
            g_offmode = 1;
        } else if (!path) {
            path = argv[a];
        } else {
            die("usage: bst_dump [-s sram_bytes] [-H | -O] file.bst");
        }
    }
    if (!path)
        die("usage: bst_dump [-s sram_bytes] [-H | -O] file.bst");

    FILE *f = fopen(path, "rb");
    if (!f) {
        fprintf(stderr, "bst_dump: %s: %s\n", path, strerror(errno));
        return 1;
    }
    if (fseek(f, 0, SEEK_END) != 0)
        die("seek failed");
    long fsz = ftell(f);
    if (fsz < 12 || fseek(f, 0, SEEK_SET) != 0)
        die("file too small for .bst container");
    uint8_t *file = malloc((size_t)fsz);
    if (!file)
        die("out of memory");
    if (fread(file, 1, (size_t)fsz, f) != (size_t)fsz)
        die("read failed");
    fclose(f);

    /* container (states.cpp:75-100); signature 0x5A220000 (states.cpp:1) */
    uint32_t sig = (uint32_t)file[0] | (uint32_t)file[1] << 8 |
                   (uint32_t)file[2] << 16 | (uint32_t)file[3] << 24;
    uint32_t rle_state = (uint32_t)file[4] | (uint32_t)file[5] << 8 |
                         (uint32_t)file[6] << 16 | (uint32_t)file[7] << 24;
    uint32_t rle_preview = (uint32_t)file[8] | (uint32_t)file[9] << 8 |
                           (uint32_t)file[10] << 16 | (uint32_t)file[11] << 24;
    if (sig != 0x5A220000u)
        die("bad container signature (want 0x5A220000)");
    if (12 + (uint64_t)rle_state + rle_preview != (uint64_t)fsz)
        die("container section sizes disagree with file size");
    printf("bst.rle_state_size = %u\n", rle_state);
    printf("bst.rle_preview_size = %u\n", rle_preview);

    /* RLE<1> decode (nall/decode/rle.hpp, S=1, M=4) */
    const uint8_t *in = file + 12;
    size_t in_left = rle_state;
    if (in_left < 8)
        die("rle section too small");
    uint64_t out_size = 0;
    for (int i = 0; i < 8; i++)
        out_size |= (uint64_t)in[i] << (8 * i);
    in += 8;
    in_left -= 8;
    if (out_size > (64u << 20))
        die("implausible decoded stream size");
    uint8_t *stream = malloc(out_size ? out_size : 1);
    if (!stream)
        die("out of memory");
    size_t o = 0;
    while (o < out_size) {
        if (in_left < 1)
            die("rle stream truncated (control byte)");
        uint8_t ctrl = *in++;
        in_left--;
        if (ctrl < 128) {
            unsigned n = ctrl + 1u;
            if (in_left < n)
                die("rle stream truncated (literal run)");
            while (n-- && o < out_size) {
                stream[o++] = *in++;
                in_left--;
            }
        } else {
            if (in_left < 1)
                die("rle stream truncated (repeat word)");
            uint8_t v = *in++;
            in_left--;
            unsigned n = (ctrl & 127u) + 4u;
            while (n-- && o < out_size)
                stream[o++] = v;
        }
    }
    printf("bst.stream_size = %llu\n", (unsigned long long)out_size);

    g_data = stream;
    g_size = out_size;
    g_pos = 0;

    /* stream header (serialization.cpp:1-23) — gate like unserialize
     * (serialization.cpp:25-48): signature, size, version, fastPPU. */
    uint32_t ssig = (uint32_t)uint_field("header.signature", 4);
    uint32_t ssize = (uint32_t)uint_field("header.serialize_size", 4);
    const uint8_t *ver = take(16, "header.version");
    char verstr[17];
    memcpy(verstr, ver, 16);
    verstr[16] = 0;
    printf("header.version = %s\n", verstr);
    take(512, "header.description"); /* free text, not validated */
    uint64_t synchronize = uint_field("header.synchronize", 1);
    uint64_t fastppu = uint_field("header.fastppu", 1);

    if (ssig != 0x31545342u)
        die("bad stream signature (want 0x31545342 'BST1')");
    if (ssize != out_size)
        die("header serialize_size disagrees with decoded stream size");
    if (strcmp(verstr, "115.1") != 0) {
        fprintf(stderr, "bst_dump: REFUSE: SerializerVersion %s != 115.1 "
                        "(pin)\n", verstr);
        return 2;
    }
    if (!synchronize) {
        fprintf(stderr, "bst_dump: REFUSE: synchronize=0 rewind-variant "
                        "stream (carries raw cothread stacks)\n");
        return 2;
    }
    if (!fastppu) {
        fprintf(stderr, "bst_dump: REFUSE: fastppu=0 accurate-PPU layout "
                        "(inventoried but out of pilot scope)\n");
        return 2;
    }

    if (header_only)
        return 0;

    /* serializeAll plain-cart block order (serialization.cpp:52-98) */
    static const struct field random_fields[] = {
        { "entropy", 4 }, { "state", 8 }, { "increment", 8 }, { NULL, 0 }
    };
    run_fields("random", random_fields);

    if (sram)
        array_field("cartridge.ram", sram);
    else
        printf("cartridge.ram : 0 bytes (no -s given; plain cart with no "
               "SRAM, or pass -s)\n");

    walk_cpu();
    walk_smp();
    walk_ppu_fast();
    walk_dsp();

    /* controllerPort1/2 + expansionPort serialize zero bytes
     * (controller.cpp:60-61, expansion.cpp:36-37); synchronize=1 streams
     * carry no stacks. Anything left over means coprocessor blocks. */
    if (g_pos != g_size) {
        fprintf(stderr, "bst_dump: REFUSE: %zu residual bytes after "
                        "plain-cart walk (coprocessor blocks present, or "
                        "wrong -s sram size)\n", g_size - g_pos);
        return 2;
    }

    free(stream);
    free(file);
    return 0;
}
