/*
 * drm_log.h - Unified logging for drm-colortemp
 *
 * Provides syslog-based logging with optional stderr fallback for
 * interactive / debug use.  Every translation unit that needs to log
 * should #include this header.
 *
 * Usage:
 *   drm_log_init("drm_colortemp_daemon", 1);  // verbose=1 -> LOG_DEBUG
 *   DRM_LOG_INF("Applied %dK to CRTC %u", temp, crtc_id);
 *   DRM_LOG_ERR("Failed to open %s: %s", path, strerror(errno));
 *   drm_log_close();
 */

#ifndef DRM_LOG_H
#define DRM_LOG_H

#include <syslog.h>
#include <stdio.h>
#include <stdarg.h>

/* Global flag: when set, also echo to stderr (useful during development). */
static int drm_log_stderr = 0;

/* Global flag: verbose mode enables LOG_DEBUG messages. */
static int drm_log_verbose = 0;

/*
 * drm_log_init - Open the syslog connection.
 *
 * @ident:    Program name shown in log entries.
 * @verbose:  If non-zero, LOG_DEBUG messages are enabled and output is
 *            also echoed to stderr.
 */
static inline void drm_log_init(const char *ident, int verbose) {
    drm_log_verbose = verbose;
    drm_log_stderr  = verbose;
    int log_mask = verbose ? LOG_UPTO(LOG_DEBUG) : LOG_UPTO(LOG_INFO);
    openlog(ident, LOG_PID | LOG_CONS, LOG_DAEMON);
    setlogmask(log_mask);
}

/*
 * drm_log_close - Close the syslog connection.
 */
static inline void drm_log_close(void) {
    closelog();
}

/*
 * drm_log - Core logging function.
 *
 * Sends the message to syslog and optionally to stderr.
 */
static inline void drm_log(int priority, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
static inline void drm_log(int priority, const char *fmt, ...) {
    va_list ap;

    va_start(ap, fmt);
    vsyslog(priority, fmt, ap);
    va_end(ap);

    if (drm_log_stderr) {
        const char *label;
        switch (priority) {
            case LOG_ERR:     label = "ERROR"; break;
            case LOG_WARNING: label = "WARN";  break;
            case LOG_INFO:    label = "INFO";  break;
            case LOG_DEBUG:   label = "DEBUG"; break;
            default:          label = "LOG";   break;
        }
        va_start(ap, fmt);
        fprintf(stderr, "[%s] ", label);
        vfprintf(stderr, fmt, ap);
        fprintf(stderr, "\n");
        va_end(ap);
    }
}

/* Convenience macros */
#define DRM_LOG_ERR(fmt, ...)  drm_log(LOG_ERR,     fmt, ##__VA_ARGS__)
#define DRM_LOG_WRN(fmt, ...)  drm_log(LOG_WARNING,  fmt, ##__VA_ARGS__)
#define DRM_LOG_INF(fmt, ...)  drm_log(LOG_INFO,     fmt, ##__VA_ARGS__)
#define DRM_LOG_DBG(fmt, ...)  do { if (drm_log_verbose) drm_log(LOG_DEBUG, fmt, ##__VA_ARGS__); } while(0)

#endif /* DRM_LOG_H */
