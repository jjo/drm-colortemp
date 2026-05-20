/*
 * drm_config.c - Configuration management for drm-colortemp
 *
 * Implements INI-style KEY=VALUE parsing with validation,
 * extracted from drm_colortemp_daemon_inotify.c.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "drm_config.h"
#include "drm_device.h"
#include "drm_colortemp_utils.h"
#include "drm_log.h"

/* ---- string helpers ---- */

char *
config_trim (char *str)
{
  char *end;
  while (*str == ' ' || *str == '\t')
    str++;
  if (*str == 0)
    return str;
  end = str + strlen (str) - 1;
  while (end > str
	 && (*end == ' ' || *end == '\t' || *end == '\n' || *end == '\r'))
    end--;
  end[1] = '\0';
  return str;
}

char *
config_remove_quotes (char *str)
{
  size_t len = strlen (str);
  if (len >= 2 && ((str[0] == '"' && str[len - 1] == '"') ||
		   (str[0] == '\'' && str[len - 1] == '\'')))
    {
      str[len - 1] = '\0';
      return str + 1;
    }
  return str;
}

/* ---- defaults ---- */

void
config_defaults (config_t * cfg)
{
  memset (cfg, 0, sizeof (*cfg));
  cfg->day_temp = 6500;
  cfg->night_temp = 3500;
  cfg->sunset_hour = 20;
  cfg->sunrise_hour = 8;
  cfg->monitor_tty = 3;
  cfg->warm_tty = 4;
  cfg->cool_tty = 5;
  cfg->check_interval = 1;
  cfg->verbose = 0;
  cfg->has_location = 0;
  cfg->connector[0] = '\0';
  cfg->gamma_size = 0;		/* 0 = use hardware-reported size */
}

/* ---- key-value dispatch table ---- */

typedef struct
{
  const char *key;
  enum
  { KV_INT, KV_STR, KV_LOCATION, KV_DEVICE, KV_DEVICEN } kind;
  size_t offset;		/* offsetof into config_t */
  size_t size;			/* for KV_STR: buffer size */
  int min_val;			/* for KV_INT: minimum value */
  int max_val;			/* for KV_INT: maximum value */
} kv_entry_t;

#define OFF(field) __builtin_offsetof(config_t, field)
#define INT_RANGE(min, max) min, max

static const kv_entry_t kv_table[] = {
  {"DEVICE", KV_DEVICE, 0, 0, 0, 0},
  {"DAY_TEMP", KV_INT, OFF (day_temp), 0, 1000, 10000},
  {"NIGHT_TEMP", KV_INT, OFF (night_temp), 0, 1000, 10000},
  {"SUNSET_HOUR", KV_INT, OFF (sunset_hour), 0, 0, 23},
  {"SUNRISE_HOUR", KV_INT, OFF (sunrise_hour), 0, 0, 23},
  {"MONITOR_TTY", KV_INT, OFF (monitor_tty), 0, 1, 12},
  {"WARM_TTY", KV_INT, OFF (warm_tty), 0, 1, 12},
  {"COOL_TTY", KV_INT, OFF (cool_tty), 0, 1, 12},
  {"CHECK_INTERVAL", KV_INT, OFF (check_interval), 0, 1, 3600},
  {"VERBOSE", KV_INT, OFF (verbose), 0, 0, 1},
  {"LOCATION", KV_LOCATION, 0, 0, 0, 0},
  {"CONNECTOR", KV_STR, OFF (connector),
   sizeof (((config_t *) 0)->connector), 0, 0},
  {"GAMMA_SIZE", KV_INT, OFF (gamma_size), 0, 0, 4096},
  {NULL, 0, 0, 0, 0, 0}
};

/* Try to match DEVICEn (n = 1..MAX_DEVICES) */
static int
parse_devicen (const char *key, const char *value, config_t * cfg)
{
  if (strncmp (key, "DEVICE", 6) != 0)
    return 0;
  char ch = key[6];
  if (ch < '1' || ch > '0' + MAX_DEVICES || key[7] != '\0')
    return 0;
  int idx = ch - '1';
  strncpy (cfg->devices[idx], value, sizeof (cfg->devices[idx]) - 1);
  if (cfg->num_devices < idx + 1)
    cfg->num_devices = idx + 1;
  return 1;
}

/* Apply a single key=value pair */
static void
config_apply_kv (const char *key, const char *value, config_t * cfg)
{
  int parsed_val;

  /* Try numbered DEVICE first (DEVICE1..DEVICE8) */
  if (parse_devicen (key, value, cfg))
    return;

  for (const kv_entry_t * e = kv_table; e->key; e++)
    {
      if (strcmp (key, e->key) != 0)
	continue;

      switch (e->kind)
	{
	case KV_INT:
	  if (safe_atoi (value, &parsed_val, e->min_val, e->max_val))
	    {
	      *(int *) ((char *) cfg + e->offset) = parsed_val;
	    }
	  else
	    {
	      DRM_LOG_WRN
		("config: invalid integer value for %s: %s (valid range: %d-%d)",
		 key, value, e->min_val, e->max_val);
	    }
	  break;
	case KV_STR:
	  strncpy ((char *) cfg + e->offset, value, e->size - 1);
	  ((char *) cfg + e->offset)[e->size - 1] = '\0';
	  break;
	case KV_DEVICE:
	  strncpy (cfg->devices[0], value, sizeof (cfg->devices[0]) - 1);
	  if (cfg->num_devices < 1)
	    cfg->num_devices = 1;
	  break;
	case KV_LOCATION:
	  if (strlen (value) > 0)
	    {
	      if (sscanf
		  (value, "%lf,%lf", &cfg->latitude, &cfg->longitude) == 2)
		{
		  cfg->has_location = 1;
		}
	    }
	  break;
	case KV_DEVICEN:
	  /* handled above */
	  break;
	}
      return;
    }
  /* Unknown keys are silently ignored */
}

/* ---- validation ---- */

static void
config_validate (config_t * cfg)
{
  if (cfg->day_temp < 1000 || cfg->day_temp > 10000)
    {
      DRM_LOG_WRN
	("DAY_TEMP %d out of range [1000,10000], clamping", cfg->day_temp);
      if (cfg->day_temp < 1000)
	cfg->day_temp = 1000;
      if (cfg->day_temp > 10000)
	cfg->day_temp = 10000;
    }
  if (cfg->night_temp < 1000 || cfg->night_temp > 10000)
    {
      DRM_LOG_WRN
	("NIGHT_TEMP %d out of range [1000,10000], clamping",
	 cfg->night_temp);
      if (cfg->night_temp < 1000)
	cfg->night_temp = 1000;
      if (cfg->night_temp > 10000)
	cfg->night_temp = 10000;
    }
  if (cfg->sunset_hour < 0 || cfg->sunset_hour > 23)
    {
      DRM_LOG_WRN
	("SUNSET_HOUR %d out of range [0,23], resetting to 20",
	 cfg->sunset_hour);
      cfg->sunset_hour = 20;
    }
  if (cfg->sunrise_hour < 0 || cfg->sunrise_hour > 23)
    {
      DRM_LOG_WRN
	("SUNRISE_HOUR %d out of range [0,23], resetting to 8",
	 cfg->sunrise_hour);
      cfg->sunrise_hour = 8;
    }
  if (cfg->check_interval < 1)
    {
      cfg->check_interval = 1;
    }
  if (cfg->gamma_size != 0 &&
      (cfg->gamma_size < GAMMA_SIZE_MIN || cfg->gamma_size > GAMMA_SIZE_MAX))
    {
      DRM_LOG_WRN
	("GAMMA_SIZE %d out of range [%d,%d], resetting to 0 (auto)",
	 cfg->gamma_size, GAMMA_SIZE_MIN, GAMMA_SIZE_MAX);
      cfg->gamma_size = 0;
    }
}

/* ---- public API ---- */

int
config_load (const char *filename, config_t * cfg)
{
  FILE *f = fopen (filename, "r");
  if (!f)
    {
      DRM_LOG_ERR ("Cannot open config file: %s", filename);
      return -1;
    }

  config_defaults (cfg);

  char line[MAX_LINE];
  int line_num = 0;

  while (fgets (line, sizeof (line), f))
    {
      line_num++;
      char *trimmed = config_trim (line);

      /* Skip comments and empty lines */
      if (trimmed[0] == '#' || trimmed[0] == '\0')
	continue;

      /* Parse KEY=VALUE */
      char *equals = strchr (trimmed, '=');
      if (!equals)
	{
	  DRM_LOG_WRN ("config:%d: malformed line (no '=')", line_num);
	  continue;
	}

      *equals = '\0';
      char *key = config_trim (trimmed);
      char *value = config_trim (equals + 1);
      value = config_remove_quotes (value);

      config_apply_kv (key, value, cfg);
    }

  fclose (f);

  /* Auto-detect devices if none explicitly configured */
  if (cfg->num_devices == 0)
    {
      int found = drm_find_all_devices (cfg->devices, MAX_DEVICES);
      if (found > 0)
	{
	  cfg->num_devices = found;
	  DRM_LOG_INF ("Auto-detected %d DRM device(s)", found);
	}
      else
	{
	  if (drm_find_device
	      (cfg->devices[0], sizeof (cfg->devices[0])) == 0)
	    {
	      cfg->num_devices = 1;
	    }
	}
    }

  config_validate (cfg);

  DRM_LOG_INF ("Configuration loaded from %s", filename);
  if (cfg->verbose)
    {
      for (int i = 0; i < cfg->num_devices; i++)
	{
	  DRM_LOG_INF ("Device[%d]: %s", i, cfg->devices[i]);
	}
      DRM_LOG_INF ("Day temp: %dK, Night temp: %dK",
		   cfg->day_temp, cfg->night_temp);
      DRM_LOG_INF ("Sunset: %02d:00, Sunrise: %02d:00",
		   cfg->sunset_hour, cfg->sunrise_hour);
      DRM_LOG_INF ("Monitor TTY: %d, Warm TTY: %d, Cool TTY: %d",
		   cfg->monitor_tty, cfg->warm_tty, cfg->cool_tty);
      if (cfg->has_location)
	{
	  DRM_LOG_INF ("Location: %.4f, %.4f", cfg->latitude, cfg->longitude);
	}
      if (cfg->connector[0])
	{
	  DRM_LOG_INF ("Connector filter: %s", cfg->connector);
	}
      if (cfg->gamma_size > 0)
	{
	  DRM_LOG_INF ("Gamma table size override: %d", cfg->gamma_size);
	}
    }

  return 0;
}
