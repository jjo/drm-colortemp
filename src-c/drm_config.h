/*
 * drm_config.h - Configuration management for drm-colortemp
 *
 * Provides config_t struct, load_config(), and string helpers.
 * Extracted from drm_colortemp_daemon_inotify.c for reuse and testability.
 */

#ifndef DRM_CONFIG_H
#define DRM_CONFIG_H

#define CONFIG_FILE "/etc/default/drm-colortemp.conf"
#define MAX_LINE 256
#define MAX_DEVICES 8
#define GAMMA_SIZE_MIN 64
#define GAMMA_SIZE_MAX 4096

/* Configuration state */
typedef struct
{
  char devices[MAX_DEVICES][256];
  int num_devices;
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
  char connector[128];		/* Phase 4: preferred connector name (e.g. "DP-1") */
  int gamma_size;		/* Phase 5: override gamma table size (0 = use HW) */
} config_t;

/**
 * Load configuration from an INI-style file.
 *
 * Resets @cfg to defaults, then parses @filename.  If no DEVICE keys are
 * present, auto-detects DRM devices.
 *
 * @param filename  Path to the configuration file.
 * @param cfg       Pointer to config_t to populate.
 * @return 0 on success, -1 on error.
 */
int config_load (const char *filename, config_t * cfg);

/**
 * Set @cfg to built-in defaults (6500K day, 3500K night, etc.).
 */
void config_defaults (config_t * cfg);

/**
 * Trim leading/trailing whitespace from @str in place.
 * Returns pointer into the same buffer.
 */
char *config_trim (char *str);

/**
 * Strip matching surrounding quotes (single or double) from @str.
 * Returns pointer into the same buffer.
 */
char *config_remove_quotes (char *str);

#endif /* DRM_CONFIG_H */
