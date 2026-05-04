/*
 * drm_colortemp_daemon.c - Monitor TTY switches and auto-apply color temperature
 * with inotify-based config file watching
 * 
 * Watches the DIRECTORY containing config file (not the file itself) to handle
 * editors that create temp files and rename (vim, nano, etc)
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <time.h>
#include <signal.h>
#include <stdarg.h>
#include <libgen.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/inotify.h>
#include <sys/select.h>
#include <linux/vt.h>
#include <drm/drm.h>
#include <drm/drm_mode.h>
#include "drm_device.h"
#include "drm_colortemp_utils.h"
#include "drm_config.h"
#include "drm_log.h"

// Global state
static volatile int running = 1;
static volatile int reload_config = 0;
config_t config;

// Signal handler
void signal_handler(int signum) {
    if (signum == SIGHUP) {
        reload_config = 1;
        return;
    }
    running = 0;
}

// log_msg - wrapper that maps level strings to syslog priorities.
// Kept as a thin shim so call sites that pass level strings still compile.
void log_msg(const char *level, const char *format, ...) {
    int prio = LOG_INFO;
    if (strcmp(level, "ERROR") == 0) prio = LOG_ERR;
    else if (strcmp(level, "WARN") == 0) prio = LOG_WARNING;
    else if (strcmp(level, "DEBUG") == 0) prio = LOG_DEBUG;

    va_list args;
    va_start(args, format);
    vsyslog(prio, format, args);
    va_end(args);

    if (drm_log_stderr) {
        va_start(args, format);
        fprintf(stderr, "[%s] ", level);
        vfprintf(stderr, format, args);
        fprintf(stderr, "\n");
        va_end(args);
    }
}

// Backwards-compat shims -- old code used trim/remove_quotes/load_config
// directly; redirect to the new drm_config.h functions.
char *trim(char *str)          { return config_trim(str); }
char *remove_quotes(char *str) { return config_remove_quotes(str); }

int load_config(const char *filename) {
    return config_load(filename, &config);
}

// Get active VT number
int get_active_vt(void) {
    int fd = open("/dev/console", O_RDONLY);
    if (fd < 0) {
        fd = open("/dev/tty0", O_RDONLY);
    }
    
    if (fd < 0) {
        return -1;
    }
    
    struct vt_stat vts;
    if (ioctl(fd, VT_GETSTATE, &vts) < 0) {
        close(fd);
        return -1;
    }
    
    close(fd);
    return vts.v_active;
}

// Calculate temperature based on time (Phase 3: uses localtime_r)
int calculate_temperature(void) {
    time_t now = time(NULL);
    struct tm tm_buf;
    localtime_r(&now, &tm_buf);
    int hour = tm_buf.tm_hour;
    
    if (hour >= config.sunset_hour || hour < config.sunrise_hour) {
        return config.night_temp;
    }
    return config.day_temp;
}

// Set gamma using ioctl
// Phase 5: If config.gamma_size > 0 it overrides the hardware-reported size.
int set_gamma_temp(int fd, uint32_t crtc_id, int gamma_size, int temp) {
    int effective_size = (config.gamma_size > 0) ? config.gamma_size : gamma_size;
    uint16_t *red_lut, *green_lut, *blue_lut;

    if (effective_size <= 0) return -1;

    red_lut = calloc(effective_size, sizeof(uint16_t));
    green_lut = calloc(effective_size, sizeof(uint16_t));
    blue_lut = calloc(effective_size, sizeof(uint16_t));

    if (!red_lut || !green_lut || !blue_lut) {
        free(red_lut);
        free(green_lut);
        free(blue_lut);
        return -1;
    }

    fill_gamma_luts(effective_size, temp, 1.0, red_lut, green_lut, blue_lut);

    struct drm_mode_crtc_lut lut = {
        .crtc_id = crtc_id,
        .gamma_size = effective_size,
        .red = (uint64_t)(uintptr_t)red_lut,
        .green = (uint64_t)(uintptr_t)green_lut,
        .blue = (uint64_t)(uintptr_t)blue_lut,
    };

    int ret = ioctl(fd, DRM_IOCTL_MODE_SETGAMMA, &lut);

    free(red_lut);
    free(green_lut);
    free(blue_lut);

    return ret;
}

// Get CRTC info
int get_crtc_info(int fd, uint32_t crtc_id, int *gamma_size, int *mode_valid) {
    struct drm_mode_crtc crtc = {
        .crtc_id = crtc_id,
    };
    
    if (ioctl(fd, DRM_IOCTL_MODE_GETCRTC, &crtc) < 0) {
        return -1;
    }
    
    *gamma_size = crtc.gamma_size;
    *mode_valid = crtc.mode_valid;
    
    return 0;
}

// Phase 4: Check whether a connector name matches the configured filter.
// If no filter is configured (connector[0]=='\0'), every connector matches.
static int connector_matches(int fd, uint32_t connector_id) {
    if (config.connector[0] == '\0')
        return 1;  /* no filter -> match all */

    struct drm_mode_get_connector conn = { .connector_id = connector_id };
    if (ioctl(fd, DRM_IOCTL_MODE_GETCONNECTOR, &conn) < 0)
        return 0;

    /* Build the canonical name "type-typeId", e.g. "DP-1" */
    static const char *type_names[] = {
        [0] = "Unknown",
        [1] = "VGA",  [2] = "DVII", [3] = "DVID", [4] = "DVIA",
        [5] = "Composite", [6] = "SVIDEO", [7] = "LVDS", [8] = "Component",
        [9] = "9PinDIN", [10] = "DisplayPort", [11] = "HDMIA", [12] = "HDMIB",
        [13] = "TV", [14] = "eDP", [15] = "VIRTUAL", [16] = "DSI", [17] = "DPI",
    };
    const char *tname = "Unknown";
    if (conn.connector_type < sizeof(type_names)/sizeof(type_names[0]) && type_names[conn.connector_type])
        tname = type_names[conn.connector_type];

    /* Also accept short aliases: DP for DisplayPort, etc. */
    char name_long[64], name_short[64];
    snprintf(name_long, sizeof(name_long), "%s-%u", tname, conn.connector_type_id);
    /* Common short aliases */
    const char *alias = tname;
    if (conn.connector_type == 10) alias = "DP";
    else if (conn.connector_type == 11) alias = "HDMI-A";
    else if (conn.connector_type == 12) alias = "HDMI-B";
    else if (conn.connector_type == 14) alias = "eDP";
    snprintf(name_short, sizeof(name_short), "%s-%u", alias, conn.connector_type_id);

    return (strcasecmp(config.connector, name_long) == 0 ||
            strcasecmp(config.connector, name_short) == 0);
}

// Collect CRTCs that are attached to connectors matching the filter.
// Returns a bitmask of matching CRTC indices.
static uint32_t get_matching_crtc_mask(int fd) {
    if (config.connector[0] == '\0')
        return ~0u;  /* no filter -> all CRTCs */

    struct drm_mode_card_res res = {0};
    if (ioctl(fd, DRM_IOCTL_MODE_GETRESOURCES, &res) < 0 || res.count_connectors == 0)
        return ~0u;

    uint32_t *conn_ids = calloc(res.count_connectors, sizeof(uint32_t));
    if (!conn_ids) return ~0u;
    res.connector_id_ptr = (uint64_t)(uintptr_t)conn_ids;

    /* Also need encoder list to map connector -> CRTC */
    uint32_t *enc_ids = calloc(res.count_encoders ? res.count_encoders : 1, sizeof(uint32_t));
    uint32_t *crtc_ids = calloc(res.count_crtcs ? res.count_crtcs : 1, sizeof(uint32_t));
    uint32_t *fb_ids = calloc(res.count_fbs ? res.count_fbs : 1, sizeof(uint32_t));
    res.encoder_id_ptr = (uint64_t)(uintptr_t)enc_ids;
    res.crtc_id_ptr    = (uint64_t)(uintptr_t)crtc_ids;
    res.fb_id_ptr      = (uint64_t)(uintptr_t)fb_ids;

    if (ioctl(fd, DRM_IOCTL_MODE_GETRESOURCES, &res) < 0) {
        free(conn_ids); free(enc_ids); free(crtc_ids); free(fb_ids);
        return ~0u;
    }

    uint32_t mask = 0;
    for (uint32_t c = 0; c < res.count_connectors; c++) {
        if (!connector_matches(fd, conn_ids[c]))
            continue;

        /* Get the encoder attached to this connector */
        struct drm_mode_get_connector gc = { .connector_id = conn_ids[c] };
        if (ioctl(fd, DRM_IOCTL_MODE_GETCONNECTOR, &gc) < 0 || gc.encoder_id == 0)
            continue;

        struct drm_mode_get_encoder enc = { .encoder_id = gc.encoder_id };
        if (ioctl(fd, DRM_IOCTL_MODE_GETENCODER, &enc) < 0)
            continue;

        /* Find which CRTC index this encoder is bound to */
        for (uint32_t i = 0; i < res.count_crtcs; i++) {
            if (crtc_ids[i] == enc.crtc_id) {
                mask |= (1u << i);
                break;
            }
        }
    }

    free(conn_ids); free(enc_ids); free(crtc_ids); free(fb_ids);
    return mask ? mask : ~0u;  /* fall back to all if nothing matched */
}

// Apply temperature to all CRTCs on a single DRM device fd
static int apply_temperature_to_fd(int fd, const char *device_name, int temp) {
    struct drm_mode_card_res res = {0};
    if (ioctl(fd, DRM_IOCTL_MODE_GETRESOURCES, &res) < 0) {
        log_msg("ERROR", "Failed to get DRM resources for %s", device_name);
        return -1;
    }

    if (res.count_crtcs == 0) {
        log_msg("ERROR", "No CRTCs found on %s", device_name);
        return -1;
    }

    uint32_t *crtcs = calloc(res.count_crtcs, sizeof(uint32_t));
    uint32_t *fbs = calloc(res.count_fbs ? res.count_fbs : 1, sizeof(uint32_t));
    uint32_t *connectors = calloc(res.count_connectors ? res.count_connectors : 1, sizeof(uint32_t));
    uint32_t *encoders = calloc(res.count_encoders ? res.count_encoders : 1, sizeof(uint32_t));

    if (!crtcs) {
        free(fbs); free(connectors); free(encoders);
        return -1;
    }

    res.fb_id_ptr = (uint64_t)(uintptr_t)fbs;
    res.crtc_id_ptr = (uint64_t)(uintptr_t)crtcs;
    res.connector_id_ptr = (uint64_t)(uintptr_t)connectors;
    res.encoder_id_ptr = (uint64_t)(uintptr_t)encoders;

    if (ioctl(fd, DRM_IOCTL_MODE_GETRESOURCES, &res) < 0) {
        log_msg("ERROR", "Failed to get CRTC list for %s", device_name);
        free(crtcs); free(fbs); free(connectors); free(encoders);
        return -1;
    }

    /* Phase 4: build a mask of CRTCs attached to the requested connector */
    uint32_t crtc_mask = get_matching_crtc_mask(fd);

    int success_count = 0;

    for (uint32_t i = 0; i < res.count_crtcs; i++) {
        if (!(crtc_mask & (1u << i)))
            continue;

        uint32_t crtc_id = crtcs[i];
        int gamma_size, mode_valid;

        if (get_crtc_info(fd, crtc_id, &gamma_size, &mode_valid) < 0)
            continue;
        if (!mode_valid || gamma_size == 0)
            continue;

        if (set_gamma_temp(fd, crtc_id, gamma_size, temp) == 0) {
            success_count++;
            if (config.verbose) {
                log_msg("INFO", "Applied %dK to %s CRTC %u", temp, device_name, crtc_id);
            }
        }
    }

    free(crtcs); free(fbs); free(connectors); free(encoders);
    return success_count > 0 ? 0 : -1;
}

// Apply temperature to all displays on all configured devices
int apply_temperature(int temp) {
    int total_success = 0;

    for (int d = 0; d < config.num_devices; d++) {
        char actual_device[256];
        int fd = drm_open_device(config.devices[d], actual_device, sizeof(actual_device));
        if (fd < 0) {
            log_msg("ERROR", "Failed to open DRM device %s: %s", config.devices[d], strerror(errno));
            continue;
        }
        if (config.verbose && strcmp(actual_device, config.devices[d]) != 0) {
            log_msg("INFO", "Using device %s (requested %s)", actual_device, config.devices[d]);
        }

        if (apply_temperature_to_fd(fd, actual_device, temp) == 0)
            total_success++;

        close(fd);
    }

    return total_success > 0 ? 0 : -1;
}

// Main daemon loop with inotify
void daemon_loop(const char *config_file) {
    log_msg("INFO", "Daemon started");
    log_msg("INFO", "Monitoring config file: %s", config_file);
    log_msg("INFO", "Monitoring TTY %d (auto), TTY %d (force warm), TTY %d (force cool)",
            config.monitor_tty, config.warm_tty, config.cool_tty);
    log_msg("INFO", "Day: %dK, Night: %dK", config.day_temp, config.night_temp);
    log_msg("INFO", "Sunset: %02d:00, Sunrise: %02d:00", 
            config.sunset_hour, config.sunrise_hour);
    if (config.connector[0])
        log_msg("INFO", "Connector filter: %s", config.connector);
    if (config.gamma_size > 0)
        log_msg("INFO", "Gamma table size override: %d", config.gamma_size);
    
    // Setup inotify - watch the directory, not the file itself
    // This handles editors that create temp files and rename
    int inotify_fd = inotify_init1(IN_NONBLOCK);
    if (inotify_fd < 0) {
        log_msg("ERROR", "Failed to initialize inotify: %s", strerror(errno));
        return;
    }
    
    // Get directory and filename - use separate strdup for each since
    // dirname() and basename() may modify their argument
    char *path_for_dir = strdup(config_file);
    char *path_for_base = strdup(config_file);
    char *config_dir = dirname(path_for_dir);
    char *filename = basename(path_for_base);

    int watch_fd = inotify_add_watch(inotify_fd, config_dir, IN_CREATE | IN_MOVED_TO | IN_MODIFY | IN_CLOSE_WRITE);
    if (watch_fd < 0) {
        log_msg("WARN", "Cannot watch config directory %s: %s", config_dir, strerror(errno));
        log_msg("INFO", "Config auto-reload disabled - changes require daemon restart");
    } else {
        log_msg("INFO", "Watching directory: %s", config_dir);
    }
    
    int last_applied_temp = 0;
    int prev_vt = 0;
    time_t last_check = 0;

    while (running) {
        // Check for config file changes
        if (watch_fd >= 0) {
            char buf[4096] __attribute__((aligned(__alignof__(struct inotify_event))));
            ssize_t len = read(inotify_fd, buf, sizeof(buf));

            if (len > 0) {
                const struct inotify_event *event;
                for (char *ptr = buf; ptr < buf + len; ptr += sizeof(struct inotify_event) + event->len) {
                    event = (const struct inotify_event *)ptr;

                    // Check if the event is for our config file
                    if (event->len > 0 && strcmp(event->name, filename) == 0) {
                        if (event->mask & (IN_CREATE | IN_MOVED_TO | IN_MODIFY | IN_CLOSE_WRITE)) {
                            log_msg("INFO", "Config file changed, reloading...");
                            // Give the file a moment to be completely written
                            usleep(100000);  // 100ms
                            if (load_config(config_file) == 0) {
                                log_msg("INFO", "Configuration reloaded successfully");
                                last_applied_temp = 0;  // Force reapplication
                            }
                        }
                    }
                }
            }
        }

        // Check VT state
        int active_vt = get_active_vt();

        if (active_vt < 0) {
            sleep(config.check_interval);
            continue;
        }

        // Detect VT switch
        if (active_vt != prev_vt) {
            int target_temp = 0;

            if (active_vt == config.monitor_tty) {
                // Switch to monitor TTY: apply time-based temperature
                target_temp = calculate_temperature();
                log_msg("INFO", "User switched to TTY%d (auto)", config.monitor_tty);
            } else if (active_vt == config.warm_tty) {
                // Switch to warm TTY: force warm (night) temperature
                target_temp = config.night_temp;
                log_msg("INFO", "User switched to TTY%d (force warm: %dK)",
                        config.warm_tty, target_temp);
            } else if (active_vt == config.cool_tty) {
                // Switch to cool TTY: force cool (day) temperature
                target_temp = config.day_temp;
                log_msg("INFO", "User switched to TTY%d (force cool: %dK)",
                        config.cool_tty, target_temp);
            }

            if (target_temp > 0 && (target_temp != last_applied_temp || last_applied_temp == 0)) {
                log_msg("INFO", "Applying temperature: %dK", target_temp);

                if (apply_temperature(target_temp) == 0) {
                    log_msg("INFO", "Successfully applied %dK", target_temp);
                    last_applied_temp = target_temp;
                } else {
                    log_msg("ERROR", "Failed to apply temperature");
                }
            }

            prev_vt = active_vt;
        }

        int is_on_target_tty = (active_vt == config.monitor_tty);

        // Periodic check for time-based changes (every minute)
        time_t now = time(NULL);
        if (now - last_check >= 60) {
            int current_temp = calculate_temperature();
            if (current_temp != last_applied_temp && is_on_target_tty) {
                log_msg("INFO", "Time-based temperature change: %dK", current_temp);
                if (apply_temperature(current_temp) == 0) {
                    last_applied_temp = current_temp;
                }
            }
            last_check = now;
        }

        sleep(config.check_interval);
    }
    
    free(path_for_dir);
    free(path_for_base);

    if (watch_fd >= 0) {
        inotify_rm_watch(inotify_fd, watch_fd);
    }
    close(inotify_fd);

    log_msg("INFO", "Daemon stopped");
}

// Print usage
void print_usage(const char *prog) {
    printf("Usage: %s [OPTIONS]\n", prog);
    printf("DRM Color Temperature TTY Daemon with inotify config watching\n\n");
    printf("Options:\n");
    printf("  -c FILE      Config file (default: %s)\n", CONFIG_FILE);
    printf("  -h           Show this help\n");
    printf("\nThe daemon monitors TTY switches and config file changes.\n");
    printf("Edit %s and changes apply automatically.\n", CONFIG_FILE);
}

#ifndef TEST_BUILD
int main(int argc, char *argv[]) {
    const char *config_file = CONFIG_FILE;
    int opt;

    /* Phase 3: ensure timezone database is loaded */
    tzset();
    
    while ((opt = getopt(argc, argv, "c:h")) != -1) {
        switch (opt) {
            case 'c':
                config_file = optarg;
                break;
            case 'h':
                print_usage(argv[0]);
                return 0;
            default:
                print_usage(argv[0]);
                return 1;
        }
    }
    
    // Check root
    if (geteuid() != 0) {
        fprintf(stderr, "Error: This daemon must run as root\n");
        return 1;
    }
    
    // Load initial config
    if (load_config(config_file) < 0) {
        fprintf(stderr, "Error: Failed to load config file\n");
        return 1;
    }

    // Initialize syslog (must be after load_config so config.verbose is known)
    drm_log_init("drm_colortemp_daemon", config.verbose);
    
    // Setup signal handlers
    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);
    signal(SIGHUP, signal_handler);
    
    // Run daemon
    daemon_loop(config_file);

    drm_log_close();
    return 0;
}
#endif /* TEST_BUILD */
