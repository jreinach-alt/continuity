/* shim: only what rzip_stream.c uses from file/file_path.h */
#ifndef SHIM_FILE_PATH_H
#define SHIM_FILE_PATH_H
#include <boolean.h>
bool path_is_valid(const char *path);
#endif
