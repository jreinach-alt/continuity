/* shim: the exact file_stream.h surface rzip_stream.c consumes,
 * backed by stdio in file_stream_stdio.c. File I/O plumbing only —
 * nothing here influences the RZIP byte format. */
#ifndef SHIM_FILE_STREAM_H
#define SHIM_FILE_STREAM_H

#include <stdint.h>
#include <stdlib.h>  /* the real file_stream.h chain provides this transitively */
#include <boolean.h>
#include <retro_common_api.h>

RETRO_BEGIN_DECLS

typedef struct RFILE RFILE;

#define RETRO_VFS_FILE_ACCESS_READ            (1 << 0)
#define RETRO_VFS_FILE_ACCESS_WRITE           (1 << 1)
#define RETRO_VFS_FILE_ACCESS_READ_WRITE \
        (RETRO_VFS_FILE_ACCESS_READ | RETRO_VFS_FILE_ACCESS_WRITE)
#define RETRO_VFS_FILE_ACCESS_UPDATE_EXISTING (1 << 2)

#define RETRO_VFS_FILE_ACCESS_HINT_NONE            0
#define RETRO_VFS_FILE_ACCESS_HINT_FREQUENT_ACCESS (1 << 0)

#define RETRO_VFS_SEEK_POSITION_START   0
#define RETRO_VFS_SEEK_POSITION_CURRENT 1
#define RETRO_VFS_SEEK_POSITION_END     2

RFILE  *filestream_open(const char *path, unsigned mode, unsigned hints);
int64_t filestream_read(RFILE *stream, void *data, int64_t len);
int64_t filestream_write(RFILE *stream, const void *data, int64_t len);
int64_t filestream_seek(RFILE *stream, int64_t offset, int seek_position);
int64_t filestream_tell(RFILE *stream);
void    filestream_rewind(RFILE *stream);
int64_t filestream_get_size(RFILE *stream);
int     filestream_close(RFILE *stream);
int     filestream_error(RFILE *stream);
int     filestream_eof(RFILE *stream);

RETRO_END_DECLS

#endif
