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

#define CONFIG_FILE "/etc/default/drm-colortemp.conf"
#define MAX_LINE 256

// Configuration
typedef struct {
    char device[256];
    int day_temp;
    int night_temp;
    int sunset_hour;
    int sunrise_hour;
    int monitor_tty;
    int warm_tty;
    int cool_tty;
    int check_interval;
    int verbose;
    double latitude;
    double longitude;
    int has_location;
} config_t;

// Global state
static volatile int running = 1;
static volatile int reload_config = 0;
static config_t config;

// Signal handler
void signal_handler(int signum) {
    if (signum == SIGHUP) {
        reload_config = 1;
        return;
    }
    running = 0;
    printf("\nShutting down daemon...\n");
}

// Logging
void log_msg(const char *level, const char *format, ...) {
    time_t now = time(NULL);
    struct tm *tm = localtime(&now);
    char timestr[64];
    strftime(timestr, sizeof(timestr), "%Y-%m-%d %H:%M:%S", tm);
    
    printf("[%s] %s: ", timestr, level);
    
    va_list args;
    va_start(args, format);
    vprintf(format, args);
    va_end(args);
    
    printf("\n");
    fflush(stdout);
}

// Trim whitespace
char *trim(char *str) {
    char *end;
    while (*str == ' ' || *str == '\t') str++;
    if (*str == 0) return str;
    end = str + strlen(str) - 1;
    while (end > str && (*end == ' ' || *end == '\t' || *end == '\n' || *end == '\r')) end--;
    end[1] = '\0';
    return str;
}

// Remove quotes from string
char *remove_quotes(char *str) {
    size_t len = strlen(str);
    if (len >= 2 && ((str[0] == '"' && str[len-1] == '"') || 
                     (str[0] == '\'' && str[len-1] == '\''))) {
        str[len-1] = '\0';
        return str + 1;
    }
    return str;
}

// Load configuration from file
int load_config(const char *filename) {
    FILE *f = fopen(filename, "r");
    if (!f) {
        log_msg("ERROR", "Cannot open config file: %s", filename);
        return -1;
    }
    
    // Set defaults
    strncpy(config.device, "/dev/dri/card1", sizeof(config.device) - 1);
    config.day_temp = 6500;
    config.night_temp = 3500;
    config.sunset_hour = 20;
    config.sunrise_hour = 8;
    config.monitor_tty = 3;
    config.warm_tty = 4;
    config.cool_tty = 5;
    config.check_interval = 1;
    config.verbose = 0;
    config.has_location = 0;
    
    char line[MAX_LINE];
    int line_num = 0;
    
    while (fgets(line, sizeof(line), f)) {
        line_num++;
        char *trimmed = trim(line);
        
        // Skip comments and empty lines
        if (trimmed[0] == '#' || trimmed[0] == '\0') {
            continue;
        }
        
        // Parse KEY=VALUE
        char *equals = strchr(trimmed, '=');
        if (!equals) {
            continue;
        }
        
        *equals = '\0';
        char *key = trim(trimmed);
        char *value = trim(equals + 1);
        value = remove_quotes(value);
        
        if (strcmp(key, "DEVICE") == 0) {
            strncpy(config.device, value, sizeof(config.device) - 1);
        } else if (strcmp(key, "DAY_TEMP") == 0) {
            config.day_temp = atoi(value);
        } else if (strcmp(key, "NIGHT_TEMP") == 0) {
            config.night_temp = atoi(value);
        } else if (strcmp(key, "SUNSET_HOUR") == 0) {
            config.sunset_hour = atoi(value);
        } else if (strcmp(key, "SUNRISE_HOUR") == 0) {
            config.sunrise_hour = atoi(value);
        } else if (strcmp(key, "MONITOR_TTY") == 0) {
            config.monitor_tty = atoi(value);
        } else if (strcmp(key, "WARM_TTY") == 0) {
            config.warm_tty = atoi(value);
        } else if (strcmp(key, "COOL_TTY") == 0) {
            config.cool_tty = atoi(value);
        } else if (strcmp(key, "CHECK_INTERVAL") == 0) {
            config.check_interval = atoi(value);
        } else if (strcmp(key, "VERBOSE") == 0) {
            config.verbose = atoi(value);
        } else if (strcmp(key, "LOCATION") == 0) {
            if (strlen(value) > 0) {
                if (sscanf(value, "%lf,%lf", &config.latitude, &config.longitude) == 2) {
                    config.has_location = 1;
                }
            }
        }
    }
    
    fclose(f);
    
    log_msg("INFO", "Configuration loaded from %s", filename);
    if (config.verbose) {
        log_msg("INFO", "Device: %s", config.device);
        log_msg("INFO", "Day temp: %dK, Night temp: %dK", config.day_temp, config.night_temp);
        log_msg("INFO", "Sunset: %02d:00, Sunrise: %02d:00", config.sunset_hour, config.sunrise_hour);
        log_msg("INFO", "Monitor TTY: %d, Warm TTY: %d, Cool TTY: %d",
                config.monitor_tty, config.warm_tty, config.cool_tty);
        if (config.has_location) {
            log_msg("INFO", "Location: %.4f, %.4f", config.latitude, config.longitude);
        }
    }
    
    return 0;
}

// Get active VT number
int get_active_vt() {
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

// Calculate temperature based on time
int calculate_temperature() {
    time_t now = time(NULL);
    struct tm *tm = localtime(&now);
    int hour = tm->tm_hour;
    
    if (hour >= config.sunset_hour || hour < config.sunrise_hour) {
        return config.night_temp;
    }
    return config.day_temp;
}

// Set gamma using ioctl
int set_gamma_temp(int fd, uint32_t crtc_id, int gamma_size, int temp) {
    uint16_t *red_lut, *green_lut, *blue_lut;

    if (gamma_size <= 0) return -1;

    red_lut = calloc(gamma_size, sizeof(uint16_t));
    green_lut = calloc(gamma_size, sizeof(uint16_t));
    blue_lut = calloc(gamma_size, sizeof(uint16_t));

    if (!red_lut || !green_lut || !blue_lut) {
        free(red_lut);
        free(green_lut);
        free(blue_lut);
        return -1;
    }

    fill_gamma_luts(gamma_size, temp, 1.0, red_lut, green_lut, blue_lut);

    struct drm_mode_crtc_lut lut = {
        .crtc_id = crtc_id,
        .gamma_size = gamma_size,
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

// Apply temperature to all displays
int apply_temperature(int temp) {
    char actual_device[256];
    int fd = drm_open_device(config.device, actual_device, sizeof(actual_device));
    if (fd < 0) {
        log_msg("ERROR", "Failed to open DRM device: %s", strerror(errno));
        return -1;
    }
    if (config.verbose && strcmp(actual_device, config.device) != 0) {
        log_msg("INFO", "Using device %s", actual_device);
    }
    
    // Get resources
    struct drm_mode_card_res res = {0};
    if (ioctl(fd, DRM_IOCTL_MODE_GETRESOURCES, &res) < 0) {
        log_msg("ERROR", "Failed to get DRM resources");
        close(fd);
        return -1;
    }
    
    if (res.count_crtcs == 0) {
        log_msg("ERROR", "No CRTCs found");
        close(fd);
        return -1;
    }
    
    // Allocate arrays
    uint32_t *crtcs = calloc(res.count_crtcs, sizeof(uint32_t));
    uint32_t *fbs = calloc(res.count_fbs, sizeof(uint32_t));
    uint32_t *connectors = calloc(res.count_connectors, sizeof(uint32_t));
    uint32_t *encoders = calloc(res.count_encoders, sizeof(uint32_t));
    
    if (!crtcs) {
        close(fd);
        return -1;
    }
    
    res.fb_id_ptr = (uint64_t)(uintptr_t)fbs;
    res.crtc_id_ptr = (uint64_t)(uintptr_t)crtcs;
    res.connector_id_ptr = (uint64_t)(uintptr_t)connectors;
    res.encoder_id_ptr = (uint64_t)(uintptr_t)encoders;
    
    if (ioctl(fd, DRM_IOCTL_MODE_GETRESOURCES, &res) < 0) {
        log_msg("ERROR", "Failed to get CRTC list");
        free(crtcs);
        free(fbs);
        free(connectors);
        free(encoders);
        close(fd);
        return -1;
    }
    
    int success_count = 0;
    
    for (uint32_t i = 0; i < res.count_crtcs; i++) {
        uint32_t crtc_id = crtcs[i];
        int gamma_size, mode_valid;
        
        if (get_crtc_info(fd, crtc_id, &gamma_size, &mode_valid) < 0) {
            continue;
        }
        
        if (!mode_valid || gamma_size == 0) {
            continue;
        }
        
        if (set_gamma_temp(fd, crtc_id, gamma_size, temp) == 0) {
            success_count++;
            if (config.verbose) {
                log_msg("INFO", "Applied %dK to CRTC %u", temp, crtc_id);
            }
        }
    }
    
    free(crtcs);
    free(fbs);
    free(connectors);
    free(encoders);
    close(fd);
    
    return success_count > 0 ? 0 : -1;
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

            if (target_temp > 0) {
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

int main(int argc, char *argv[]) {
    const char *config_file = CONFIG_FILE;
    int opt;
    
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
    
    // Setup signal handlers
    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);
    signal(SIGHUP, signal_handler);
    
    // Run daemon
    daemon_loop(config_file);
    
    return 0;
}
