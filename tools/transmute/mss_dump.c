/* mss_dump — Mesen2 .mss save-state decode oracle (Spike T2.0, P0).
 *
 * Read-only field-inventory tool: prints the container header, then every
 * record in the keyed payload in file order. Exists to prove the format
 * pins in cms/mapping_mesen2_bsnes.json against real files, and to serve
 * as the decode half's executable specification.
 *
 * Format truth: vendored Mesen2 @ b9fa69ddc6d0a331fb103fdb5eef6904305703c2
 *   container: Core/Shared/SaveStateManager.cpp:60-129
 *   payload:   Core/Shared/Emulator.cpp (Serialize) +
 *              Utilities/Serializer.cpp:64-146 / Serializer.h:255-266
 *
 * Output (stdout), deterministic for byte-identical input:
 *   header lines "mss.<field> = <value>"
 *   one line per record: "<key>\t<size>\t<rendering>"
 *     size <= 8: little-endian value as 0x hex (+ decimal)
 *     size >  8: crc32 of the value bytes
 * -x <key>: write that record's raw value bytes to stdout instead
 *   (extraction mode, for piping into od/cmp in tests and for P2
 *   decode debugging); exit 3 if the key is absent.
 * Firewall: any key under a coprocessor prefix flips the exit to REFUSE.
 *
 * Exit: 0 clean, 2 refused (chip firewall), 1 malformed/unreadable,
 * 3 extraction key not found. Desktop-tier x86_64 tool; C99 + zlib.
 * Never ships to a device.
 */

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

#define MSS_SIZE_CAP (10u * 1024u * 1024u) /* Serializer.cpp:85-88 */
#define VIDEO_ZLIB_CAP (2u * 1024u * 1024u)

static const char *refuse_prefixes[] = {
    /* BaseCartridge.cpp:735-747 — presence of any of these = chip cart */
    "cart.coprocessor.", "cart.bsxMemPack.", "cart.gameboy.", "msu1.",
    NULL
};

static void die(const char *msg)
{
    fprintf(stderr, "mss_dump: %s\n", msg);
    exit(1);
}

static uint32_t rd_u32le(const uint8_t *p)
{
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 |
           (uint32_t)p[3] << 24;
}

static uint32_t read_u32(FILE *f, const char *what)
{
    uint8_t b[4];
    if (fread(b, 1, 4, f) != 4) {
        fprintf(stderr, "mss_dump: truncated reading %s\n", what);
        exit(1);
    }
    return rd_u32le(b);
}

static uint8_t *read_exact(FILE *f, size_t n, const char *what)
{
    uint8_t *buf = malloc(n ? n : 1);
    if (!buf)
        die("out of memory");
    if (fread(buf, 1, n, f) != n) {
        fprintf(stderr, "mss_dump: truncated reading %s\n", what);
        exit(1);
    }
    return buf;
}

/* Payload record stream: [key bytes 0x21..0x7E][0x00][u32le size][value].
 * extract==NULL: dump every record, return 1 if firewall tripped.
 * extract!=NULL: write that key's value bytes to stdout, return 0 on
 * hit, -1 on miss (firewall does not apply in extraction mode). */
static int dump_records(const uint8_t *data, size_t size,
                        const char *extract)
{
    size_t i = 0;
    int refused = 0;
    int found = 0;

    while (i < size) {
        size_t kstart = i;
        while (i < size && data[i] != 0) {
            /* key charset per Serializer.cpp:117 — else invalid state */
            if (data[i] <= ' ' || data[i] >= 127)
                die("invalid character in record key");
            i++;
        }
        if (i == size)
            die("unterminated record key");
        if (i == kstart)
            die("empty record key");

        size_t klen = i - kstart;
        i++; /* NUL */
        if (i + 4 > size)
            die("truncated record size");
        uint32_t vsize = rd_u32le(data + i);
        i += 4;
        if (i + vsize > size)
            die("record value overruns payload");

        char key[512];
        if (klen >= sizeof(key))
            die("record key longer than 511 bytes");
        memcpy(key, data + kstart, klen);
        key[klen] = 0;

        if (extract) {
            if (strcmp(key, extract) == 0) {
                fwrite(data + i, 1, vsize, stdout);
                found = 1;
            }
        } else {
            for (const char **p = refuse_prefixes; *p; p++) {
                if (strncmp(key, *p, strlen(*p)) == 0)
                    refused = 1;
            }

            if (vsize <= 8) {
                uint64_t v = 0;
                for (uint32_t b = 0; b < vsize; b++)
                    v |= (uint64_t)data[i + b] << (8 * b);
                printf("%s\t%u\t0x%llx\t%llu\n", key, vsize,
                       (unsigned long long)v, (unsigned long long)v);
            } else {
                uLong crc = crc32(0L, data + i, vsize);
                printf("%s\t%u\tcrc32=%08lx\n", key, vsize,
                       (unsigned long)crc);
            }
        }
        i += vsize;
    }
    if (extract)
        return found ? 0 : -1;
    return refused;
}

int main(int argc, char **argv)
{
    int header_only = 0;
    const char *extract = NULL;
    const char *path = NULL;

    for (int a = 1; a < argc; a++) {
        if (strcmp(argv[a], "-H") == 0)
            header_only = 1;
        else if (strcmp(argv[a], "-x") == 0 && a + 1 < argc)
            extract = argv[++a];
        else if (!path)
            path = argv[a];
        else
            die("usage: mss_dump [-H | -x key] file.mss");
    }
    if (!path)
        die("usage: mss_dump [-H | -x key] file.mss");

    FILE *f = fopen(path, "rb");
    if (!f) {
        fprintf(stderr, "mss_dump: %s: %s\n", path, strerror(errno));
        return 1;
    }

    /* --- container header (SaveStateManager.cpp:60-83) --- */
    uint8_t magic[3];
    if (fread(magic, 1, 3, f) != 3 || memcmp(magic, "MSS", 3) != 0)
        die("bad magic (want \"MSS\")");

    uint32_t emu_version = read_u32(f, "emu_version");
    uint32_t format_version = read_u32(f, "format_version");
    uint32_t console_type = read_u32(f, "console_type");
    if (!extract) {
        printf("mss.emu_version = %u\n", emu_version);
        printf("mss.format_version = %u\n", format_version);
        printf("mss.console_type = %u\n", console_type);
    }
    if (format_version < 3)
        die("format_version < 3 (pre-v3 states carry a different header)");
    if (console_type != 0) {
        fprintf(stderr, "mss_dump: REFUSE: console_type %u is not SNES(0)\n",
                console_type);
        return 2;
    }

    /* video block (SaveVideoData, SaveStateManager.cpp:115-129) — skip */
    uint32_t fb_size = read_u32(f, "video_frame_size");
    uint32_t fb_w = read_u32(f, "video_width");
    uint32_t fb_h = read_u32(f, "video_height");
    uint32_t fb_scale = read_u32(f, "video_scale_x100");
    uint32_t fb_zlib = read_u32(f, "video_zlib_size");
    if (!extract)
        printf("mss.video = %ux%u scale=%u.%02u raw=%u zlib=%u\n", fb_w,
               fb_h, fb_scale / 100, fb_scale % 100, fb_size, fb_zlib);
    if (fb_zlib >= VIDEO_ZLIB_CAP)
        die("video zlib block exceeds 2 MB load cap");
    free(read_exact(f, fb_zlib, "video zlib data"));

    uint32_t name_len = read_u32(f, "rom_name_len");
    if (name_len >= 4096)
        die("implausible rom name length");
    uint8_t *name = read_exact(f, name_len, "rom name");
    if (!extract)
        printf("mss.rom_name = %.*s\n", (int)name_len, (const char *)name);
    free(name);

    /* --- payload framing (Serializer.cpp:64-107) --- */
    int comp = fgetc(f);
    if (comp == EOF)
        die("truncated at payload flag");
    if (!extract)
        printf("mss.payload_compressed = %d\n", comp == 1);

    uint8_t *payload = NULL;
    size_t payload_size = 0;

    if (comp == 1) {
        uint32_t raw_size = read_u32(f, "payload raw size");
        uint32_t zlib_size = read_u32(f, "payload zlib size");
        if (raw_size >= MSS_SIZE_CAP || zlib_size >= MSS_SIZE_CAP)
            die("payload exceeds 10 MB load cap");
        uint8_t *zdata = read_exact(f, zlib_size, "payload zlib data");
        payload = malloc(raw_size ? raw_size : 1);
        if (!payload)
            die("out of memory");
        uLongf dst = raw_size;
        if (uncompress(payload, &dst, zdata, zlib_size) != Z_OK ||
            dst != raw_size)
            die("payload zlib decompression failed");
        free(zdata);
        payload_size = raw_size;
        if (!extract)
            printf("mss.payload_raw_size = %u\n", raw_size);
    } else {
        /* uncompressed: records run to EOF (Serializer.cpp:99-106) */
        long pos = ftell(f);
        if (pos < 0 || fseek(f, 0, SEEK_END) != 0)
            die("seek failed");
        long end = ftell(f);
        if (end < pos || fseek(f, pos, SEEK_SET) != 0)
            die("seek failed");
        payload_size = (size_t)(end - pos);
        if (payload_size >= MSS_SIZE_CAP)
            die("payload exceeds 10 MB load cap");
        payload = read_exact(f, payload_size, "raw payload");
        if (!extract)
            printf("mss.payload_raw_size = %zu\n", payload_size);
    }
    fclose(f);

    int rc = 0;
    if (extract) {
        if (dump_records(payload, payload_size, extract) < 0) {
            fprintf(stderr, "mss_dump: key not found: %s\n", extract);
            rc = 3;
        }
    } else if (!header_only) {
        rc = dump_records(payload, payload_size, NULL);
        if (rc) {
            fprintf(stderr,
                    "mss_dump: REFUSE: coprocessor/enhancement keys "
                    "present (chip firewall)\n");
            rc = 2;
        }
    }
    free(payload);
    return rc;
}
