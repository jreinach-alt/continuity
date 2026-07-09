/* shim: stdio-backed implementation of the file_stream surface
 * rzip_stream.c consumes. Pure plumbing — the RZIP byte format is
 * produced entirely by the vendored, unmodified rzip_stream.c. */
#define _POSIX_C_SOURCE 200809L  /* fseeko/ftello/off_t under -std=c99 */
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>

#include <boolean.h>
#include <streams/file_stream.h>
#include <file/file_path.h>

struct RFILE
{
    FILE *fp;
};

bool path_is_valid(const char *path)
{
    struct stat st;
    return path && stat(path, &st) == 0;
}

RFILE *filestream_open(const char *path, unsigned mode, unsigned hints)
{
    const char *m;
    RFILE *f;
    (void)hints;

    if ((mode & RETRO_VFS_FILE_ACCESS_READ) &&
        (mode & RETRO_VFS_FILE_ACCESS_WRITE))
        m = (mode & RETRO_VFS_FILE_ACCESS_UPDATE_EXISTING) ? "r+b" : "w+b";
    else if (mode & RETRO_VFS_FILE_ACCESS_WRITE)
        m = "wb";
    else
        m = "rb";

    f = malloc(sizeof(*f));
    if (!f)
        return NULL;
    f->fp = fopen(path, m);
    if (!f->fp) {
        free(f);
        return NULL;
    }
    return f;
}

int64_t filestream_read(RFILE *stream, void *data, int64_t len)
{
    if (!stream || len < 0)
        return -1;
    return (int64_t)fread(data, 1, (size_t)len, stream->fp);
}

int64_t filestream_write(RFILE *stream, const void *data, int64_t len)
{
    if (!stream || len < 0)
        return -1;
    return (int64_t)fwrite(data, 1, (size_t)len, stream->fp);
}

int64_t filestream_seek(RFILE *stream, int64_t offset, int seek_position)
{
    int whence;
    if (!stream)
        return -1;
    switch (seek_position) {
        case RETRO_VFS_SEEK_POSITION_CURRENT: whence = SEEK_CUR; break;
        case RETRO_VFS_SEEK_POSITION_END:     whence = SEEK_END; break;
        default:                              whence = SEEK_SET; break;
    }
    if (fseeko(stream->fp, (off_t)offset, whence) != 0)
        return -1;
    return (int64_t)ftello(stream->fp);
}

int64_t filestream_tell(RFILE *stream)
{
    if (!stream)
        return -1;
    return (int64_t)ftello(stream->fp);
}

void filestream_rewind(RFILE *stream)
{
    if (stream)
        rewind(stream->fp);
}

int64_t filestream_get_size(RFILE *stream)
{
    off_t cur, size;
    if (!stream)
        return -1;
    cur = ftello(stream->fp);
    if (fseeko(stream->fp, 0, SEEK_END) != 0)
        return -1;
    size = ftello(stream->fp);
    fseeko(stream->fp, cur, SEEK_SET);
    return (int64_t)size;
}

int filestream_close(RFILE *stream)
{
    int rc;
    if (!stream)
        return -1;
    rc = fclose(stream->fp);
    free(stream);
    return rc;
}

int filestream_error(RFILE *stream)
{
    if (!stream)
        return 1;
    return ferror(stream->fp);
}

int filestream_eof(RFILE *stream)
{
    if (!stream)
        return 1;
    return feof(stream->fp);
}
