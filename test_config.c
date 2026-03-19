/*
 * test_config.c - Unit tests for config parsing (multi-device support)
 *
 * Compiled with TEST_BUILD so the daemon's main() is excluded.
 * Links against drm_colortemp_daemon_inotify.o to test load_config() directly.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define MAX_LINE 256
#define MAX_DEVICES 8

/* Mirrors config_t from daemon - must stay in sync */
typedef struct {
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
} config_t;

/* Defined in drm_colortemp_daemon_inotify.o */
extern config_t config;
extern int load_config(const char *filename);

/* ---------- helpers ---------- */

static int pass_count = 0;
static int fail_count = 0;

#define ASSERT(cond, msg) do { \
    if (cond) { \
        printf("  PASS: %s\n", msg); \
        pass_count++; \
    } else { \
        printf("  FAIL: %s  (line %d)\n", msg, __LINE__); \
        fail_count++; \
    } \
} while (0)

/* Write a temp conf file, return path (caller must unlink) */
static char *write_conf(const char *content) {
    char *path = strdup("/tmp/test_drm_colortemp_XXXXXX.conf");
    int fd = mkstemps(path, 5);
    if (fd < 0) { perror("mkstemps"); exit(1); }
    write(fd, content, strlen(content));
    close(fd);
    return path;
}

/* ---------- tests ---------- */

static void test_single_device_legacy(void) {
    printf("test: DEVICE= (legacy single-device)\n");
    char *path = write_conf("DEVICE=\"/dev/dri/card0\"\n");
    load_config(path);
    unlink(path); free(path);

    ASSERT(config.num_devices == 1, "num_devices == 1");
    ASSERT(strcmp(config.devices[0], "/dev/dri/card0") == 0, "devices[0] == /dev/dri/card0");
}

static void test_device1_device2(void) {
    printf("test: DEVICE1= + DEVICE2= (multi-device)\n");
    char *path = write_conf(
        "DEVICE1=\"/dev/dri/card0\"\n"
        "DEVICE2=\"/dev/dri/card1\"\n"
    );
    load_config(path);
    unlink(path); free(path);

    ASSERT(config.num_devices == 2, "num_devices == 2");
    ASSERT(strcmp(config.devices[0], "/dev/dri/card0") == 0, "devices[0] == /dev/dri/card0");
    ASSERT(strcmp(config.devices[1], "/dev/dri/card1") == 0, "devices[1] == /dev/dri/card1");
}

static void test_mixed_device_and_device2(void) {
    printf("test: DEVICE= + DEVICE2= (mixed)\n");
    char *path = write_conf(
        "DEVICE=\"/dev/dri/card0\"\n"
        "DEVICE2=\"/dev/dri/card1\"\n"
    );
    load_config(path);
    unlink(path); free(path);

    ASSERT(config.num_devices == 2, "num_devices == 2");
    ASSERT(strcmp(config.devices[0], "/dev/dri/card0") == 0, "devices[0] == /dev/dri/card0");
    ASSERT(strcmp(config.devices[1], "/dev/dri/card1") == 0, "devices[1] == /dev/dri/card1");
}

static void test_device_max(void) {
    printf("test: DEVICE1..DEVICE8 (max devices)\n");
    char *path = write_conf(
        "DEVICE1=\"/dev/dri/card0\"\n"
        "DEVICE2=\"/dev/dri/card1\"\n"
        "DEVICE3=\"/dev/dri/card2\"\n"
        "DEVICE4=\"/dev/dri/card3\"\n"
        "DEVICE5=\"/dev/dri/card4\"\n"
        "DEVICE6=\"/dev/dri/card5\"\n"
        "DEVICE7=\"/dev/dri/card6\"\n"
        "DEVICE8=\"/dev/dri/card7\"\n"
    );
    load_config(path);
    unlink(path); free(path);

    ASSERT(config.num_devices == 8, "num_devices == 8");
    ASSERT(strcmp(config.devices[7], "/dev/dri/card7") == 0, "devices[7] == /dev/dri/card7");
}

static void test_no_device_autodetect(void) {
    printf("test: no DEVICE= (auto-detect)\n");
    char *path = write_conf("DAY_TEMP=6500\n");
    load_config(path);
    unlink(path); free(path);

    /* Auto-detect may find 0 or more devices depending on hardware.
     * We just verify the function handled it without crashing and
     * num_devices is non-negative. */
    ASSERT(config.num_devices >= 0, "num_devices >= 0 (no crash)");
    printf("  INFO: auto-detected %d device(s)\n", config.num_devices);
}

static void test_single_values_parsed(void) {
    printf("test: scalar config values\n");
    char *path = write_conf(
        "DEVICE=\"/dev/dri/card0\"\n"
        "DAY_TEMP=5500\n"
        "NIGHT_TEMP=2700\n"
        "SUNSET_HOUR=19\n"
        "SUNRISE_HOUR=7\n"
        "MONITOR_TTY=3\n"
        "WARM_TTY=4\n"
        "COOL_TTY=5\n"
        "CHECK_INTERVAL=2\n"
        "VERBOSE=1\n"
        "LOCATION=\"51.5074,-0.1278\"\n"
    );
    load_config(path);
    unlink(path); free(path);

    ASSERT(config.day_temp == 5500,   "day_temp == 5500");
    ASSERT(config.night_temp == 2700, "night_temp == 2700");
    ASSERT(config.sunset_hour == 19,  "sunset_hour == 19");
    ASSERT(config.sunrise_hour == 7,  "sunrise_hour == 7");
    ASSERT(config.monitor_tty == 3,   "monitor_tty == 3");
    ASSERT(config.warm_tty == 4,      "warm_tty == 4");
    ASSERT(config.cool_tty == 5,      "cool_tty == 5");
    ASSERT(config.check_interval == 2,"check_interval == 2");
    ASSERT(config.verbose == 1,       "verbose == 1");
    ASSERT(config.has_location == 1,  "has_location == 1");
}

static void test_comments_and_empty_lines(void) {
    printf("test: comments and empty lines ignored\n");
    char *path = write_conf(
        "# This is a comment\n"
        "\n"
        "   # Indented comment\n"
        "DEVICE=\"/dev/dri/card0\"\n"
        "\n"
        "DAY_TEMP=4000\n"
    );
    load_config(path);
    unlink(path); free(path);

    ASSERT(config.num_devices == 1, "num_devices == 1");
    ASSERT(config.day_temp == 4000,  "day_temp == 4000");
}

static void test_device_out_of_range_ignored(void) {
    printf("test: DEVICE0 and DEVICE9 are ignored (out of range)\n");
    char *path = write_conf(
        "DEVICE1=\"/dev/dri/card0\"\n"
        "DEVICE9=\"/dev/dri/card9\"\n"  /* >MAX_DEVICES, should be ignored */
    );
    load_config(path);
    unlink(path); free(path);

    /* DEVICE9 is > MAX_DEVICES=8, so only DEVICE1 should be stored */
    ASSERT(config.num_devices == 1, "num_devices == 1 (DEVICE9 ignored)");
    ASSERT(strcmp(config.devices[0], "/dev/dri/card0") == 0, "devices[0] == /dev/dri/card0");
}

/* ---------- main ---------- */

int main(void) {
    printf("=== drm-colortemp config unit tests ===\n\n");

    test_single_device_legacy();
    test_device1_device2();
    test_mixed_device_and_device2();
    test_device_max();
    test_no_device_autodetect();
    test_single_values_parsed();
    test_comments_and_empty_lines();
    test_device_out_of_range_ignored();

    printf("\n=== Results: %d passed, %d failed ===\n", pass_count, fail_count);
    return fail_count > 0 ? 1 : 0;
}
