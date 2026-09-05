/* One portable save transaction for native filesystems and Emscripten IDBFS.
 * Archive: 8-byte magic LEMONSV1, little-endian payload length and CRC32, then
 * the original compressed Lemonade.dat. No filenames or guest pointers enter
 * the archive. The browser separately awaits syncfs to make a commit durable. */
#include "save.h"
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <sys/stat.h>
#include <unistd.h>

#define SAVE_LIMIT (8u * 1024u * 1024u)
static pthread_mutex_t save_lock = PTHREAD_MUTEX_INITIALIZER;
static FILE *writer;
static char writer_directory[2048];
static int running;
static LemonSaveStatus latest;
static const char *leaves[] = {"Lemonade.dat", "Lemonade.dat.bak", "Lemonade.before-import.dat"};
static void filename(char *out, const char *dir, const char *leaf) {
  snprintf(out, 4096, "%s/%s", dir, leaf);
}
static int read_bytes(const char *path, unsigned char **out, size_t *length) {
  FILE *f = fopen(path, "rb");
  if (!f)
    return errno == ENOENT ? LEMON_SAVE_MISSING : LEMON_SAVE_IO;
  struct stat st;
  int result = LEMON_SAVE_INVALID;
  if (!fstat(fileno(f), &st) && st.st_size >= 0 && st.st_size <= SAVE_LIMIT + 16) {
    *length = st.st_size;
    *out = malloc(*length ? *length : 1);
    if (*out) {
      result = fread(*out, 1, *length, f) == *length && !ferror(f) ? LEMON_SAVE_OK : LEMON_SAVE_IO;
      if (result) {
        free(*out);
        *out = NULL;
      }
    } else
      result = LEMON_SAVE_IO;
  }
  fclose(f);
  return result;
}
static int flush_close(FILE *f) {
  int ok = !ferror(f);
  if (fflush(f) || fsync(fileno(f)))
    ok = 0;
  if (fclose(f))
    ok = 0;
  return ok;
}
static int atomic_bytes(const char *target, const void *data, size_t length) {
  char temp[4100];
  snprintf(temp, sizeof(temp), "%s.tmp", target);
  FILE *f = fopen(temp, "wb");
  if (!f)
    return LEMON_SAVE_IO;
  int ok = fwrite(data, 1, length, f) == length;
  if (!flush_close(f))
    ok = 0;
  if (ok && rename(temp, target))
    ok = 0;
  if (!ok)
    unlink(temp);
  return ok ? LEMON_SAVE_OK : LEMON_SAVE_IO;
}
static int copy_backup(const char *dir, const char *backup) {
  char current[4096], target[4096];
  filename(current, dir, leaves[0]);
  filename(target, dir, backup);
  unsigned char *bytes = NULL;
  size_t length = 0;
  int result = read_bytes(current, &bytes, &length);
  if (result == LEMON_SAVE_MISSING)
    return LEMON_SAVE_OK;
  if (!result)
    result = atomic_bytes(target, bytes, length);
  free(bytes);
  return result;
}
static uint32_t checksum(const unsigned char *bytes, size_t length) {
  uint32_t crc = UINT32_MAX;
  for (size_t i = 0; i < length; i++) {
    crc ^= bytes[i];
    for (unsigned bit = 0; bit < 8; bit++)
      crc = (crc >> 1) ^ (0xedb88320u & -(crc & 1));
  }
  return ~crc;
}
static uint32_t get32(const unsigned char *p) {
  return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}
static void put32(unsigned char *p, uint32_t v) {
  for (unsigned i = 0; i < 4; i++)
    p[i] = v >> (i * 8);
}
static int payload_valid(const unsigned char *p, size_t n) {
  /* The original compressor's two format bytes, followed by its 24-byte header.
   * Archive integrity is checked separately; this is not a new game serializer. */
  return n >= 26 && n <= SAVE_LIMIT && p[0] == 1 && p[1] == 1;
}
static int read_archive(const char *path, unsigned char **bytes, size_t *length) {
  int result = read_bytes(path, bytes, length);
  if (result)
    return result;
  unsigned char *p = *bytes;
  size_t n = *length;
  if (n < 42 || memcmp(p, "LEMONSV1", 8) || get32(p + 8) != n - 16 ||
      !payload_valid(p + 16, n - 16) || get32(p + 12) != checksum(p + 16, n - 16)) {
    free(p);
    *bytes = NULL;
    return LEMON_SAVE_INVALID;
  }
  return LEMON_SAVE_OK;
}
const char *lemon_save_message(int result) {
  switch (result) {
  case LEMON_SAVE_OK:
    return "Save ready.";
  case LEMON_SAVE_MISSING:
    return "There is no saved checkpoint here yet.";
  case LEMON_SAVE_INVALID:
    return "This save file is incomplete, damaged, or an unsupported version.";
  case LEMON_SAVE_BUSY:
    return "Close the game before importing a save.";
  default:
    return "The save could not be written. Your previous checkpoint is unchanged.";
  }
}
void lemon_save_running(int value) {
  pthread_mutex_lock(&save_lock);
  running = value;
  pthread_mutex_unlock(&save_lock);
}
void lemon_save_status(const char *dir, LemonSaveStatus *status) {
  pthread_mutex_lock(&save_lock);
  *status = latest;
  status->available = 0;
  for (unsigned i = 0; i < 3; i++) {
    char path[4096];
    struct stat st;
    filename(path, dir, leaves[i]);
    if (!stat(path, &st)) {
      status->available |= 1 << i;
      if (!i)
        status->saved_at = st.st_mtime;
    }
  }
  pthread_mutex_unlock(&save_lock);
}
FILE *lemon_save_open(const char *dir, unsigned creation) {
  pthread_mutex_lock(&save_lock);
  char current[4096], temp[4096];
  filename(current, dir, leaves[0]);
  filename(temp, dir, "Lemonade.dat.pending");
  int exists = access(current, F_OK) == 0;
  if (writer || strlen(dir) >= sizeof(writer_directory) || creation < 1 || creation > 5 ||
      (creation == 1 && exists) || ((creation == 3 || creation == 5) && !exists)) {
    errno = writer ? EBUSY : creation == 1 && exists ? EEXIST : ENOENT;
    pthread_mutex_unlock(&save_lock);
    return NULL;
  }
  if ((creation == 3 || creation == 4) && exists) {
    unsigned char *bytes = NULL;
    size_t n = 0;
    int result = read_bytes(current, &bytes, &n);
    if (!result)
      result = atomic_bytes(temp, bytes, n);
    free(bytes);
    if (result) {
      pthread_mutex_unlock(&save_lock);
      return NULL;
    }
    writer = fopen(temp, "r+b");
  } else
    writer = fopen(temp, "w+b");
  if (writer)
    snprintf(writer_directory, sizeof(writer_directory), "%s", dir);
  pthread_mutex_unlock(&save_lock);
  return writer;
}
int lemon_save_close(FILE *file, int commit) {
  pthread_mutex_lock(&save_lock);
  if (file != writer) {
    pthread_mutex_unlock(&save_lock);
    return fclose(file) == 0;
  }
  char current[4096], temp[4096];
  filename(current, writer_directory, leaves[0]);
  filename(temp, writer_directory, "Lemonade.dat.pending");
  int result = flush_close(file) ? LEMON_SAVE_OK : LEMON_SAVE_IO;
  writer = NULL;
  if (commit) {
    unsigned char *bytes = NULL;
    size_t n = 0;
    if (!result)
      result = read_bytes(temp, &bytes, &n);
    if (!result && !payload_valid(bytes, n))
      result = LEMON_SAVE_INVALID;
    free(bytes);
    if (!result)
      result = copy_backup(writer_directory, leaves[1]);
    if (!result && rename(temp, current))
      result = LEMON_SAVE_IO;
    latest.result = result;
    latest.revision++;
  }
  if (!commit || result)
    unlink(temp);
  pthread_mutex_unlock(&save_lock);
  return commit && !result;
}
int lemon_save_export(const char *dir, const char *archive, unsigned source) {
  if (source > 2)
    return LEMON_SAVE_INVALID;
  pthread_mutex_lock(&save_lock);
  char path[4096];
  filename(path, dir, leaves[source]);
  unsigned char *payload = NULL;
  size_t n = 0;
  int result = read_bytes(path, &payload, &n);
  if (!result && !payload_valid(payload, n))
    result = LEMON_SAVE_INVALID;
  if (!result) {
    unsigned char *bytes = malloc(n + 16);
    if (!bytes)
      result = LEMON_SAVE_IO;
    else {
      memcpy(bytes, "LEMONSV1", 8);
      put32(bytes + 8, n);
      put32(bytes + 12, checksum(payload, n));
      memcpy(bytes + 16, payload, n);
      result = atomic_bytes(archive, bytes, n + 16);
      free(bytes);
    }
  }
  free(payload);
  pthread_mutex_unlock(&save_lock);
  return result;
}
int lemon_save_validate(const char *archive) {
  unsigned char *bytes = NULL;
  size_t n = 0;
  int result = read_archive(archive, &bytes, &n);
  free(bytes);
  return result;
}
int lemon_save_import(const char *dir, const char *archive) {
  unsigned char *bytes = NULL;
  size_t n = 0;
  int result = read_archive(archive, &bytes, &n);
  if (result)
    return result;
  pthread_mutex_lock(&save_lock);
  if (running || writer)
    result = LEMON_SAVE_BUSY;
  else {
    char current[4096];
    filename(current, dir, leaves[0]);
    result = copy_backup(dir, leaves[2]);
    if (!result)
      result = atomic_bytes(current, bytes + 16, n - 16);
    latest.result = result;
    latest.revision++;
  }
  pthread_mutex_unlock(&save_lock);
  free(bytes);
  return result;
}
