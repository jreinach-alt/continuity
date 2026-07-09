/*
 * continuity-rzip — standalone codec for RetroArch's RZIP save container.
 *
 * Format (pinned to libretro-common streams/rzip_stream.c, the
 * implementation NextUI's minarch and RetroArch both use):
 *
 *   20-byte file header:
 *     bytes 0-7   magic: '#' 'R' 'Z' 'I' 'P' 'v' 0x01 '#'
 *                 (byte 6 is the raw version NUMBER, not ASCII '1')
 *     bytes 8-11  chunk size, uint32 little-endian, nonzero
 *     bytes 12-19 total uncompressed size, uint64 little-endian, nonzero
 *   then per chunk:
 *     4 bytes     compressed frame size, uint32 little-endian, nonzero
 *     N bytes     one whole zlib stream inflating to exactly chunk_size
 *                 bytes (the final chunk inflates to the remainder)
 *
 * Anything without that magic — including files shorter than 20 bytes
 * and any future version byte — is treated as raw data, exactly like
 * the reference reader does.
 *
 * Defensive parsing mirrors the reference's hardening: declared chunk
 * size is capped (a malformed header must not drive huge allocations)
 * and a compressed frame may not exceed twice the chunk size.
 *
 * Usage:
 *   continuity-rzip detect FILE            print "rzip" or "raw"
 *                                          exit 0=rzip, 1=raw, 2=error
 *   continuity-rzip compress IN OUT [-c N] raw -> rzip (chunk N, default 128 KiB)
 *   continuity-rzip decompress IN OUT      rzip -> raw (refuses raw input)
 *   continuity-rzip --version
 */

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

#define TOOL_VERSION "1.0.0"

#define RZIP_HEADER_SIZE 20
#define RZIP_CHUNK_HEADER_SIZE 4
#define RZIP_DEFAULT_CHUNK_SIZE 131072u
#define RZIP_MAX_CHUNK_SIZE (64u * 1024u * 1024u)
#define RZIP_COMPRESSION_LEVEL 6

static const uint8_t RZIP_MAGIC[8] = { '#', 'R', 'Z', 'I', 'P', 'v', 1, '#' };

static void die(const char *msg, const char *detail)
{
    if (detail)
        fprintf(stderr, "continuity-rzip: %s: %s\n", msg, detail);
    else
        fprintf(stderr, "continuity-rzip: %s\n", msg);
    exit(2);
}

static uint32_t read_u32le(const uint8_t *b)
{
    return  (uint32_t)b[0]
         | ((uint32_t)b[1] << 8)
         | ((uint32_t)b[2] << 16)
         | ((uint32_t)b[3] << 24);
}

static uint64_t read_u64le(const uint8_t *b)
{
    return  (uint64_t)read_u32le(b)
         | ((uint64_t)read_u32le(b + 4) << 32);
}

static void write_u32le(uint8_t *b, uint32_t v)
{
    b[0] = (uint8_t)(v & 0xFF);
    b[1] = (uint8_t)((v >> 8) & 0xFF);
    b[2] = (uint8_t)((v >> 16) & 0xFF);
    b[3] = (uint8_t)((v >> 24) & 0xFF);
}

static void write_u64le(uint8_t *b, uint64_t v)
{
    write_u32le(b, (uint32_t)(v & 0xFFFFFFFFu));
    write_u32le(b + 4, (uint32_t)(v >> 32));
}

/* header_is_rzip — the reference reader's exact acceptance test:
 * full 20-byte header present, 8 magic bytes (version byte included)
 * match, chunk size and total size nonzero, chunk size within cap. */
static int header_is_rzip(const uint8_t *hdr, size_t len,
                          uint32_t *chunk_size, uint64_t *total_size)
{
    uint32_t cs;
    uint64_t ts;

    if (len < RZIP_HEADER_SIZE)
        return 0;
    if (memcmp(hdr, RZIP_MAGIC, sizeof(RZIP_MAGIC)) != 0)
        return 0;

    cs = read_u32le(hdr + 8);
    ts = read_u64le(hdr + 12);
    if (cs == 0 || ts == 0 || cs > RZIP_MAX_CHUNK_SIZE)
        return 0;

    if (chunk_size)
        *chunk_size = cs;
    if (total_size)
        *total_size = ts;
    return 1;
}

static int cmd_detect(const char *path)
{
    uint8_t hdr[RZIP_HEADER_SIZE];
    size_t n;
    FILE *f = fopen(path, "rb");

    if (!f) {
        fprintf(stderr, "continuity-rzip: cannot open: %s: %s\n",
                path, strerror(errno));
        return 2;
    }
    n = fread(hdr, 1, sizeof(hdr), f);
    if (ferror(f)) {
        fclose(f);
        fprintf(stderr, "continuity-rzip: read error: %s\n", path);
        return 2;
    }
    fclose(f);

    if (header_is_rzip(hdr, n, NULL, NULL)) {
        printf("rzip\n");
        return 0;
    }
    printf("raw\n");
    return 1;
}

static int cmd_compress(const char *in_path, const char *out_path,
                        uint32_t chunk_size)
{
    FILE *in, *out;
    uint8_t hdr[RZIP_HEADER_SIZE];
    uint8_t chunk_hdr[RZIP_CHUNK_HEADER_SIZE];
    uint8_t *in_buf, *out_buf;
    uLong out_cap;
    uint64_t total = 0;
    size_t got;

    if (chunk_size == 0 || chunk_size > RZIP_MAX_CHUNK_SIZE)
        die("invalid chunk size", NULL);

    in = fopen(in_path, "rb");
    if (!in)
        die("cannot open input", in_path);
    if (fseek(in, 0, SEEK_END) != 0)
        die("cannot seek input", in_path);
    {
        long sz = ftell(in);
        if (sz < 0)
            die("cannot size input", in_path);
        total = (uint64_t)sz;
    }
    rewind(in);

    /* The reference reader rejects a declared size of zero — an empty
     * payload is unrepresentable in RZIP v1. Refuse rather than emit
     * a file the device could never read back. */
    if (total == 0)
        die("refusing to compress empty input (RZIP cannot represent it)",
            in_path);

    out = fopen(out_path, "wb");
    if (!out)
        die("cannot open output", out_path);

    memcpy(hdr, RZIP_MAGIC, sizeof(RZIP_MAGIC));
    write_u32le(hdr + 8, chunk_size);
    write_u64le(hdr + 12, total);
    if (fwrite(hdr, 1, sizeof(hdr), out) != sizeof(hdr))
        die("write failed", out_path);

    out_cap = compressBound(chunk_size);
    in_buf  = malloc(chunk_size);
    out_buf = malloc(out_cap);
    if (!in_buf || !out_buf)
        die("out of memory", NULL);

    while ((got = fread(in_buf, 1, chunk_size, in)) > 0) {
        uLongf out_len = out_cap;
        int zrc = compress2(out_buf, &out_len, in_buf, (uLong)got,
                            RZIP_COMPRESSION_LEVEL);
        if (zrc != Z_OK)
            die("zlib compress failed", NULL);
        if (out_len == 0 || out_len > 0xFFFFFFFFu)
            die("compressed chunk size out of range", NULL);
        write_u32le(chunk_hdr, (uint32_t)out_len);
        if (fwrite(chunk_hdr, 1, sizeof(chunk_hdr), out) != sizeof(chunk_hdr))
            die("write failed", out_path);
        if (fwrite(out_buf, 1, out_len, out) != out_len)
            die("write failed", out_path);
    }
    if (ferror(in))
        die("read error", in_path);

    free(in_buf);
    free(out_buf);
    if (fclose(out) != 0)
        die("close failed (disk full?)", out_path);
    fclose(in);
    return 0;
}

static int cmd_decompress(const char *in_path, const char *out_path)
{
    FILE *in, *out;
    uint8_t hdr[RZIP_HEADER_SIZE];
    uint8_t chunk_hdr[RZIP_CHUNK_HEADER_SIZE];
    uint8_t *in_buf, *out_buf;
    uint32_t chunk_size = 0;
    uint64_t total = 0, written = 0;
    size_t n;

    in = fopen(in_path, "rb");
    if (!in)
        die("cannot open input", in_path);

    n = fread(hdr, 1, sizeof(hdr), in);
    if (ferror(in))
        die("read error", in_path);
    if (!header_is_rzip(hdr, n, &chunk_size, &total)) {
        fprintf(stderr,
                "continuity-rzip: not an RZIP file (raw?): %s\n", in_path);
        fclose(in);
        return 1;
    }

    out = fopen(out_path, "wb");
    if (!out)
        die("cannot open output", out_path);

    /* compressed frame cap mirrors the reference: 2x chunk size */
    in_buf  = malloc((size_t)chunk_size * 2);
    out_buf = malloc(chunk_size);
    if (!in_buf || !out_buf)
        die("out of memory", NULL);

    while (written < total) {
        uint64_t remaining = total - written;
        uint64_t expect = remaining < chunk_size ? remaining : chunk_size;
        uint32_t frame;
        uLongf out_len = chunk_size;
        int zrc;

        if (fread(chunk_hdr, 1, sizeof(chunk_hdr), in) != sizeof(chunk_hdr))
            die("truncated file (chunk header)", in_path);
        frame = read_u32le(chunk_hdr);
        if (frame == 0 || frame > chunk_size * 2u)
            die("malformed chunk header", in_path);
        if (fread(in_buf, 1, frame, in) != frame)
            die("truncated file (chunk data)", in_path);

        zrc = uncompress(out_buf, &out_len, in_buf, frame);
        if (zrc != Z_OK)
            die("zlib inflate failed (corrupt chunk)", in_path);
        if (out_len != expect)
            die("chunk inflated to unexpected size", in_path);

        if (fwrite(out_buf, 1, out_len, out) != out_len)
            die("write failed", out_path);
        written += out_len;
    }

    /* Strict: trailing bytes mean the file is not what its header
     * claims — refuse rather than silently ignore. */
    if (fread(chunk_hdr, 1, 1, in) != 0)
        die("trailing bytes after final chunk", in_path);

    free(in_buf);
    free(out_buf);
    if (fclose(out) != 0)
        die("close failed (disk full?)", out_path);
    fclose(in);
    return 0;
}

int main(int argc, char **argv)
{
    if (argc >= 2 && strcmp(argv[1], "--version") == 0) {
        printf("continuity-rzip %s (rzip v1, zlib %s)\n",
               TOOL_VERSION, zlibVersion());
        return 0;
    }
    if (argc >= 3 && strcmp(argv[1], "detect") == 0)
        return cmd_detect(argv[2]);
    if (argc >= 4 && strcmp(argv[1], "compress") == 0) {
        uint32_t chunk = RZIP_DEFAULT_CHUNK_SIZE;
        if (argc >= 6 && strcmp(argv[4], "-c") == 0) {
            char *end = NULL;
            unsigned long v = strtoul(argv[5], &end, 10);
            if (!end || *end != '\0' || v == 0 || v > RZIP_MAX_CHUNK_SIZE)
                die("invalid -c chunk size", argv[5]);
            chunk = (uint32_t)v;
        }
        return cmd_compress(argv[2], argv[3], chunk);
    }
    if (argc >= 4 && strcmp(argv[1], "decompress") == 0)
        return cmd_decompress(argv[2], argv[3]);

    fprintf(stderr,
        "usage: continuity-rzip detect FILE\n"
        "       continuity-rzip compress IN OUT [-c CHUNK_BYTES]\n"
        "       continuity-rzip decompress IN OUT\n"
        "       continuity-rzip --version\n");
    return 2;
}
