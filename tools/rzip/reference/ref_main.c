/* ref-rzip — CLI harness over the VENDORED, UNMODIFIED libretro-common
 * rzip_stream.c: the same code NextUI's minarch and RetroArch compile.
 * Mirrors minarch's exact calls (rzipstream_write_file at write time,
 * rzipstream_read_file at read time), so its output/acceptance IS the
 * OS's real behavior — the interop oracle for continuity-rzip.
 *
 * Usage:
 *   ref-rzip compress   IN OUT   (writes RZIP, default chunking —
 *                                 exactly what a device would produce)
 *   ref-rzip decompress IN OUT   (reads RZIP or raw transparently,
 *                                 exactly like the device reads saves)
 */

#include <stdio.h>
#include <stdlib.h>

#include <boolean.h>
#include <streams/rzip_stream.h>

static void *slurp(const char *path, int64_t *len)
{
    FILE *f = fopen(path, "rb");
    void *buf;
    long sz;

    if (!f)
        return NULL;
    if (fseek(f, 0, SEEK_END) != 0 || (sz = ftell(f)) < 0) {
        fclose(f);
        return NULL;
    }
    rewind(f);
    buf = malloc(sz ? (size_t)sz : 1);
    if (!buf || fread(buf, 1, (size_t)sz, f) != (size_t)sz) {
        free(buf);
        fclose(f);
        return NULL;
    }
    fclose(f);
    *len = (int64_t)sz;
    return buf;
}

int main(int argc, char **argv)
{
    if (argc != 4) {
        fprintf(stderr, "usage: ref-rzip compress|decompress IN OUT\n");
        return 2;
    }

    if (argv[1][0] == 'c') {
        int64_t len = 0;
        void *buf = slurp(argv[2], &len);
        if (!buf) {
            fprintf(stderr, "ref-rzip: cannot read %s\n", argv[2]);
            return 2;
        }
        /* minarch.c:859 / :1114 — the device's write call */
        if (!rzipstream_write_file(argv[3], buf, len)) {
            fprintf(stderr, "ref-rzip: rzipstream_write_file failed\n");
            return 1;
        }
        free(buf);
        return 0;
    }

    if (argv[1][0] == 'd') {
        void *buf = NULL;
        int64_t len = 0;
        FILE *out;
        /* the device's read call — sniffs RZIP vs raw itself */
        if (!rzipstream_read_file(argv[2], &buf, &len)) {
            fprintf(stderr, "ref-rzip: rzipstream_read_file failed\n");
            return 1;
        }
        out = fopen(argv[3], "wb");
        if (!out || fwrite(buf, 1, (size_t)len, out) != (size_t)len) {
            fprintf(stderr, "ref-rzip: cannot write %s\n", argv[3]);
            return 2;
        }
        fclose(out);
        free(buf);
        return 0;
    }

    fprintf(stderr, "ref-rzip: unknown mode %s\n", argv[1]);
    return 2;
}
