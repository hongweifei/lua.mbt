/*
 * stub.c -- host interface layer for the MoonBit Lua interpreter.
 *
 * The interpreter core is written in MoonBit.  Everything that needs the host
 * operating system (buffered streams, files, the clock, the environment, process
 * control, printf-compatible number formatting and a decent PRNG) is funnelled
 * through the wrappers below.  This mirrors the role that the C standard library
 * plays for the reference implementation of Lua.
 *
 * Conventions used throughout this file:
 *   - Handles to C objects (FILE *) are passed to MoonBit as int64_t.  The
 *     enclosed pointer is never dereferenced by MoonBit, and 0 means "no object".
 *   - MoonBit `Bytes` is passed as `moonbit_bytes_t`, a NUL terminated mutable
 *     byte buffer.  Buffers that C fills in are always length checked.
 *   - Functions that can fail return an int32_t status (< 0 on failure) and
 *     report the precise reason through a MoonBit-provided out-buffer.
 */

#define _CRT_SECURE_NO_WARNINGS

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <errno.h>
#include <locale.h>

#include <moonbit.h>

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <io.h>
#define MBT_POPEN _popen
#define MBT_PCLOSE _pclose
#define MBT_FILENO _fileno
#else
#include <unistd.h>
#define MBT_POPEN popen
#define MBT_PCLOSE pclose
#define MBT_FILENO fileno
#endif

#define MBT_EXPORT MOONBIT_FFI_EXPORT

/* ------------------------------------------------------------------ */
/* little endian encoding helpers (endianness independent on both ends) */
/* ------------------------------------------------------------------ */

static void mbt_put_i32(uint8_t *p, int32_t v) {
  p[0] = (uint8_t)(v & 0xff);
  p[1] = (uint8_t)((v >> 8) & 0xff);
  p[2] = (uint8_t)((v >> 16) & 0xff);
  p[3] = (uint8_t)((v >> 24) & 0xff);
}

static void mbt_put_i64(uint8_t *p, int64_t v) {
  mbt_put_i32(p, (int32_t)(v & 0xffffffffLL));
  mbt_put_i32(p + 4, (int32_t)((v >> 32) & 0xffffffffLL));
}

/* ------------------------------------------------------------------ */
/* printf compatible formatting                                        */
/* ------------------------------------------------------------------ */

/*
 * Lua delegates the conversion of numbers inside string.format to the host
 * printf.  Doing the same guarantees bit-for-bit identical results for %d, %x,
 * %o, %f, %e, %g, %a and every flag/width/precision combination.
 * The format string is assembled by the MoonBit side (which inserts the proper
 * length modifier), so each entry point only has to name the argument type.
 */

MBT_EXPORT int32_t
lua_mbt_fmt_double(moonbit_bytes_t buf, int32_t n, moonbit_bytes_t fmt, double v) {
  int r = snprintf((char *)buf, (size_t)n, (const char *)fmt, v);
  return (int32_t)r;
}

MBT_EXPORT int32_t
lua_mbt_fmt_int64(moonbit_bytes_t buf, int32_t n, moonbit_bytes_t fmt, int64_t v) {
  int r = snprintf((char *)buf, (size_t)n, (const char *)fmt, (long long)v);
  return (int32_t)r;
}

MBT_EXPORT int32_t
lua_mbt_fmt_uint64(moonbit_bytes_t buf, int32_t n, moonbit_bytes_t fmt, uint64_t v) {
  int r = snprintf((char *)buf, (size_t)n, (const char *)fmt, (unsigned long long)v);
  return (int32_t)r;
}

MBT_EXPORT int32_t
lua_mbt_fmt_int(moonbit_bytes_t buf, int32_t n, moonbit_bytes_t fmt, int32_t v) {
  int r = snprintf((char *)buf, (size_t)n, (const char *)fmt, (int)v);
  return (int32_t)r;
}

MBT_EXPORT int32_t
lua_mbt_fmt_cstr(moonbit_bytes_t buf, int32_t n, moonbit_bytes_t fmt, moonbit_bytes_t s) {
  int r = snprintf((char *)buf, (size_t)n, (const char *)fmt, (const char *)s);
  return (int32_t)r;
}

/* ------------------------------------------------------------------ */
/* numeral conversion                                                  */
/* ------------------------------------------------------------------ */

/*
 * Lua converts numerals with the host's strtod, which handles decimal and
 * hexadecimal floats with correct rounding and saturates to infinity on
 * overflow.  The MoonBit side validates the syntax and rejects the spellings
 * Lua rejects ("inf", "nan"), so a failed conversion here is unreachable.
 */
MBT_EXPORT double lua_mbt_strtod(moonbit_bytes_t s, int32_t len) {
  char tmp[512];
  if (len < 0) {
    len = 0;
  }
  if (len > (int32_t)sizeof(tmp) - 1) {
    len = (int32_t)sizeof(tmp) - 1;
  }
  memcpy(tmp, (const char *)s, (size_t)len);
  tmp[len] = 0;
  return strtod(tmp, NULL);
}

/* ------------------------------------------------------------------ */
/* standard streams and files                                          */
/* ------------------------------------------------------------------ */

MBT_EXPORT int64_t lua_mbt_stdin(void) {
  return (int64_t)(intptr_t)stdin;
}

/* Whether standard input is a terminal.  The stand-alone interpreter asks so
 * that it starts the read-eval-print loop only for a person, and reads a file
 * otherwise (`lua_stdin_is_tty`). */
MBT_EXPORT int32_t lua_mbt_stdin_is_tty(void) {
#if defined(_WIN32)
  return (int32_t)(_isatty(_fileno(stdin)) != 0);
#else
  return (int32_t)(isatty(fileno(stdin)) != 0);
#endif
}

MBT_EXPORT int64_t lua_mbt_stdout(void) {
  return (int64_t)(intptr_t)stdout;
}

MBT_EXPORT int64_t lua_mbt_stderr(void) {
  return (int64_t)(intptr_t)stderr;
}

MBT_EXPORT int64_t lua_mbt_fopen(moonbit_bytes_t path, moonbit_bytes_t mode) {
  FILE *f = fopen((const char *)path, (const char *)mode);
  return (int64_t)(intptr_t)f;
}

MBT_EXPORT int32_t lua_mbt_fclose(int64_t h) {
  FILE *f = (FILE *)(intptr_t)h;
  if (f == NULL) {
    return -1;
  }
  return (int32_t)fclose(f);
}

MBT_EXPORT int32_t lua_mbt_fflush(int64_t h) {
  if (h == 0) {
    /* fflush(NULL) flushes every open output stream. */
    return (int32_t)fflush(NULL);
  }
  return (int32_t)fflush((FILE *)(intptr_t)h);
}

/* Returns the number of bytes actually read; 0 on end of file, -1 on error. */
MBT_EXPORT int32_t lua_mbt_fread(int64_t h, moonbit_bytes_t buf, int32_t len) {
  FILE *f = (FILE *)(intptr_t)h;
  size_t got;
  if (f == NULL || len <= 0) {
    return 0;
  }
  got = fread((void *)buf, 1, (size_t)len, f);
  if (got == 0 && ferror(f)) {
    return -1;
  }
  return (int32_t)got;
}

MBT_EXPORT int32_t lua_mbt_fwrite(int64_t h, moonbit_bytes_t buf, int32_t len) {
  FILE *f = (FILE *)(intptr_t)h;
  size_t put;
  if (f == NULL) {
    return -1;
  }
  if (len <= 0) {
    return 0;
  }
  put = fwrite((const void *)buf, 1, (size_t)len, f);
  return (int32_t)put;
}

MBT_EXPORT double lua_mbt_fseek(int64_t h, int64_t off, int32_t whence) {
  FILE *f = (FILE *)(intptr_t)h;
  if (f == NULL) {
    return -1.0;
  }
  if (fseek(f, (long)off, (int)whence) != 0) {
    return -1.0;
  }
  return 0.0;
}

MBT_EXPORT int64_t lua_mbt_ftell(int64_t h) {
  FILE *f = (FILE *)(intptr_t)h;
  long p;
  if (f == NULL) {
    return -1;
  }
  p = ftell(f);
  return (int64_t)p;
}

MBT_EXPORT int32_t lua_mbt_feof(int64_t h) {
  return (int32_t)feof((FILE *)(intptr_t)h);
}

MBT_EXPORT int32_t lua_mbt_ferror(int64_t h) {
  return (int32_t)ferror((FILE *)(intptr_t)h);
}

MBT_EXPORT void lua_mbt_clearerr(int64_t h) {
  clearerr((FILE *)(intptr_t)h);
}

/* Returns the byte read, or -1 on end of file. */
MBT_EXPORT int32_t lua_mbt_fgetc(int64_t h) {
  int c = fgetc((FILE *)(intptr_t)h);
  return (int32_t)c;
}

MBT_EXPORT int32_t lua_mbt_ungetc(int32_t c, int64_t h) {
  return (int32_t)ungetc((int)c, (FILE *)(intptr_t)h);
}

/* Reads one line into buf, stopping after '\n'.  Returns the length, 0 at end
 * of file, or -1 when the line does not fit (buf is filled but not terminated
 * by a newline).  A trailing NUL is always written. */
MBT_EXPORT int32_t lua_mbt_fgets(int64_t h, moonbit_bytes_t buf, int32_t len) {
  FILE *f = (FILE *)(intptr_t)h;
  int32_t i = 0;
  int c;
  if (f == NULL || len <= 1) {
    return 0;
  }
  while (i < len - 1) {
    c = fgetc(f);
    if (c == EOF) {
      break;
    }
    buf[i++] = (uint8_t)c;
    if (c == '\n') {
      break;
    }
  }
  buf[i] = 0;
  if (i == len - 1 && buf[i - 1] != '\n') {
    return -1;
  }
  return i;
}

MBT_EXPORT int32_t lua_mbt_remove(moonbit_bytes_t path) {
  return (int32_t)remove((const char *)path);
}

MBT_EXPORT int32_t lua_mbt_rename(moonbit_bytes_t from, moonbit_bytes_t to) {
  return (int32_t)rename((const char *)from, (const char *)to);
}

MBT_EXPORT int64_t lua_mbt_tmpfile(void) {
  FILE *f = tmpfile();
  return (int64_t)(intptr_t)f;
}

MBT_EXPORT int64_t lua_mbt_popen(moonbit_bytes_t cmd, moonbit_bytes_t mode) {
  FILE *f = MBT_POPEN((const char *)cmd, (const char *)mode);
  return (int64_t)(intptr_t)f;
}

MBT_EXPORT int32_t lua_mbt_pclose(int64_t h) {
  return (int32_t)MBT_PCLOSE((FILE *)(intptr_t)h);
}

MBT_EXPORT int32_t lua_mbt_setvbuf(int64_t h, int32_t mode, int32_t size) {
  int m = _IOFBF;
  if (mode == 1) {
    m = _IOLBF;
  } else if (mode == 2) {
    m = _IONBF;
  }
  return (int32_t)setvbuf((FILE *)(intptr_t)h, NULL, m, (size_t)size);
}

MBT_EXPORT int32_t lua_mbt_fileno(int64_t h) {
  return (int32_t)MBT_FILENO((FILE *)(intptr_t)h);
}

MBT_EXPORT int32_t lua_mbt_errno(void) {
  return (int32_t)errno;
}

MBT_EXPORT void lua_mbt_set_errno(int32_t e) {
  errno = (int)e;
}

/* Writes the message for errno `e` into buf (NUL terminated) and returns its
 * length.  `n` must be at least 1. */
MBT_EXPORT int32_t lua_mbt_strerror(int32_t e, moonbit_bytes_t buf, int32_t n) {
  char tmp[256];
  size_t need;
  if (n <= 0) {
    return 0;
  }
  tmp[0] = 0;
#if defined(_WIN32)
  strerror_s(tmp, sizeof(tmp), (int)e);
#else
  {
    const char *m = strerror((int)e);
    if (m != NULL) {
      strncpy(tmp, m, sizeof(tmp) - 1);
      tmp[sizeof(tmp) - 1] = 0;
    }
  }
#endif
  need = strlen(tmp);
  if ((int32_t)need >= n) {
    need = (size_t)(n - 1);
  }
  memcpy(buf, tmp, need);
  buf[need] = 0;
  return (int32_t)need;
}

/* Suggests a file name for a temporary file into buf. */
MBT_EXPORT int64_t lua_mbt_tmpnam(moonbit_bytes_t buf, int32_t n) {
  char tmp[512];
  char *p;
  size_t len;
  if (n <= 1) {
    return 0;
  }
  p = tmpnam(tmp);
  if (p == NULL) {
    return 0;
  }
  len = strlen(tmp);
  if ((int32_t)len >= n) {
    len = (size_t)(n - 1);
  }
  memcpy(buf, tmp, len);
  buf[len] = 0;
  return (int64_t)1;
}

/* ------------------------------------------------------------------ */
/* clock, calendar and locale                                          */
/* ------------------------------------------------------------------ */

MBT_EXPORT int64_t lua_mbt_time(void) {
  return (int64_t)time(NULL);
}

/* Processor time consumed so far, in seconds. */
MBT_EXPORT double lua_mbt_clock(void) {
  return (double)clock() / (double)CLOCKS_PER_SEC;
}

MBT_EXPORT double lua_mbt_diff_seconds(int64_t a, int64_t b) {
  return difftime((time_t)a, (time_t)b);
}

static struct tm *mbt_localtime(int64_t t, struct tm *out) {
  time_t tt = (time_t)t;
#if defined(_WIN32)
  if (localtime_s(out, &tt) != 0) {
    return NULL;
  }
  return out;
#else
  return localtime_r(&tt, out);
#endif
}

static struct tm *mbt_gmtime(int64_t t, struct tm *out) {
  time_t tt = (time_t)t;
#if defined(_WIN32)
  if (gmtime_s(out, &tt) != 0) {
    return NULL;
  }
  return out;
#else
  return gmtime_r(&tt, out);
#endif
}

/*
 * Breaks a timestamp into the nine fields of `struct tm`, written to `out` as
 * little endian int32 in this order:
 *   year (full), month (1-12), day (1-31), hour (0-23), minute (0-59),
 *   second (0-61), weekday (1-7, Sunday == 1), day of year (1-366), isdst
 * `islocal` selects local time instead of UTC.  `out` must hold 36 bytes.
 * Returns 0 on success, -1 when the timestamp cannot be represented.
 */
MBT_EXPORT int32_t
lua_mbt_tm_breakdown(int64_t t, int32_t islocal, moonbit_bytes_t out) {
  struct tm tmv;
  struct tm *p = islocal ? mbt_localtime(t, &tmv) : mbt_gmtime(t, &tmv);
  if (p == NULL) {
    return -1;
  }
  mbt_put_i32(out + 0, (int32_t)(p->tm_year + 1900));
  mbt_put_i32(out + 4, (int32_t)(p->tm_mon + 1));
  mbt_put_i32(out + 8, (int32_t)p->tm_mday);
  mbt_put_i32(out + 12, (int32_t)p->tm_hour);
  mbt_put_i32(out + 16, (int32_t)p->tm_min);
  mbt_put_i32(out + 20, (int32_t)p->tm_sec);
  mbt_put_i32(out + 24, (int32_t)p->tm_wday + 1);
  mbt_put_i32(out + 28, (int32_t)p->tm_yday + 1);
  mbt_put_i32(out + 32, (int32_t)(p->tm_isdst > 0));
  return 0;
}

/* Formats a timestamp with strftime.  Returns the length written (-1 on
 * overflow), or -2 when the timestamp is out of range. */
MBT_EXPORT int32_t
lua_mbt_strftime_time(
  moonbit_bytes_t buf,
  int32_t n,
  moonbit_bytes_t fmt,
  int64_t t,
  int32_t islocal
) {
  struct tm tmv;
  struct tm *p = islocal ? mbt_localtime(t, &tmv) : mbt_gmtime(t, &tmv);
  size_t r;
  if (p == NULL) {
    return -2;
  }
  if (n <= 1) {
    return -1;
  }
  r = strftime((char *)buf, (size_t)n, (const char *)fmt, p);
  if (r == 0) {
    return -1;
  }
  return (int32_t)r;
}

/* Builds a timestamp from the nine `struct tm` fields.  Fields outside their
 * normal range are normalised exactly like mktime does.  `islocal` selects
 * local time (mktime) instead of UTC (timegm).  Returns -1 on failure. */
MBT_EXPORT int64_t lua_mbt_time_make(
  int32_t year,
  int32_t month,
  int32_t day,
  int32_t hour,
  int32_t min,
  int32_t sec,
  int32_t isdst,
  int32_t islocal
) {
  struct tm tmv;
  time_t r;
  memset(&tmv, 0, sizeof(tmv));
  tmv.tm_year = (int)year - 1900;
  tmv.tm_mon = (int)month - 1;
  tmv.tm_mday = (int)day;
  tmv.tm_hour = (int)hour;
  tmv.tm_min = (int)min;
  tmv.tm_sec = (int)sec;
  tmv.tm_isdst = (int)isdst;
  if (islocal) {
    r = mktime(&tmv);
  } else {
#if defined(_WIN32)
    r = _mkgmtime(&tmv);
#else
    r = timegm(&tmv);
#endif
  }
  if (r == (time_t)-1) {
    return -1;
  }
  return (int64_t)r;
}

/* Difference in seconds between local time and UTC at timestamp `t`. */
MBT_EXPORT int32_t lua_mbt_tz_offset(int64_t t) {
  struct tm lt;
  struct tm gt;
  time_t tt = (time_t)t;
  int64_t l;
  int64_t g;
  if (mbt_localtime(t, &lt) == NULL || mbt_gmtime(t, &gt) == NULL) {
    return 0;
  }
  /* mktime interprets the broken down UTC fields as if they were local, which
   * yields exactly the offset. */
  lt.tm_isdst = -1;
#if defined(_WIN32)
  l = (int64_t)mktime(&lt);
  g = (int64_t)_mkgmtime(&gt);
#else
  l = (int64_t)mktime(&lt);
  g = (int64_t)timegm(&gt);
#endif
  (void)tt;
  return (int32_t)difftime((time_t)l, (time_t)g);
}

MBT_EXPORT int32_t lua_mbt_isdst(int64_t t) {
  struct tm tmv;
  if (mbt_localtime(t, &tmv) == NULL) {
    return 0;
  }
  return (int32_t)(tmv.tm_isdst > 0);
}

/* Copies the current locale name into buf, returning its length. */
MBT_EXPORT int32_t lua_mbt_getlocale(moonbit_bytes_t buf, int32_t n) {
  const char *l = setlocale(LC_ALL, NULL);
  size_t len;
  if (l == NULL) {
    l = "C";
  }
  len = strlen(l);
  if ((int32_t)len >= n) {
    len = (size_t)(n - 1);
  }
  memcpy(buf, l, len);
  buf[len] = 0;
  return (int32_t)len;
}

/* Lua's categories are the same numbers as the C ones for LC_* on every
 * supported platform except LC_ALL, which is handled by the caller. */
MBT_EXPORT int32_t lua_mbt_setlocale(moonbit_bytes_t locale, int32_t category) {
  const char *l = setlocale(category, (const char *)locale);
  return l == NULL ? 0 : 1;
}

/* The first byte of the current locale's decimal point, as 'l_str2d' in
 * lobject.c consults it.  Returns '.' when localeconv gives nothing. */
MBT_EXPORT int32_t lua_mbt_locale_decpoint(void) {
  struct lconv *lcp = localeconv();
  if (lcp != NULL && lcp->decimal_point != NULL && lcp->decimal_point[0] != '\0')
    return (unsigned char)lcp->decimal_point[0];
  return '.';
}

/* String ordering, exactly as the VM does it: 'strcmp', which follows the
 * locale's collation sequence and stops at the first zero byte. */
MBT_EXPORT int32_t lua_mbt_strcmp(moonbit_bytes_t a, moonbit_bytes_t b) {
  return strcmp((const char *)a, (const char *)b);
}

/* Mirrors 'l_strcmp' from lvm.c: compares segment by segment with 'strcoll',
 * continuing past embedded zero bytes. */
MBT_EXPORT int32_t lua_mbt_lstrcmp(moonbit_bytes_t a, int32_t la,
                                   moonbit_bytes_t b, int32_t lb) {
  const char *s1 = (const char *)a;
  const char *s2 = (const char *)b;
  size_t rl1 = (size_t)la, rl2 = (size_t)lb;
  for (;;) {
    int temp = strcoll(s1, s2);
    if (temp != 0) return temp;
    else {
      size_t zl1 = strlen(s1), zl2 = strlen(s2);
      if (zl2 == rl2) return (zl1 == rl1) ? 0 : 1;
      else if (zl1 == rl1) return -1;
      zl1++; zl2++;
      s1 += zl1; rl1 -= zl1;
      s2 += zl2; rl2 -= zl2;
    }
  }
}

/* ------------------------------------------------------------------ */
/* environment and process control                                     */
/* ------------------------------------------------------------------ */

/* Returns the length of the value, or -1 when the variable is unset.  When the
 * value does not fit, the required length is returned and nothing is written. */
MBT_EXPORT int32_t lua_mbt_getenv(moonbit_bytes_t name, moonbit_bytes_t buf, int32_t n) {
  const char *v = getenv((const char *)name);
  size_t len;
  if (v == NULL) {
    return -1;
  }
  len = strlen(v);
  if ((int32_t)len >= n) {
    return (int32_t)len + 1;
  }
  memcpy(buf, v, len);
  buf[len] = 0;
  return (int32_t)len;
}

MBT_EXPORT int32_t
lua_mbt_setenv(moonbit_bytes_t name, moonbit_bytes_t value, int32_t overwrite) {
#if defined(_WIN32)
  if (!overwrite && getenv((const char *)name) != NULL) {
    return 0;
  }
  return _putenv_s((const char *)name, (const char *)value);
#else
  return setenv((const char *)name, (const char *)value, (int)overwrite);
#endif
}

MBT_EXPORT int32_t lua_mbt_unsetenv(moonbit_bytes_t name) {
#if defined(_WIN32)
  return _putenv_s((const char *)name, "");
#else
  return unsetenv((const char *)name);
#endif
}

MBT_EXPORT int32_t lua_mbt_system(moonbit_bytes_t cmd) {
  return (int32_t)system((const char *)cmd);
}

/* The `system(NULL)` question: is there a command processor at all?  Lua asks
 * it for `os.execute()` with no command, where an empty string would instead
 * run one. */
MBT_EXPORT int32_t lua_mbt_system_available(void) {
  return (int32_t)(system(NULL) != 0);
}

/* Whether the host is Windows.  The package library asks, because the reference
 * picks its default path templates and its directory separator with this very
 * condition (`_WIN32` in luaconf.h). */
MBT_EXPORT int32_t lua_mbt_is_windows(void) {
#if defined(_WIN32)
  return 1;
#else
  return 0;
#endif
}

/* The directory holding the running executable, without a trailing separator.
 * This is what the reference's `setprogdir` puts in place of every '!' of a
 * path template.  Returns the length written, or -1 when it cannot be found;
 * a buffer that is too small returns the length the answer needs. */
MBT_EXPORT int32_t lua_mbt_exec_dir(moonbit_bytes_t buf, int32_t n) {
  char path[4096];
  size_t len;
#if defined(_WIN32)
  {
    DWORD got = GetModuleFileNameA(NULL, path, (DWORD)sizeof(path));
    char *slash;
    if (got == 0 || got >= (DWORD)sizeof(path)) return -1;
    slash = strrchr(path, '\\');
    if (slash == NULL) return -1;
    len = (size_t)(slash - path);
  }
#else
  {
    ssize_t got = readlink("/proc/self/exe", path, sizeof(path) - 1);
    char *slash;
    if (got <= 0) return -1;
    path[got] = '\0';
    slash = strrchr(path, '/');
    if (slash == NULL) return -1;
    len = (size_t)(slash - path);
  }
#endif
  if ((int32_t)len >= n) return (int32_t)len + 1;
  memcpy(buf, path, len);
  buf[len] = 0;
  return (int32_t)len;
}

MBT_EXPORT void lua_mbt_exit(int32_t code) {
  fflush(NULL);
  exit((int)code);
}

/* ------------------------------------------------------------------ */
/* pseudo random numbers (xoshiro256**, as in the reference)           */
/* ------------------------------------------------------------------ */

static uint64_t mbt_rng_state[4];
static int mbt_rng_initialised = 0;

static uint64_t mbt_rotl(uint64_t x, int k) {
  return (x << k) | (x >> (64 - k));
}

/* The generator step: `nextrand` in lmathlib.c. */
static uint64_t mbt_rng_advance(void) {
  uint64_t result, t;
  result = mbt_rotl(mbt_rng_state[1] * 5, 7) * 9;
  t = mbt_rng_state[1] << 17;
  mbt_rng_state[2] ^= mbt_rng_state[0];
  mbt_rng_state[3] ^= mbt_rng_state[1];
  mbt_rng_state[1] ^= mbt_rng_state[2];
  mbt_rng_state[0] ^= mbt_rng_state[3];
  mbt_rng_state[2] ^= t;
  mbt_rng_state[3] = mbt_rotl(mbt_rng_state[3], 45);
  return result;
}

MBT_EXPORT void lua_mbt_rng_seed(uint64_t n1, uint64_t n2) {
  int i;
  /* `setseed` in the reference: the two seeds with a constant in between, so
     that the state is never zero, then sixteen steps to spread them. */
  mbt_rng_state[0] = n1;
  mbt_rng_state[1] = UINT64_C(0xff);
  mbt_rng_state[2] = n2;
  mbt_rng_state[3] = 0;
  mbt_rng_initialised = 1;
  for (i = 0; i < 16; i++)
    mbt_rng_advance();
}

MBT_EXPORT uint64_t lua_mbt_rng_time_seed(void) {
  return (uint64_t)time(NULL);
}

MBT_EXPORT uint64_t lua_mbt_rng_addr_seed(void) {
  /* The reference uses the address of the state, which a system with address
     space layout randomization changes from run to run. */
  return (uint64_t)(uintptr_t)mbt_rng_state;
}

MBT_EXPORT uint64_t lua_mbt_rng_next(void) {
  if (!mbt_rng_initialised) {
    lua_mbt_rng_seed(lua_mbt_rng_time_seed(), lua_mbt_rng_addr_seed());
  }
  return mbt_rng_advance();
}

/* ------------------------------------------------------------------ */
/* locale-dependent character classes                                  */
/* ------------------------------------------------------------------ */

/* `which` selects the class: 0 isalpha, 1 iscntrl, 2 isdigit, 3 isgraph,
 * 4 islower, 5 isprint, 6 ispunct, 7 isspace, 8 isupper, 9 isxdigit,
 * 10 isalnum.  `c` must be an unsigned char value or EOF. */
MBT_EXPORT int32_t lua_mbt_ctype(int32_t which, int32_t c) {
  switch (which) {
    case 0: return isalpha(c);
    case 1: return iscntrl(c);
    case 2: return isdigit(c);
    case 3: return isgraph(c);
    case 4: return islower(c);
    case 5: return isprint(c);
    case 6: return ispunct(c);
    case 7: return isspace(c);
    case 8: return isupper(c);
    case 9: return isxdigit(c);
    default: return isalnum(c);
  }
}

/* Locale-aware single-byte case mapping, as the string library's
 * `str_upper`/`str_lower` apply per byte. */
MBT_EXPORT int32_t lua_mbt_toupper32(int32_t c) { return toupper(c); }
MBT_EXPORT int32_t lua_mbt_tolower32(int32_t c) { return tolower(c); }
