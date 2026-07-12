/* transmute_snes.c — Spike T2.0 cross-emulator SNES state pipeline (P2).
 *
 * The shipping formalization of the decode/encode the P1 harness prototyped
 * with mss_dump + bst_dump + the Python encoder. Standalone: reads a Mesen2
 * `.mss` capture and a power-on bsnes `.bst` donor, overwrites the donor's
 * architectural + register-file domains with the CMS values decoded from the
 * capture, and writes a rebuilt `.bst` that bsnes loads (G2) and continues
 * from — StateProbe's WAI resumes, the beacon epoch advances, and the
 * self-audit reaches the full pass bitmap 0x3F8F (G3).
 *
 * Format truth (project rule: from vendored source, never docs/memory):
 *   .mss container + zlib + keyed records : Mesen2 @ b9fa69d
 *     (SaveStateManager.cpp:60-129, Serializer.cpp/.h)
 *   .bst container + nall RLE<1>          : bsnes @ 7d5aa1e
 *     (target-bsnes/program/states.cpp, nall/encode|decode/rle.hpp)
 *   payload field layout (fastPPU=true)   : sfc/{cpu,smp,ppu-fast,dsp}/
 *     serialization.cpp + processor/{wdc65816,spc700}/serialization.cpp
 *   register-file transforms + SMP port / DMA bit crosswalks + OAM object
 *     bit-packing + SPC_DSP copy_state blob : cms/mapping_mesen2_bsnes.json
 *
 * The positional field walk here is byte-for-byte the same walk bst_dump
 * prints under -O; the record decode is the same walk mss_dump prints. This
 * tool's output is verified byte-identical to the Python oracle encoder
 * (tests/unit/transmute/test_gates_p2.sh).
 *
 * Usage: transmute_snes <capture.mss> <donor.bst> <out.bst> [sram_bytes]
 *   sram_bytes default 8192 (StateProbe battery SRAM).
 * Exit: 0 ok, 1 malformed/unreadable, 2 refused (chip firewall / non-SNES /
 *   SPC mid-instruction / pending port write), 3 internal (offset/width).
 *
 * Desktop-tier x86_64 tool; C99 + zlib. Never ships to a device.
 */

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

#define MSS_SIZE_CAP (10u * 1024u * 1024u)
#define VIDEO_ZLIB_CAP (2u * 1024u * 1024u)

static void die(const char *msg) { fprintf(stderr, "transmute_snes: %s\n", msg); exit(1); }
static void refuse(const char *msg) { fprintf(stderr, "transmute_snes: REFUSE: %s\n", msg); exit(2); }
static void internal(const char *msg) { fprintf(stderr, "transmute_snes: internal: %s\n", msg); exit(3); }

static uint32_t rd_u32le(const uint8_t *p) {
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}
static uint8_t *slurp(const char *path, size_t *n) {
    FILE *f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "transmute_snes: %s: %s\n", path, strerror(errno)); exit(1); }
    fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
    if (sz < 0) die("ftell");
    uint8_t *b = malloc((size_t)sz ? (size_t)sz : 1);
    if (!b) die("oom");
    if (fread(b, 1, (size_t)sz, f) != (size_t)sz) die("read");
    fclose(f); *n = (size_t)sz; return b;
}

/* ===================== .mss keyed-record decode ===================== */
struct rec { const char *key; const uint8_t *val; uint32_t len; };
static struct rec *g_recs; static size_t g_nrec;
static uint8_t *g_mss_payload;

static void mss_load(const char *path) {
    size_t n; uint8_t *f = slurp(path, &n); size_t i = 0;
    if (n < 3 || memcmp(f, "MSS", 3)) die("bad .mss magic");
    i = 3;
    if (i + 20 > n) die("truncated .mss header");
    /* emu_version(4) format_version(4) console_type(4) */
    uint32_t fmt = rd_u32le(f + i + 4), console = rd_u32le(f + i + 8);
    i += 12;
    if (fmt < 3) die(".mss format_version < 3");
    if (console != 0) refuse("console_type != SNES(0)");
    /* video block: size(4) w(4) h(4) scale(4) zlib(4) [zlib bytes] */
    if (i + 20 > n) die("truncated video header");
    uint32_t fb_zlib = rd_u32le(f + i + 16); i += 20;
    if (fb_zlib >= VIDEO_ZLIB_CAP) die("video block too large");
    if (i + fb_zlib > n) die("truncated video data");
    i += fb_zlib;
    /* rom name */
    if (i + 4 > n) die("truncated rom name len");
    uint32_t nl = rd_u32le(f + i); i += 4;
    if (nl >= 4096 || i + nl > n) die("bad rom name");
    i += nl;
    /* payload framing */
    if (i >= n) die("truncated at payload flag");
    int comp = f[i++];
    uint8_t *payload; size_t psize;
    if (comp == 1) {
        if (i + 8 > n) die("truncated payload sizes");
        uint32_t raw = rd_u32le(f + i), zl = rd_u32le(f + i + 4); i += 8;
        if (raw >= MSS_SIZE_CAP || zl >= MSS_SIZE_CAP) die("payload too large");
        if (i + zl > n) die("truncated payload zlib");
        payload = malloc(raw ? raw : 1); if (!payload) die("oom");
        uLongf dst = raw;
        if (uncompress(payload, &dst, f + i, zl) != Z_OK || dst != raw) die("payload inflate failed");
        psize = raw;
    } else {
        psize = n - i;
        if (psize >= MSS_SIZE_CAP) die("payload too large");
        payload = malloc(psize ? psize : 1); if (!payload) die("oom");
        memcpy(payload, f + i, psize);
    }
    free(f);
    g_mss_payload = payload;
    /* build the record map: [key\0][u32 len][val] */
    static const char *refuse_pfx[] = { "cart.coprocessor.", "cart.bsxMemPack.",
        "cart.gameboy.", "msu1.", NULL };
    size_t cap = 2048; g_recs = malloc(cap * sizeof *g_recs); if (!g_recs) die("oom");
    g_nrec = 0; size_t p = 0;
    while (p < psize) {
        size_t ks = p;
        while (p < psize && payload[p]) { if (payload[p] <= ' ' || payload[p] >= 127) die("bad record key char"); p++; }
        if (p >= psize) die("unterminated record key");
        size_t klen = p - ks; if (!klen) die("empty record key");
        payload[p] = 0; const char *key = (const char *)(payload + ks); p++;
        if (p + 4 > psize) die("truncated record size");
        uint32_t vlen = rd_u32le(payload + p); p += 4;
        if (p + vlen > psize) die("record value overruns payload");
        for (const char **q = refuse_pfx; *q; q++)
            if (!strncmp(key, *q, strlen(*q))) refuse("coprocessor/enhancement keys present (chip firewall)");
        if (g_nrec == cap) { cap *= 2; g_recs = realloc(g_recs, cap * sizeof *g_recs); if (!g_recs) die("oom"); }
        g_recs[g_nrec].key = key; g_recs[g_nrec].val = payload + p; g_recs[g_nrec].len = vlen;
        g_nrec++; p += vlen;
    }
}

static const struct rec *mss_find(const char *key) {
    for (size_t i = 0; i < g_nrec; i++) if (!strcmp(g_recs[i].key, key)) return &g_recs[i];
    return NULL;
}
static uint64_t mss_u(const char *key) {
    const struct rec *r = mss_find(key);
    if (!r) { fprintf(stderr, "transmute_snes: missing record %s\n", key); exit(3); }
    if (r->len > 8) internal("scalar record too wide");
    uint64_t v = 0; for (uint32_t b = 0; b < r->len; b++) v |= (uint64_t)r->val[b] << (8 * b);
    return v;
}
static const uint8_t *mss_arr(const char *key, uint32_t want) {
    const struct rec *r = mss_find(key);
    if (!r) { fprintf(stderr, "transmute_snes: missing record %s\n", key); exit(3); }
    if (want && r->len != want) { fprintf(stderr, "transmute_snes: %s is %u bytes, want %u\n", key, r->len, want); exit(3); }
    return r->val;
}

/* ===================== .bst container + RLE<1> ===================== */
static const uint32_t BST_SIG = 0x5a220000u;
static uint8_t *rle_decode(const uint8_t *in, size_t n, size_t *outlen) {
    if (n < 8) die("rle too small");
    uint64_t size = 0; for (int i = 0; i < 8; i++) size |= (uint64_t)in[i] << (8 * i);
    if (size > (64u << 20)) die("implausible stream size");
    uint8_t *out = malloc(size ? size : 1); if (!out) die("oom");
    size_t ip = 8, o = 0;
    while (o < size) {
        if (ip >= n) die("rle truncated");
        uint8_t c = in[ip++];
        if (c < 128) { unsigned k = c + 1u; while (k-- && o < size) { if (ip >= n) die("rle lit trunc"); out[o++] = in[ip++]; } }
        else { if (ip >= n) die("rle rep trunc"); uint8_t v = in[ip++]; unsigned k = (c & 127u) + 4u; while (k-- && o < size) out[o++] = v; }
    }
    *outlen = size; return out;
}
static uint8_t *rle_encode(const uint8_t *in, size_t n, size_t *outlen) {
    /* transcribed from nall/encode/rle.hpp (S=1,M=4) — matches bsnes_host.cpp */
    size_t cap = n + n / 2 + 64; uint8_t *out = malloc(cap); if (!out) die("oom");
    size_t o = 0;
    for (int byte = 0; byte < 8; byte++) out[o++] = (uint8_t)(n >> (byte * 8));
    size_t base = 0, skip = 0;
    #define ENS(extra) do { if (o + (extra) > cap) { cap = (o + (extra)) * 2; out = realloc(out, cap); if (!out) die("oom"); } } while (0)
    while (base + skip < n) {
        size_t same = 1;
        for (size_t off = base + skip + 1; off < n; off++) { if (in[off] != in[base + skip]) break; if (++same == 127 + 4) break; }
        if (same < 4) {
            if (++skip == 128) { ENS(1 + skip); out[o++] = (uint8_t)(skip - 1); do { out[o++] = in[base++]; } while (--skip); }
        } else {
            if (skip) { ENS(1 + skip); out[o++] = (uint8_t)(skip - 1); do { out[o++] = in[base++]; } while (--skip); }
            ENS(2); out[o++] = (uint8_t)(128 | (same - 4)); out[o++] = in[base]; base += same;
        }
    }
    if (skip) { ENS(1 + skip); out[o++] = (uint8_t)(skip - 1); do { out[o++] = in[base++]; } while (--skip); }
    #undef ENS
    *outlen = o; return out;
}

/* ===================== bsnes payload offset map =====================
 * A positional walk identical to bst_dump's, recording (name,off,len) so a
 * transform can address any field by name. Naming matches bst_dump -O exactly.
 */
struct field { char name[64]; size_t off, len; };
static struct field *g_fields; static size_t g_nfield, g_fcap;
static const uint8_t *g_pay; static size_t g_paysize, g_pos;

static void rec_field(const char *name, size_t len) {
    if (g_pos + len > g_paysize) internal("offset walk overran donor payload");
    if (g_nfield == g_fcap) { g_fcap = g_fcap ? g_fcap * 2 : 4096; g_fields = realloc(g_fields, g_fcap * sizeof *g_fields); if (!g_fields) die("oom"); }
    struct field *f = &g_fields[g_nfield++];
    if (strlen(name) >= sizeof f->name) internal("field name too long");
    strcpy(f->name, name); f->off = g_pos; f->len = len; g_pos += len;
}
static void rec_pfx(const char *pfx, const char *sub, unsigned len) {
    char nm[64]; snprintf(nm, sizeof nm, "%s.%s", pfx, sub); rec_field(nm, len);
}
struct sf { const char *name; unsigned bytes; };
static void rec_run(const char *pfx, const struct sf *t) { for (; t->name; t++) rec_pfx(pfx, t->name, t->bytes); }

static const struct sf thread_f[] = { {"thread.frequency",4},{"thread.clock",8},{NULL,0} };
static const struct sf ppucounter_f[] = {
    {"counter.time.interlace",1},{"counter.time.field",1},{"counter.time.vperiod",4},{"counter.time.hperiod",4},
    {"counter.time.vcounter",4},{"counter.time.hcounter",4},{"counter.last.vperiod",4},{"counter.last.hperiod",4},{NULL,0} };

static void walk_offsets(size_t sram) {
    /* header (serialization.cpp:1-23) */
    rec_field("header.signature", 4); rec_field("header.serialize_size", 4);
    rec_field("header.version", 16); rec_field("header.description", 512);
    rec_field("header.synchronize", 1); rec_field("header.fastppu", 1);
    /* random */
    rec_field("random.entropy", 4); rec_field("random.state", 8); rec_field("random.increment", 8);
    if (sram) rec_field("cartridge.ram", sram);
    /* cpu */
    static const struct sf wdc[] = {
        {"wdc.pc",4},{"wdc.a",2},{"wdc.x",2},{"wdc.y",2},{"wdc.z",2},{"wdc.s",2},{"wdc.d",2},{"wdc.b",1},
        {"wdc.p.c",1},{"wdc.p.z",1},{"wdc.p.i",1},{"wdc.p.d",1},{"wdc.p.x",1},{"wdc.p.m",1},{"wdc.p.v",1},{"wdc.p.n",1},
        {"wdc.e",1},{"wdc.irq",1},{"wdc.wai",1},{"wdc.stp",1},{"wdc.vector",2},{"wdc.mar",4},{"wdc.mdr",1},
        {"wdc.u",4},{"wdc.v",4},{"wdc.w",4},{NULL,0} };
    rec_run("cpu", wdc); rec_run("cpu", thread_f); rec_run("cpu", ppucounter_f);
    rec_field("cpu.wram", 128 * 1024);
    static const struct sf ctail[] = {
        {"version",4},{"counter.cpu",4},{"counter.dma",4},{"status.clockCount",4},{"status.irqLock",1},
        {"status.dramRefreshPosition",4},{"status.dramRefresh",4},{"status.hdmaSetupPosition",4},{"status.hdmaSetupTriggered",1},
        {"status.hdmaPosition",4},{"status.hdmaTriggered",1},{"status.nmiValid",1},{"status.nmiLine",1},{"status.nmiTransition",1},
        {"status.nmiPending",1},{"status.nmiHold",1},{"status.irqValid",1},{"status.irqLine",1},{"status.irqTransition",1},
        {"status.irqPending",1},{"status.irqHold",1},{"status.resetPending",1},{"status.interruptPending",1},{"status.dmaActive",1},
        {"status.dmaPending",1},{"status.hdmaPending",1},{"status.hdmaMode",1},{"status.autoJoypadCounter",4},
        {"status.autoJoypadPort1",1},{"status.autoJoypadPort2",1},{"status.cpuLatch",1},{"status.autoJoypadLatch",1},
        {"io.wramAddress",4},{"io.hirqEnable",1},{"io.virqEnable",1},{"io.irqEnable",1},{"io.nmiEnable",1},{"io.autoJoypadPoll",1},
        {"io.pio",1},{"io.wrmpya",1},{"io.wrmpyb",1},{"io.wrdiva",2},{"io.wrdivb",1},{"io.htime",2},{"io.vtime",2},{"io.fastROM",1},
        {"io.rddiv",2},{"io.rdmpy",2},{"io.joy1",2},{"io.joy2",2},{"io.joy3",2},{"io.joy4",2},
        {"alu.mpyctr",4},{"alu.divctr",4},{"alu.shift",4},{NULL,0} };
    rec_run("cpu", ctail);
    static const struct sf chan[] = {
        {"dmaEnable",1},{"hdmaEnable",1},{"direction",1},{"indirect",1},{"unused",1},{"reverseTransfer",1},{"fixedTransfer",1},
        {"transferMode",1},{"targetAddress",1},{"sourceAddress",2},{"sourceBank",1},{"transferSize",2},{"indirectBank",1},
        {"hdmaAddress",2},{"lineCounter",1},{"unknown",1},{"hdmaCompleted",1},{"hdmaDoTransfer",1},{NULL,0} };
    for (int i = 0; i < 8; i++) { char p[32]; snprintf(p, sizeof p, "cpu.channel[%d]", i); rec_run(p, chan); }
    /* smp */
    static const struct sf spc700[] = {
        {"spc700.pc",2},{"spc700.ya",2},{"spc700.x",1},{"spc700.s",1},
        {"spc700.p.c",1},{"spc700.p.z",1},{"spc700.p.i",1},{"spc700.p.h",1},{"spc700.p.b",1},{"spc700.p.p",1},{"spc700.p.v",1},{"spc700.p.n",1},
        {"spc700.wait",1},{"spc700.stop",1},{NULL,0} };
    rec_run("smp", spc700); rec_run("smp", thread_f);
    static const struct sf smpio[] = {
        {"io.clockCounter",4},{"io.dspCounter",4},{"io.apu0",1},{"io.apu1",1},{"io.apu2",1},{"io.apu3",1},
        {"io.timersDisable",1},{"io.ramWritable",1},{"io.ramDisable",1},{"io.timersEnable",1},{"io.externalWaitStates",1},
        {"io.internalWaitStates",1},{"io.iplromEnable",1},{"io.dspAddr",1},{"io.cpu0",1},{"io.cpu1",1},{"io.cpu2",1},{"io.cpu3",1},
        {"io.aux4",1},{"io.aux5",1},{NULL,0} };
    rec_run("smp", smpio);
    static const struct sf timer[] = { {"stage0",1},{"stage1",1},{"stage2",1},{"stage3",1},{"line",1},{"enable",1},{"target",1},{NULL,0} };
    for (int i = 0; i < 3; i++) { char p[32]; snprintf(p, sizeof p, "smp.timer%d", i); rec_run(p, timer); }
    /* ppu fast */
    static const struct sf disp[] = { {"display.interlace",1},{"display.overscan",1},{"display.vdisp",4},{NULL,0} };
    rec_run("ppu", disp); rec_run("ppufast", thread_f); rec_run("ppufast", ppucounter_f);
    static const struct sf latch[] = {
        {"latch.interlace",1},{"latch.overscan",1},{"latch.hires",1},{"latch.hd",1},{"latch.ss",1},{"latch.vram",2},
        {"latch.oam",1},{"latch.cgram",1},{"latch.oamAddress",2},{"latch.cgramAddress",1},{"latch.mode7",1},{"latch.counters",1},
        {"latch.hcounter",1},{"latch.vcounter",1},{"latch.ppu1.mdr",1},{"latch.ppu1.bgofs",1},{"latch.ppu2.mdr",1},{"latch.ppu2.bgofs",1},{NULL,0} };
    rec_run("ppufast", latch);
    static const struct sf ppuio[] = {
        {"io.displayDisable",1},{"io.displayBrightness",1},{"io.oamBaseAddress",2},{"io.oamAddress",2},{"io.oamPriority",1},
        {"io.bgPriority",1},{"io.bgMode",1},{"io.vramIncrementMode",1},{"io.vramMapping",1},{"io.vramIncrementSize",1},{"io.vramAddress",2},
        {"io.cgramAddress",1},{"io.cgramAddressLatch",1},{"io.hcounter",2},{"io.vcounter",2},{"io.interlace",1},{"io.overscan",1},
        {"io.pseudoHires",1},{"io.extbg",1},{"io.mosaic.size",1},{"io.mosaic.counter",1},{"io.mode7.hflip",1},{"io.mode7.vflip",1},
        {"io.mode7.repeat",4},{"io.mode7.a",2},{"io.mode7.b",2},{"io.mode7.c",2},{"io.mode7.d",2},{"io.mode7.x",2},{"io.mode7.y",2},
        {"io.mode7.hoffset",2},{"io.mode7.voffset",2},{"io.window.oneLeft",1},{"io.window.oneRight",1},{"io.window.twoLeft",1},{"io.window.twoRight",1},{NULL,0} };
    rec_run("ppufast", ppuio);
    static const struct sf winlayer[] = {
        {"window.oneEnable",1},{"window.oneInvert",1},{"window.twoEnable",1},{"window.twoInvert",1},{"window.mask",4},
        {"window.aboveEnable",1},{"window.belowEnable",1},{NULL,0} };
    static const struct sf bg[] = {
        {"aboveEnable",1},{"belowEnable",1},{"mosaicEnable",1},{"tiledataAddress",2},{"screenAddress",2},{"screenSize",1},
        {"tileSize",1},{"hoffset",2},{"voffset",2},{"tileMode",1},{"priority[0]",1},{"priority[1]",1},{NULL,0} };
    for (int i = 1; i <= 4; i++) { char p[32]; snprintf(p, sizeof p, "ppufast.io.bg%d", i); rec_run(p, winlayer); rec_run(p, bg); }
    static const struct sf obj[] = {
        {"aboveEnable",1},{"belowEnable",1},{"interlace",1},{"baseSize",1},{"nameselect",1},{"tiledataAddress",2},{"first",1},
        {"rangeOver",1},{"timeOver",1},{"priority[0]",1},{"priority[1]",1},{"priority[2]",1},{"priority[3]",1},{NULL,0} };
    rec_run("ppufast.io.obj", winlayer); rec_run("ppufast.io.obj", obj);
    static const struct sf wincolor[] = {
        {"window.oneEnable",1},{"window.oneInvert",1},{"window.twoEnable",1},{"window.twoInvert",1},{"window.mask",4},
        {"window.aboveMask",4},{"window.belowMask",4},{NULL,0} };
    static const struct sf col[] = {
        {"enable[0]",1},{"enable[1]",1},{"enable[2]",1},{"enable[3]",1},{"enable[4]",1},{"enable[5]",1},{"enable[6]",1},
        {"directColor",1},{"blendMode",1},{"halve",1},{"mathMode",1},{"fixedColor",2},{NULL,0} };
    rec_run("ppufast.io.col", wincolor); rec_run("ppufast.io.col", col);
    rec_field("ppufast.vram", 64 * 1024); rec_field("ppufast.cgram", 512);
    static const struct sf object[] = {
        {"x",2},{"y",1},{"character",1},{"nameselect",1},{"vflip",1},{"hflip",1},{"priority",1},{"palette",1},{"size",1},{NULL,0} };
    for (int i = 0; i < 128; i++) { char p[40]; snprintf(p, sizeof p, "ppufast.object[%d]", i); rec_run(p, object); }
    /* dsp */
    rec_field("dsp.apuram", 64 * 1024); rec_field("dsp.samplebuffer", 8192 * 2);
    rec_field("dsp.clock", 8); rec_field("dsp.spc_dsp_blob", 640);
}

static uint8_t *g_out; /* mutable payload we overwrite */
static struct field *fld(const char *name) {
    for (size_t i = 0; i < g_nfield; i++) if (!strcmp(g_fields[i].name, name)) return &g_fields[i];
    fprintf(stderr, "transmute_snes: offset map missing %s\n", name); exit(3);
}
static void put(const char *name, uint64_t val) {
    struct field *f = fld(name);
    for (size_t b = 0; b < f->len; b++) g_out[f->off + b] = (uint8_t)(val >> (8 * b));
}
static void putb(const char *name, const uint8_t *data, size_t len) {
    struct field *f = fld(name);
    if (f->len != len) { fprintf(stderr, "transmute_snes: %s len %zu != %zu\n", name, f->len, len); exit(3); }
    memcpy(g_out + f->off, data, len);
}

/* ===================== transforms (mirror encode_bsnes.py) ===================== */
static void xf_cpu(void) {
    put("cpu.wdc.pc", (mss_u("cpu.k") << 16) | mss_u("cpu.pc"));
    put("cpu.wdc.a", mss_u("cpu.a")); put("cpu.wdc.x", mss_u("cpu.x")); put("cpu.wdc.y", mss_u("cpu.y"));
    put("cpu.wdc.s", mss_u("cpu.sp")); put("cpu.wdc.d", mss_u("cpu.d")); put("cpu.wdc.b", mss_u("cpu.dbr"));
    uint64_t ps = mss_u("cpu.ps");
    const char *pf[8] = {"c","z","i","d","x","m","v","n"};
    for (int i = 0; i < 8; i++) { char nm[24]; snprintf(nm, sizeof nm, "cpu.wdc.p.%s", pf[i]); put(nm, (ps >> i) & 1); }
    put("cpu.wdc.e", mss_u("cpu.emulationMode")); put("cpu.wdc.mdr", mss_u("memoryManager.openBus"));
    uint64_t stop = mss_u("cpu.stopState");
    put("cpu.wdc.wai", stop == 2 ? 1 : 0); put("cpu.wdc.stp", stop == 1 ? 1 : 0);
}
static void xf_cpu_io(void) {
    put("cpu.counter.time.vcounter", mss_u("ppu.scanline"));
    put("cpu.counter.time.hcounter", mss_u("memoryManager.hClock"));
    put("cpu.counter.time.field", mss_u("ppu.oddFrame"));
    put("cpu.io.nmiEnable", mss_u("internalRegisters.enableNmi"));
    put("cpu.io.hirqEnable", mss_u("internalRegisters.enableHorizontalIrq"));
    put("cpu.io.virqEnable", mss_u("internalRegisters.enableVerticalIrq"));
    put("cpu.io.irqEnable", 0);
    put("cpu.io.autoJoypadPoll", mss_u("internalRegisters.enableAutoJoypadRead"));
    put("cpu.status.autoJoypadCounter", 33);
    put("cpu.io.htime", ((mss_u("internalRegisters.horizontalTimer") + 1) << 2) & 0xFFFF);
    put("cpu.io.vtime", mss_u("internalRegisters.verticalTimer"));
    put("cpu.io.fastROM", mss_u("internalRegisters.enableFastRom"));
    put("cpu.io.pio", mss_u("internalRegisters.ioPortOutput"));
    put("cpu.io.wrmpya", mss_u("internalRegisters.aluMulDiv.multOperand1"));
    put("cpu.io.wrmpyb", mss_u("internalRegisters.aluMulDiv.multOperand2"));
    put("cpu.io.wrdiva", mss_u("internalRegisters.aluMulDiv.dividend"));
    put("cpu.io.wrdivb", mss_u("internalRegisters.aluMulDiv.divisor"));
    put("cpu.io.rddiv", mss_u("internalRegisters.aluMulDiv.divResult"));
    put("cpu.io.rdmpy", mss_u("internalRegisters.aluMulDiv.multOrRemainderResult"));
    for (int i = 0; i < 4; i++) { char s[40], d[24]; snprintf(s, sizeof s, "internalRegisters.controllerData[%d]", i); snprintf(d, sizeof d, "cpu.io.joy%d", i + 1); put(d, mss_u(s)); }
    put("cpu.io.wramAddress", mss_u("memoryManager.registerHandlerB.wramPosition") & 0x1FFFF);
}
static const int TILEMODE[8][4] = {
    {0,0,0,0},{1,1,0,4},{1,1,4,4},{2,1,4,4},{2,0,4,4},{1,1,4,4},{1,4,4,4},{3,4,4,4} };
static void xf_ppu(void) {
    put("ppu.display.interlace", mss_u("ppu.screenInterlace"));
    put("ppu.display.overscan", mss_u("ppu.overscanMode"));
    put("ppu.display.vdisp", mss_u("ppu.overscanMode") ? 240 : 225);
    put("ppufast.latch.vram", mss_u("ppu.vramReadBuffer"));
    put("ppufast.latch.oam", mss_u("ppu.oamWriteBuffer"));
    put("ppufast.latch.cgram", mss_u("ppu.cgramWriteBuffer"));
    put("ppufast.latch.oamAddress", mss_u("ppu.internalOamAddress"));
    put("ppufast.latch.cgramAddress", mss_u("ppu.internalCgramAddress"));
    put("ppufast.latch.mode7", mss_u("ppu.mode7.valueLatch"));
    put("ppufast.latch.counters", mss_u("ppu.locationLatched"));
    put("ppufast.latch.hcounter", mss_u("ppu.horizontalLocToggle"));
    put("ppufast.latch.vcounter", mss_u("ppu.verticalLocationToggle"));
    put("ppufast.latch.ppu1.mdr", mss_u("ppu.ppu1OpenBus"));
    put("ppufast.latch.ppu1.bgofs", mss_u("ppu.hvScrollLatchValue"));
    put("ppufast.latch.ppu2.mdr", mss_u("ppu.ppu2OpenBus"));
    put("ppufast.latch.ppu2.bgofs", mss_u("ppu.hScrollLatchValue"));
    put("ppufast.io.displayDisable", mss_u("ppu.forcedBlank"));
    put("ppufast.io.displayBrightness", mss_u("ppu.screenBrightness"));
    put("ppufast.io.oamBaseAddress", mss_u("ppu.oamRamAddress") << 1);
    put("ppufast.io.oamAddress", mss_u("ppu.internalOamAddress"));
    put("ppufast.io.oamPriority", mss_u("ppu.enableOamPriority"));
    put("ppufast.io.bgPriority", mss_u("ppu.mode1Bg3Priority"));
    put("ppufast.io.bgMode", mss_u("ppu.bgMode"));
    put("ppufast.io.vramIncrementMode", mss_u("ppu.vramAddrIncrementOnSecondReg"));
    put("ppufast.io.vramMapping", mss_u("ppu.vramAddressRemapping"));
    put("ppufast.io.vramIncrementSize", mss_u("ppu.vramIncrementValue"));
    put("ppufast.io.vramAddress", mss_u("ppu.vramAddress"));
    put("ppufast.io.cgramAddress", mss_u("ppu.cgramAddress"));
    put("ppufast.io.cgramAddressLatch", mss_u("ppu.cgramAddressLatch"));
    put("ppufast.io.hcounter", mss_u("ppu.horizontalLocation"));
    put("ppufast.io.vcounter", mss_u("ppu.verticalLocation"));
    put("ppufast.io.interlace", mss_u("ppu.screenInterlace"));
    put("ppufast.io.overscan", mss_u("ppu.overscanMode"));
    put("ppufast.io.pseudoHires", mss_u("ppu.hiResMode"));
    put("ppufast.io.extbg", mss_u("ppu.extBgEnabled"));
    put("ppufast.io.mosaic.size", mss_u("ppu.mosaicSize"));
    put("ppufast.io.mosaic.counter", 0);
    put("ppufast.io.mode7.hflip", mss_u("ppu.mode7.horizontalMirroring"));
    put("ppufast.io.mode7.vflip", mss_u("ppu.mode7.verticalMirroring"));
    put("ppufast.io.mode7.repeat", (mss_u("ppu.mode7.largeMap") << 1) | mss_u("ppu.mode7.fillWithTile0"));
    put("ppufast.io.mode7.a", mss_u("ppu.mode7.matrix[0]"));
    put("ppufast.io.mode7.b", mss_u("ppu.mode7.matrix[1]"));
    put("ppufast.io.mode7.c", mss_u("ppu.mode7.matrix[2]"));
    put("ppufast.io.mode7.d", mss_u("ppu.mode7.matrix[3]"));
    put("ppufast.io.mode7.x", mss_u("ppu.mode7.centerX"));
    put("ppufast.io.mode7.y", mss_u("ppu.mode7.centerY"));
    put("ppufast.io.mode7.hoffset", mss_u("ppu.mode7.hscroll"));
    put("ppufast.io.mode7.voffset", mss_u("ppu.mode7.vscroll"));
    put("ppufast.io.window.oneLeft", mss_u("ppu.window[0].left"));
    put("ppufast.io.window.oneRight", mss_u("ppu.window[0].right"));
    put("ppufast.io.window.twoLeft", mss_u("ppu.window[1].left"));
    put("ppufast.io.window.twoRight", mss_u("ppu.window[1].right"));
    uint64_t bgmode = mss_u("ppu.bgMode"), main = mss_u("ppu.mainScreenLayers");
    uint64_t sub = mss_u("ppu.subScreenLayers"), mos = mss_u("ppu.mosaicEnabled");
    const char *bgn[4] = {"bg1","bg2","bg3","bg4"};
    for (int i = 0; i < 4; i++) {
        char p[32]; snprintf(p, sizeof p, "ppufast.io.%s", bgn[i]);
        char nm[64], k[64];
        #define PB(sub_, key_) do { snprintf(nm, sizeof nm, "%s.%s", p, sub_); snprintf(k, sizeof k, key_, i); put(nm, mss_u(k)); } while (0)
        PB("window.oneEnable", "ppu.window[0].activeLayers[%d]");
        PB("window.oneInvert", "ppu.window[0].invertedLayers[%d]");
        PB("window.twoEnable", "ppu.window[1].activeLayers[%d]");
        PB("window.twoInvert", "ppu.window[1].invertedLayers[%d]");
        PB("window.mask", "ppu.maskLogic[%d]");
        PB("window.aboveEnable", "ppu.windowMaskMain[%d]");
        PB("window.belowEnable", "ppu.windowMaskSub[%d]");
        #undef PB
        char nm2[64];
        snprintf(nm2, sizeof nm2, "%s.aboveEnable", p); put(nm2, (main >> i) & 1);
        snprintf(nm2, sizeof nm2, "%s.belowEnable", p); put(nm2, (sub >> i) & 1);
        snprintf(nm2, sizeof nm2, "%s.mosaicEnable", p); put(nm2, (mos >> i) & 1);
        char k2[48];
        snprintf(nm2, sizeof nm2, "%s.tiledataAddress", p); snprintf(k2, sizeof k2, "ppu.layers[%d].chrAddress", i); put(nm2, mss_u(k2));
        snprintf(nm2, sizeof nm2, "%s.screenAddress", p); snprintf(k2, sizeof k2, "ppu.layers[%d].tilemapAddress", i); put(nm2, mss_u(k2));
        char kw[48], kh[48]; snprintf(kw, sizeof kw, "ppu.layers[%d].doubleWidth", i); snprintf(kh, sizeof kh, "ppu.layers[%d].doubleHeight", i);
        snprintf(nm2, sizeof nm2, "%s.screenSize", p); put(nm2, mss_u(kw) | (mss_u(kh) << 1));
        snprintf(nm2, sizeof nm2, "%s.tileSize", p); snprintf(k2, sizeof k2, "ppu.layers[%d].largeTiles", i); put(nm2, mss_u(k2));
        snprintf(nm2, sizeof nm2, "%s.hoffset", p); snprintf(k2, sizeof k2, "ppu.layers[%d].hscroll", i); put(nm2, mss_u(k2));
        snprintf(nm2, sizeof nm2, "%s.voffset", p); snprintf(k2, sizeof k2, "ppu.layers[%d].vscroll", i); put(nm2, mss_u(k2));
        snprintf(nm2, sizeof nm2, "%s.tileMode", p); put(nm2, TILEMODE[bgmode & 7][i]);
    }
    put("ppufast.io.obj.window.oneEnable", mss_u("ppu.window[0].activeLayers[4]"));
    put("ppufast.io.obj.window.oneInvert", mss_u("ppu.window[0].invertedLayers[4]"));
    put("ppufast.io.obj.window.twoEnable", mss_u("ppu.window[1].activeLayers[4]"));
    put("ppufast.io.obj.window.twoInvert", mss_u("ppu.window[1].invertedLayers[4]"));
    put("ppufast.io.obj.window.mask", mss_u("ppu.maskLogic[4]"));
    put("ppufast.io.obj.window.aboveEnable", mss_u("ppu.windowMaskMain[4]"));
    put("ppufast.io.obj.window.belowEnable", mss_u("ppu.windowMaskSub[4]"));
    put("ppufast.io.obj.aboveEnable", (main >> 4) & 1);
    put("ppufast.io.obj.belowEnable", (sub >> 4) & 1);
    put("ppufast.io.obj.interlace", mss_u("ppu.objInterlace"));
    put("ppufast.io.obj.baseSize", mss_u("ppu.oamMode"));
    uint64_t offw = mss_u("ppu.oamAddressOffset");
    put("ppufast.io.obj.nameselect", offw ? (offw >> 12) - 1 : 0);
    put("ppufast.io.obj.tiledataAddress", mss_u("ppu.oamBaseAddress"));
    put("ppufast.io.obj.rangeOver", mss_u("ppu.rangeOver"));
    put("ppufast.io.obj.timeOver", mss_u("ppu.timeOver"));
    put("ppufast.io.col.window.oneEnable", mss_u("ppu.window[0].activeLayers[5]"));
    put("ppufast.io.col.window.oneInvert", mss_u("ppu.window[0].invertedLayers[5]"));
    put("ppufast.io.col.window.twoEnable", mss_u("ppu.window[1].activeLayers[5]"));
    put("ppufast.io.col.window.twoInvert", mss_u("ppu.window[1].invertedLayers[5]"));
    put("ppufast.io.col.window.mask", mss_u("ppu.maskLogic[5]"));
    put("ppufast.io.col.window.aboveMask", mss_u("ppu.colorMathClipMode"));
    put("ppufast.io.col.window.belowMask", mss_u("ppu.colorMathPreventMode"));
    uint64_t cme = mss_u("ppu.colorMathEnabled");
    int bit[7] = {0,1,2,3,-1,4,5};
    for (int i = 0; i < 7; i++) { char nm[32]; snprintf(nm, sizeof nm, "ppufast.io.col.enable[%d]", i); put(nm, bit[i] < 0 ? 0 : (cme >> bit[i]) & 1); }
    put("ppufast.io.col.directColor", mss_u("ppu.directColorMode"));
    put("ppufast.io.col.blendMode", mss_u("ppu.colorMathAddSubscreen"));
    put("ppufast.io.col.halve", mss_u("ppu.colorMathHalveResult"));
    put("ppufast.io.col.mathMode", mss_u("ppu.colorMathSubtractMode"));
    put("ppufast.io.col.fixedColor", mss_u("ppu.fixedColor"));
}
static void xf_oam(void) {
    const uint8_t *oam = mss_arr("ppu.oamRam", 544);
    for (int n = 0; n < 128; n++) {
        const uint8_t *lo = oam + n * 4;
        uint8_t hbyte = oam[512 + (n >> 2)]; int shift = (n & 3) * 2;
        int x9 = (hbyte >> shift) & 1, size = (hbyte >> (shift + 1)) & 1;
        char p[40]; snprintf(p, sizeof p, "ppufast.object[%d]", n);
        char nm[56];
        snprintf(nm, sizeof nm, "%s.x", p); put(nm, lo[0] | (x9 << 8));
        snprintf(nm, sizeof nm, "%s.y", p); put(nm, (lo[1] + 1) & 0xFF);
        snprintf(nm, sizeof nm, "%s.character", p); put(nm, lo[2]);
        snprintf(nm, sizeof nm, "%s.nameselect", p); put(nm, lo[3] & 1);
        snprintf(nm, sizeof nm, "%s.palette", p); put(nm, (lo[3] >> 1) & 7);
        snprintf(nm, sizeof nm, "%s.priority", p); put(nm, (lo[3] >> 4) & 3);
        snprintf(nm, sizeof nm, "%s.hflip", p); put(nm, (lo[3] >> 6) & 1);
        snprintf(nm, sizeof nm, "%s.vflip", p); put(nm, (lo[3] >> 7) & 1);
        snprintf(nm, sizeof nm, "%s.size", p); put(nm, size);
    }
}
static void xf_smp(void) {
    /* Quiescent SPC decode rules (mapping refuse_rules): the CMS drops the
     * SPC700 sub-instruction state, so a mid-instruction / pending-port-write
     * capture cannot be reconstructed byte-faithfully. */
    if (mss_u("spc.opStep") != 0) refuse("spc.opStep not at instruction start");
    if (mss_u("spc.pendingCpuRegUpdate")) refuse("spc.pendingCpuRegUpdate set (staged port write in flight)");
    put("smp.spc700.pc", mss_u("spc.pc"));
    put("smp.spc700.ya", (mss_u("spc.y") << 8) | mss_u("spc.a"));
    put("smp.spc700.x", mss_u("spc.x")); put("smp.spc700.s", mss_u("spc.sp"));
    uint64_t psw = mss_u("spc.ps");
    const char *pf[8] = {"c","z","i","h","b","p","v","n"};
    for (int i = 0; i < 8; i++) { char nm[24]; snprintf(nm, sizeof nm, "smp.spc700.p.%s", pf[i]); put(nm, (psw >> i) & 1); }
    put("smp.spc700.wait", 0); put("smp.spc700.stop", 0);
    /* Mailbox port crosswalk (names lie, bits don't): bsnes io.apu*=CPU->SMP,
     * io.cpu*=SMP->CPU (sfc/smp/io.cpp). Mesen cpuRegs=CPU->SMP, outputReg=
     * SMP->CPU. So apu<-cpuRegs, cpu<-outputReg. */
    for (int i = 0; i < 4; i++) {
        char a[16], c[16], sc[24], so[24];
        snprintf(a, sizeof a, "smp.io.apu%d", i); snprintf(sc, sizeof sc, "spc.cpuRegs[%d]", i); put(a, mss_u(sc));
        snprintf(c, sizeof c, "smp.io.cpu%d", i); snprintf(so, sizeof so, "spc.outputReg[%d]", i); put(c, mss_u(so));
    }
    put("smp.io.aux4", mss_u("spc.ramReg[0]")); put("smp.io.aux5", mss_u("spc.ramReg[1]"));
    put("smp.io.dspAddr", mss_u("spc.dspReg")); put("smp.io.iplromEnable", mss_u("spc.romEnabled"));
    put("smp.io.timersDisable", mss_u("spc.timersDisabled"));
    put("smp.io.ramWritable", mss_u("spc.writeEnabled"));
    put("smp.io.timersEnable", mss_u("spc.timersEnabled"));
    put("smp.io.externalWaitStates", mss_u("spc.externalSpeed"));
    put("smp.io.internalWaitStates", mss_u("spc.internalSpeed"));
    for (int t = 0; t < 3; t++) {
        char d[24], s[24], nm[40], k[40];
        snprintf(d, sizeof d, "smp.timer%d", t); snprintf(s, sizeof s, "spc.timer%d", t);
        #define PT(df, sf_) do { snprintf(nm, sizeof nm, "%s.%s", d, df); snprintf(k, sizeof k, "%s.%s", s, sf_); put(nm, mss_u(k)); } while (0)
        PT("stage0","stage0"); PT("stage1","stage1"); PT("stage2","stage2");
        PT("stage3","output"); PT("line","prevStage1"); PT("enable","enabled"); PT("target","target");
        #undef PT
    }
}
static void xf_dma(void) {
    uint64_t hdmaen = mss_u("dmaController.hdmaChannels");
    for (int ch = 0; ch < 8; ch++) {
        char s[40], d[24], nm[64], k[96];
        snprintf(s, sizeof s, "dmaController.channel[%d]", ch); snprintf(d, sizeof d, "cpu.channel[%d]", ch);
        snprintf(nm, sizeof nm, "%s.dmaEnable", d); put(nm, 0);
        snprintf(nm, sizeof nm, "%s.hdmaEnable", d); put(nm, (hdmaen >> ch) & 1);
        #define PD(df, sf_) do { snprintf(nm, sizeof nm, "%s.%s", d, df); snprintf(k, sizeof k, "%s.%s", s, sf_); put(nm, mss_u(k)); } while (0)
        PD("direction","invertDirection"); PD("indirect","hdmaIndirectAddressing"); PD("unused","unusedControlFlag");
        PD("reverseTransfer","decrement"); PD("fixedTransfer","fixedTransfer"); PD("transferMode","transferMode");
        PD("targetAddress","destAddress"); PD("sourceAddress","srcAddress"); PD("sourceBank","srcBank");
        PD("transferSize","transferSize"); PD("indirectBank","hdmaBank"); PD("hdmaAddress","hdmaTableAddress");
        PD("lineCounter","hdmaLineCounterAndRepeat"); PD("unknown","unusedRegister");
        PD("hdmaCompleted","hdmaFinished"); PD("hdmaDoTransfer","doTransfer");
        #undef PD
    }
}
/* SPC_DSP copy_state blob (blargg order, SPC_DSP.cpp:949-1016). */
static void xf_dsp_blob(void) {
    uint8_t blob[640]; memset(blob, 0, sizeof blob); size_t o = 0;
    #define B1(v) do { blob[o++] = (uint8_t)(v); } while (0)
    #define B2(v) do { uint32_t _t = (uint32_t)(v); blob[o++] = _t & 0xFF; blob[o++] = (_t >> 8) & 0xFF; } while (0)
    #define BARR(key, n) do { const uint8_t *_a = mss_arr(key, n); memcpy(blob + o, _a, n); o += (n); } while (0)
    BARR("spc.dsp.regs", 128);
    for (int i = 0; i < 8; i++) {
        char k[48];
        snprintf(k, sizeof k, "spc.dsp.voices[%d].sampleBuffer", i); BARR(k, 24);
        #define VU(f_) (snprintf(k, sizeof k, "spc.dsp.voices[%d].%s", i, f_), mss_u(k))
        B2(VU("interpolationPos")); B2(VU("brrAddress")); B2(VU("envVolume")); B2(VU("prevCalculatedEnv"));
        B1(VU("bufferPos")); B1(VU("brrOffset")); B1(VU("keyOnDelay")); B1(VU("envMode")); B1(VU("envOut"));
        B1(0); /* copier.extra() */
        #undef VU
    }
    BARR("spc.dsp.echoHistory", 32);
    B1(mss_u("spc.dsp.everyOtherSample")); B1(mss_u("spc.dsp.keyOn"));
    B2(mss_u("spc.dsp.noiseLfsr")); B2(mss_u("spc.dsp.counter")); B2(mss_u("spc.dsp.echoOffset")); B2(mss_u("spc.dsp.echoLength"));
    B1(mss_u("spc.dsp.step")); B1(mss_u("spc.dsp.newKeyOn")); B1(mss_u("spc.dsp.voiceEndBuffer"));
    B1(mss_u("spc.dsp.envRegBuffer")); B1(mss_u("spc.dsp.outRegBuffer"));
    B1(mss_u("spc.dsp.pitchModulationOn")); B1(mss_u("spc.dsp.noiseOn")); B1(mss_u("spc.dsp.echoOn"));
    B1(mss_u("spc.dsp.dirSampleTableAddress")); B1(mss_u("spc.dsp.keyOff"));
    B2(mss_u("spc.dsp.brrNextAddress")); B1(mss_u("spc.dsp.adsr1")); B1(mss_u("spc.dsp.brrHeader"));
    B1(mss_u("spc.dsp.brrData")); B1(mss_u("spc.dsp.sourceNumber")); B1(mss_u("spc.dsp.echoRingBufferAddress"));
    B1(mss_u("spc.dsp.echoEnabled"));
    const uint8_t *mo = mss_arr("spc.dsp.outSamples", 0), *eo = mss_arr("spc.dsp.echoOut", 0), *ei = mss_arr("spc.dsp.echoIn", 0);
    blob[o++] = mo[0]; blob[o++] = mo[1]; blob[o++] = mo[2]; blob[o++] = mo[3];
    blob[o++] = eo[0]; blob[o++] = eo[1]; blob[o++] = eo[2]; blob[o++] = eo[3];
    blob[o++] = ei[0]; blob[o++] = ei[1]; blob[o++] = ei[2]; blob[o++] = ei[3];
    B2(mss_u("spc.dsp.sampleAddress")); B2(mss_u("spc.dsp.pitch"));
    { const uint8_t *vo = mss_arr("spc.dsp.voiceOutput", 0); blob[o++] = vo[0]; blob[o++] = vo[1]; }
    B2(mss_u("spc.dsp.echoPointer")); B1(mss_u("spc.dsp.looped")); B1(0); /* extra() */
    if (o > 640) internal("dsp blob overran");
    #undef B1
    #undef B2
    #undef BARR
    putb("dsp.spc_dsp_blob", blob, 640);
}

int main(int argc, char **argv) {
    if (argc < 4) { fprintf(stderr, "usage: %s <capture.mss> <donor.bst> <out.bst> [sram_bytes]\n", argv[0]); return 1; }
    const char *mss_path = argv[1], *donor_path = argv[2], *out_path = argv[3];
    size_t sram = argc > 4 ? (size_t)strtoul(argv[4], NULL, 0) : 8192;

    mss_load(mss_path);

    /* donor .bst -> payload */
    size_t dn; uint8_t *df = slurp(donor_path, &dn);
    if (dn < 12 || rd_u32le(df) != BST_SIG) die("bad .bst donor container");
    uint32_t rle_state = rd_u32le(df + 4), rle_prev = rd_u32le(df + 8);
    if (12ull + rle_state + rle_prev != dn) die("donor container sizes disagree");
    size_t plen; uint8_t *payload = rle_decode(df + 12, rle_state, &plen);
    free(df);

    /* build the offset map by walking the payload positionally */
    g_pay = payload; g_paysize = plen; g_pos = 0;
    walk_offsets(sram);
    if (g_pos != g_paysize) refuse("donor payload has residual bytes after plain-cart walk (coprocessor cart or wrong sram size)");
    g_out = payload;

    /* header gates (as bsnes unserialize) */
    { struct field *v = fld("header.version"); if (memcmp(payload + v->off, "115.1", 5)) refuse("donor SerializerVersion != 115.1"); }
    if (payload[fld("header.synchronize")->off] != 1) refuse("donor synchronize != 1");
    if (payload[fld("header.fastppu")->off] != 1) refuse("donor fastppu != 1");

    /* raw byte-array domains (identical semantics both emulators) */
    putb("cpu.wram",       mss_arr("memoryManager.workRam", 131072), 131072);
    putb("ppufast.vram",   mss_arr("ppu.vram", 65536), 65536);
    putb("ppufast.cgram",  mss_arr("ppu.cgram", 512), 512);
    if (sram) putb("cartridge.ram", mss_arr("cart.saveRam", (uint32_t)sram), sram);
    putb("dsp.apuram",     mss_arr("spc.ram", 65536), 65536);

    /* register-file transforms */
    xf_cpu(); xf_cpu_io(); xf_ppu(); xf_oam(); xf_smp(); xf_dma(); xf_dsp_blob();

    /* re-wrap: RLE + 12-byte container (matches bsnes_host.cpp / states.cpp) */
    size_t rl; uint8_t *rle = rle_encode(payload, plen, &rl);
    FILE *f = fopen(out_path, "wb"); if (!f) die("cannot open output");
    uint8_t hdr[12]; uint32_t sig = BST_SIG;
    for (int b = 0; b < 4; b++) hdr[b] = (sig >> (b * 8)) & 0xFF;
    for (int b = 0; b < 4; b++) hdr[4 + b] = ((uint32_t)rl >> (b * 8)) & 0xFF;
    for (int b = 0; b < 4; b++) hdr[8 + b] = 0;  /* no preview */
    if (fwrite(hdr, 1, 12, f) != 12 || fwrite(rle, 1, rl, f) != rl) die("write failed");
    fclose(f);
    fprintf(stderr, "transmute_snes: wrote %s (%zu payload bytes, %zu fields mapped)\n", out_path, plen, g_nfield);
    return 0;
}
