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

/* `pthread_getattr_np`, which says where this thread's stack is, is a GNU
 * extension: it is declared only when this is defined before <pthread.h>. */
#if !defined(_WIN32) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE
#endif

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <errno.h>
#include <locale.h>
/* The character classes `lua_mbt_ctype` asks about.  MSVC pulls these in with
 * its other headers; the C library elsewhere wants the header named. */
#include <ctype.h>

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
#include <dlfcn.h>
#include <pthread.h>
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
/* byte search                                                         */
/* ------------------------------------------------------------------ */

/*
 * The reference implementation searches for a plain pattern with the C
 * library's `memchr` and `memcmp` (`lmemfind` in lstrlib.c).  Those two
 * primitives are what the host hands over here, so the interpreter does not
 * have to walk its subject one byte at a time from MoonBit.
 */
MBT_EXPORT int64_t lua_mbt_memchr(moonbit_bytes_t s, int64_t from, int64_t len,
                                  int32_t byte) {
  const char *found;
  if (from < 0 || len <= 0) {
    return -1;
  }
  found = (const char *)memchr((const char *)s + from, byte, (size_t)len);
  if (found == NULL) {
    return -1;
  }
  return (int64_t)(found - (const char *)s);
}

MBT_EXPORT int32_t lua_mbt_memeq(moonbit_bytes_t a, int64_t ai,
                                 moonbit_bytes_t b, int64_t bi, int64_t len) {
  if (len <= 0) {
    return 1; /* nothing to compare counts as equal */
  }
  return memcmp((const char *)a + ai, (const char *)b + bi, (size_t)len) == 0
             ? 1
             : 0;
}

/* Copies `len` bytes from `src + si` to `dst + di`.  A byte sequence in MoonBit
 * is NUL terminated and is never written through an offset it was not made for,
 * so this is a `memcpy` of the range.  Pulling a substring of a string is the
 * one allocation-heavy operation in the string library, and a loop in the
 * language would be a call per byte. */
MBT_EXPORT void lua_mbt_bytes_copy(moonbit_bytes_t dst, int64_t di,
                                   moonbit_bytes_t src, int64_t si,
                                   int64_t len) {
  if (len > 0) {
    memcpy((char *)dst + di, (const char *)src + si, (size_t)len);
  }
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

#if defined(_WIN32)
/*
 * A file name in a Lua string is a byte string, but a Windows file name is
 * UTF-16.  A path that is valid UTF-8 is converted, which is what lets a name
 * outside the ANSI code page -- a Chinese one, say -- be opened.  A path that
 * is not valid UTF-8 (one in the ANSI code page) is left to the narrow API
 * below, so nothing that used to open stops opening.
 */
static wchar_t *mbt_wide_path(moonbit_bytes_t path) {
  int n;
  wchar_t *w;
  if (path == NULL) {
    return NULL;
  }
  n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, (const char *)path,
                          -1, NULL, 0);
  if (n <= 0) {
    return NULL;
  }
  w = (wchar_t *)malloc((size_t)n * sizeof(wchar_t));
  if (w == NULL) {
    return NULL;
  }
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, (const char *)path,
                          -1, w, n) <= 0) {
    free(w);
    return NULL;
  }
  return w;
}

/* A file mode is ASCII in every use here, so widening it is a copy. */
static int mbt_wide_mode(moonbit_bytes_t mode, wchar_t *out, size_t n) {
  size_t i = 0;
  if (mode == NULL) {
    return 0;
  }
  while (i + 1 < n && mode[i] != 0) {
    out[i] = (wchar_t)mode[i];
    i++;
  }
  out[i] = 0;
  return i > 0;
}
#endif

MBT_EXPORT int64_t lua_mbt_fopen(moonbit_bytes_t path, moonbit_bytes_t mode) {
#if defined(_WIN32)
  wchar_t wmode[8];
  wchar_t *wp = mbt_wide_path(path);
  if (wp != NULL && mbt_wide_mode(mode, wmode, 8)) {
    FILE *f = _wfopen(wp, wmode);
    free(wp);
    return (int64_t)(intptr_t)f;
  }
  free(wp);
#endif
  return (int64_t)(intptr_t)fopen((const char *)path, (const char *)mode);
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
#if defined(_WIN32)
  wchar_t *wp = mbt_wide_path(path);
  if (wp != NULL) {
    int r = _wremove(wp);
    free(wp);
    return (int32_t)r;
  }
#endif
  return (int32_t)remove((const char *)path);
}

MBT_EXPORT int32_t lua_mbt_rename(moonbit_bytes_t from, moonbit_bytes_t to) {
#if defined(_WIN32)
  wchar_t *wf = mbt_wide_path(from);
  wchar_t *wt = mbt_wide_path(to);
  if (wf != NULL && wt != NULL) {
    int r = _wrename(wf, wt);
    free(wf);
    free(wt);
    return (int32_t)r;
  }
  free(wf);
  free(wt);
#endif
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
/* dynamic libraries                                                   */
/* ------------------------------------------------------------------ */

/*
 * The reference asks the host loader for a shared library, takes the
 * `lua_CFunction` named there and calls it.  This build can ask -- and does, so
 * that `package.loadlib` and the native searcher report the loader's own reason
 * rather than a made-up one -- but it cannot enter the function it found: MoonBit
 * binds a C symbol by name at compile time and the runtime gives no way to call a
 * pointer read out of a library at run time.  So these four wrappers stop at
 * "the file opened" and "the symbol is there"; see the note in README's list of
 * differences.
 *
 * The loader's complaint is saved here instead of being fetched by a second call
 * from MoonBit, because on Windows the value of `GetLastError` belongs to the
 * call that failed and anything MoonBit runs in between would overwrite it.  One
 * static buffer is enough: the interpreter drives one host thread, the same
 * assumption `errno` and the PRNG state above are written under.
 */

#define MBT_DL_ERR_MAX 512
static char mbt_dl_err[MBT_DL_ERR_MAX];

static void mbt_dl_seterr(const char *msg) {
  size_t n = strlen(msg);
  if (n >= MBT_DL_ERR_MAX) {
    n = MBT_DL_ERR_MAX - 1;
  }
  memcpy(mbt_dl_err, msg, n);
  mbt_dl_err[n] = 0;
}

/* A loader message rarely ends without a newline, and ours is going into the
 * middle of a line in `require`'s report, so it comes off here. */
static void mbt_dl_trim(char *s) {
  size_t n = strlen(s);
  while (n > 0 && (s[n - 1] == '\n' || s[n - 1] == '\r')) {
    s[--n] = 0;
  }
}

#if defined(_WIN32)
/* The reference's `pusherror`: the text the system attaches to the error code,
 * with the code after it. */
static void mbt_dl_seterr_os(void) {
  DWORD err = GetLastError();
  char msg[256];
  char line[MBT_DL_ERR_MAX];
  DWORD got = FormatMessageA(
      FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS, NULL, err, 0,
      msg, (DWORD)sizeof(msg) - 1, NULL);
  if (got == 0) {
    snprintf(line, sizeof(line), "unknown error (system error %lu)",
             (unsigned long)err);
  } else {
    msg[got] = 0;
    mbt_dl_trim(msg);
    snprintf(line, sizeof(line), "%s (system error %lu)", msg,
             (unsigned long)err);
  }
  mbt_dl_seterr(line);
}

MBT_EXPORT int64_t lua_mbt_dl_open(moonbit_bytes_t path) {
  /* `LOAD_WITH_ALTERED_SEARCH_PATH` is what makes a library in the same
   * directory as this one find its own dependencies, the way `dlopen` does with
   * a path. */
  HMODULE lib = LoadLibraryExA((const char *)path, NULL,
                               LOAD_WITH_ALTERED_SEARCH_PATH);
  if (lib == NULL) {
    mbt_dl_seterr_os();
  }
  return (int64_t)(intptr_t)lib;
}

MBT_EXPORT int64_t lua_mbt_dl_sym(int64_t h, moonbit_bytes_t name) {
  FARPROC p = GetProcAddress((HMODULE)(intptr_t)h, (const char *)name);
  if (p == NULL) {
    /* The reference's `pusherror`: the reason is the system's own text, not a
     * sentence about the name that was asked for.  `require` puts this in the
     * middle of its report, and a message naming the entry there would be this
     * build's invention -- the reference never prints an entry name. */
    mbt_dl_seterr_os();
  }
  return (int64_t)(intptr_t)p;
}

MBT_EXPORT int32_t lua_mbt_dl_close(int64_t h) {
  return (int32_t)(FreeLibrary((HMODULE)(intptr_t)h) ? 0 : -1);
}
#else
MBT_EXPORT int64_t lua_mbt_dl_open(moonbit_bytes_t path) {
  /* `RTLD_LOCAL`, like the reference for a library it is only looking into. */
  void *lib = dlopen((const char *)path, RTLD_NOW | RTLD_LOCAL);
  if (lib == NULL) {
    const char *e = dlerror();
    char line[MBT_DL_ERR_MAX];
    snprintf(line, sizeof(line), "%s", e != NULL ? e : "cannot open library");
    mbt_dl_trim(line);
    mbt_dl_seterr(line);
  }
  return (int64_t)(intptr_t)lib;
}

MBT_EXPORT int64_t lua_mbt_dl_sym(int64_t h, moonbit_bytes_t name) {
  void *p;
  const char *e;
  char line[MBT_DL_ERR_MAX];
  dlerror(); /* clear a message a previous call left standing */
  p = dlsym((void *)(intptr_t)h, (const char *)name);
  e = dlerror();
  if (p == NULL || e != NULL) {
    if (e != NULL) {
      snprintf(line, sizeof(line), "%s", e);
    } else {
      snprintf(line, sizeof(line), "'%s' not found", (const char *)name);
    }
    mbt_dl_trim(line);
    mbt_dl_seterr(line);
    return 0;
  }
  return (int64_t)(intptr_t)p;
}

MBT_EXPORT int32_t lua_mbt_dl_close(int64_t h) {
  return (int32_t)dlclose((void *)(intptr_t)h);
}
#endif

/* Copies what the last failure said into `buf`, NUL terminates it and returns
 * its length.  It empties the saved message, so a later call after a success
 * says nothing rather than repeating an old complaint. */
MBT_EXPORT int32_t lua_mbt_dl_error(moonbit_bytes_t buf, int32_t n) {
  int32_t len = (int32_t)strlen(mbt_dl_err);
  if (n <= 0) {
    return 0;
  }
  if (len >= n) {
    len = n - 1;
  }
  memcpy(buf, mbt_dl_err, (size_t)len);
  buf[len] = 0;
  mbt_dl_err[0] = 0;
  return len;
}

/* ------------------------------------------------------------------ */
/* calling a function found in a library                               */
/* ------------------------------------------------------------------ */

/*
 * MoonBit can only call a C function whose *name* it bound at compile time, so a
 * pointer read out of a library at run time is unreachable from the language.  C
 * can call it -- but only through a pointer of the right shape, and every shape
 * has to exist in this file at compile time.  What follows is that set of shapes:
 * the smallest honest answer to "call a C function", and the reason
 * `package.loadc` names a shape it cannot call instead of guessing one.
 *
 * A shape is (return, arity, argument types), passed to the dispatcher as small
 * integer tags:
 *     return   0 void  1 int  2 int64  3 double  4 string (char *)
 *     argument 0 absent, 1 int  2 int64  3 double  4 string (const char *)
 * Arguments travel in two `int64` slots -- a `double` arrives as its IEEE bits --
 * plus the two possible string arguments as pointers, because MoonBit cannot hand
 * a `Bytes` over as an integer.  Only here does a tag say which slot means what,
 * and `MBT_IDX` is the single place an index is computed.
 *
 * What this cannot do, at any shape, is call a `lua_CFunction`: that needs the
 * callee to call back into the interpreter through a C API this build does not
 * export.  See the shared-library note in README.
 */

#define MBT_SHAPE_COUNT 375 /* 5 returns * 3 arities * 5 * 5 argument slots */
#define MBT_IDX(r, arity, t1, t2) (((r) * 3 + (arity)) * 25 + (t1) * 5 + (t2))

/* Reserved answers, only meaningful for a `string` return, whose real answer is a
 * length and so never negative. */
#define MBT_DL_NO_STRING -1  /* the C function answered with a null pointer */
#define MBT_DL_LONG -2       /* the string does not fit the buffer it was given */
#define MBT_DL_BAD_SHAPE -3  /* tags no shape was built for; see the note above */

typedef int64_t (*mbt_shape_fn)(
  int64_t fn, int64_t a0, int64_t a1, const char *s0, const char *s1, char *out,
  int32_t outn);

/* Bits both ways, with memcpy rather than a type pun. */
static double mbt_bits_to_double(int64_t v) {
  double d;
  memcpy(&d, &v, sizeof d);
  return d;
}

static int64_t mbt_double_to_bits(double d) {
  int64_t v;
  memcpy(&v, &d, sizeof v);
  return v;
}

/* Copy a NUL terminated result into the caller's buffer: its length, or one of
 * the reserved answers above. */
static int64_t mbt_put_cstr(const char *s, char *out, int32_t outn) {
  size_t n;
  if (s == NULL) {
    return MBT_DL_NO_STRING;
  }
  n = strlen(s);
  if ((size_t)outn <= n) {
    return MBT_DL_LONG;
  }
  memcpy(out, s, n);
  out[n] = 0;
  return (int64_t)n;
}

/* The C type behind each tag. */
#define MBT_RT_void void
#define MBT_RT_int int
#define MBT_RT_int64 int64_t
#define MBT_RT_double double
#define MBT_RT_string const char *
#define MBT_AT_int int
#define MBT_AT_int64 int64_t
#define MBT_AT_double double
#define MBT_AT_string const char *

/* The tag numbers, so a table row and its index cannot drift apart. */
#define MBT_TR_void 0
#define MBT_TR_int 1
#define MBT_TR_int64 2
#define MBT_TR_double 3
#define MBT_TR_string 4
#define MBT_TT_int 1
#define MBT_TT_int64 2
#define MBT_TT_double 3
#define MBT_TT_string 4

/* Reading an argument out of slot 0 / slot 1. */
#define MBT_L0_int ((int)a0)
#define MBT_L0_int64 a0
#define MBT_L0_double mbt_bits_to_double(a0)
#define MBT_L0_string s0
#define MBT_L1_int ((int)a1)
#define MBT_L1_int64 a1
#define MBT_L1_double mbt_bits_to_double(a1)
#define MBT_L1_string s1

/* What to do with the call's answer. */
#define MBT_SV_void(x) ((void)(x), (int64_t)0)
#define MBT_SV_int(x) ((int64_t)(x))
#define MBT_SV_int64(x) ((int64_t)(x))
#define MBT_SV_double(x) mbt_double_to_bits(x)
#define MBT_SV_string(x) mbt_put_cstr((x), out, outn)

/* Token pasting needs the extra round, because the pasted token is itself a
 * macro. */
#define MBT_CAT(a, b) a##b
#define MBT_RT(T) MBT_CAT(MBT_RT_, T)
#define MBT_AT(T) MBT_CAT(MBT_AT_, T)
#define MBT_L0(T) MBT_CAT(MBT_L0_, T)
#define MBT_L1(T) MBT_CAT(MBT_L1_, T)
#define MBT_ST(R) MBT_CAT(MBT_SV_, R)

#define MBT_SHAPE_ARGS                                                         \
  int64_t fn, int64_t a0, int64_t a1, const char *s0, const char *s1,         \
      char *out, int32_t outn

/* One function per shape.  `MBT_SHAPE_1` still declares slot 1 and the second
 * string unused: the shape says which of them the call reads. */
#define MBT_SHAPE_0(R)                                                         \
  static int64_t mbt_sh_0_##R(MBT_SHAPE_ARGS) {                                \
    MBT_RT(R)(*f)(void) = (MBT_RT(R)( * )(void))(void *)fn;                    \
    (void)a0;                                                                  \
    (void)a1;                                                                  \
    (void)s0;                                                                  \
    (void)s1;                                                                  \
    (void)out;                                                                 \
    (void)outn;                                                                \
    return MBT_ST(R)(f());                                                     \
  }

#define MBT_SHAPE_1(R, T1)                                                     \
  static int64_t mbt_sh_1_##R##_##T1(MBT_SHAPE_ARGS) {                         \
    MBT_RT(R)(*f)(MBT_AT(T1)) = (MBT_RT(R)( * )(MBT_AT(T1)))(void *)fn;        \
    (void)a1;                                                                  \
    (void)s1;                                                                  \
    (void)out;                                                                 \
    (void)outn;                                                                \
    return MBT_ST(R)(f(MBT_L0(T1)));                                           \
  }

#define MBT_SHAPE_2(R, T1, T2)                                                 \
  static int64_t mbt_sh_2_##R##_##T1##_##T2(MBT_SHAPE_ARGS) {                  \
    MBT_RT(R)(*f)(MBT_AT(T1), MBT_AT(T2)) =                                    \
        (MBT_RT(R)( * )(MBT_AT(T1), MBT_AT(T2)))(void *)fn;                    \
    return MBT_ST(R)(f(MBT_L0(T1), MBT_L1(T2)));                               \
  }

MBT_SHAPE_0(void) MBT_SHAPE_0(int) MBT_SHAPE_0(int64) MBT_SHAPE_0(double)
    MBT_SHAPE_0(string)

#define MBT_SHAPES_1(R)                                                        \
  MBT_SHAPE_1(R, int) MBT_SHAPE_1(R, int64) MBT_SHAPE_1(R, double)             \
      MBT_SHAPE_1(R, string)

MBT_SHAPES_1(void) MBT_SHAPES_1(int) MBT_SHAPES_1(int64) MBT_SHAPES_1(double)
    MBT_SHAPES_1(string)

#define MBT_SHAPES_2A(R, T1)                                                   \
  MBT_SHAPE_2(R, T1, int) MBT_SHAPE_2(R, T1, int64)                            \
      MBT_SHAPE_2(R, T1, double) MBT_SHAPE_2(R, T1, string)

#define MBT_SHAPES_2(R)                                                        \
  MBT_SHAPES_2A(R, int) MBT_SHAPES_2A(R, int64) MBT_SHAPES_2A(R, double)       \
      MBT_SHAPES_2A(R, string)

MBT_SHAPES_2(void) MBT_SHAPES_2(int) MBT_SHAPES_2(int64) MBT_SHAPES_2(double)
    MBT_SHAPES_2(string)

/* The table, each row naming the shape it answers for.  A slot left out is a
 * shape nothing can call, and the row is written from the same tags as the
 * function it points at, so the two cannot disagree. */
#define MBT_E0(R) [MBT_IDX(MBT_TR_##R, 0, 0, 0)] = mbt_sh_0_##R,
#define MBT_E1(R, T1)                                                          \
  [MBT_IDX(MBT_TR_##R, 1, MBT_TT_##T1, 0)] = mbt_sh_1_##R##_##T1,
#define MBT_E2(R, T1, T2)                                                      \
  [MBT_IDX(MBT_TR_##R, 2, MBT_TT_##T1, MBT_TT_##T2)] =                         \
      mbt_sh_2_##R##_##T1##_##T2,

#define MBT_ROW_1(R)                                                           \
  MBT_E1(R, int) MBT_E1(R, int64) MBT_E1(R, double) MBT_E1(R, string)

#define MBT_ROW_2A(R, T1)                                                      \
  MBT_E2(R, T1, int) MBT_E2(R, T1, int64) MBT_E2(R, T1, double)                \
      MBT_E2(R, T1, string)

#define MBT_ROW_2(R)                                                           \
  MBT_ROW_2A(R, int) MBT_ROW_2A(R, int64) MBT_ROW_2A(R, double)                \
      MBT_ROW_2A(R, string)

static const mbt_shape_fn mbt_shapes[MBT_SHAPE_COUNT] = {
  MBT_E0(void) MBT_E0(int) MBT_E0(int64) MBT_E0(double) MBT_E0(string)
      MBT_ROW_1(void) MBT_ROW_1(int) MBT_ROW_1(int64) MBT_ROW_1(double)
          MBT_ROW_1(string) MBT_ROW_2(void) MBT_ROW_2(int) MBT_ROW_2(int64)
              MBT_ROW_2(double) MBT_ROW_2(string)};

/*
 * Make the call the signature says.  The tags come from the declared signature,
 * which the Lua side parsed -- it owns "is this a shape that can be called", and
 * this owns calling it.  The answer is the integer or the bit pattern of the
 * double, by the declared return type; a `string` return is copied into `out`
 * and its length comes back instead.
 */
MBT_EXPORT int64_t lua_mbt_dl_call(int32_t ret, int32_t arity, int32_t t1,
                                   int32_t t2, int64_t fn, int64_t a0,
                                   int64_t a1, moonbit_bytes_t s0,
                                   moonbit_bytes_t s1, moonbit_bytes_t out,
                                   int32_t outn) {
  mbt_shape_fn f;
  if (ret < MBT_TR_void || ret > MBT_TR_string || arity < 0 || arity > 2) {
    return MBT_DL_BAD_SHAPE;
  }
  if (arity == 0 && (t1 != 0 || t2 != 0)) {
    return MBT_DL_BAD_SHAPE;
  }
  if (arity == 1 && t2 != 0) {
    return MBT_DL_BAD_SHAPE;
  }
  f = mbt_shapes[MBT_IDX(ret, arity, t1, t2)];
  if (f == NULL) {
    return MBT_DL_BAD_SHAPE;
  }
  return f(fn, a0, a1, (const char *)s0, (const char *)s1, (char *)out, outn);
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

/* ------------------------------------------------------------------ */
/* host stack                                                          */
/* ------------------------------------------------------------------ */

/* How much of the host stack is left below this call, in bytes, or -1 when the
 * host cannot say.  The interpreter re-enters itself once per host-to-Lua
 * callback, and each of those consumes host stack -- the one resource it shares
 * with its host.  The reference guards that with a fixed count of C levels
 * (`LUAI_MAXCCALLS`); a count cannot be safe here, because what one level costs
 * is a property of the code the backend generates (kilobytes, for the C backend
 * this builds against) rather than of the language, so the guard measures the
 * stack itself. */
MBT_EXPORT int64_t lua_mbt_stack_left(void) {
  char here;
#if defined(_WIN32)
  ULONG_PTR low = 0;
  ULONG_PTR high = 0;
  GetCurrentThreadStackLimits(&low, &high);
  if (low == 0 || (char *)&here <= (char *)low) return -1;
  return (int64_t)((char *)&here - (char *)low);
#elif defined(__APPLE__)
  char *top = (char *)pthread_get_stackaddr_np(pthread_self());
  size_t size = pthread_get_stacksize_np(pthread_self());
  char *low = top - size;
  if (top == 0 || (char *)&here <= low) return -1;
  return (int64_t)((char *)&here - low);
#elif defined(__linux__)
  pthread_attr_t attr;
  void *low = 0;
  size_t size = 0;
  if (pthread_getattr_np(pthread_self(), &attr) != 0) return -1;
  if (pthread_attr_getstack(&attr, &low, &size) != 0) {
    pthread_attr_destroy(&attr);
    return -1;
  }
  pthread_attr_destroy(&attr);
  if (low == 0 || (char *)&here <= (char *)low) return -1;
  return (int64_t)((char *)&here - (char *)low);
#else
  (void)here;
  return -1;
#endif
}
