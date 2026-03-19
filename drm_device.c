/*
 * drm_device.c - DRM device detection and management
 */

#include "drm_device.h"
#include <stdio.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <drm/drm.h>
#include <drm/drm_mode.h>

int drm_device_accessible(const char *device) {
    if (!device) {
        return 0;
    }

    struct stat st;
    if (stat(device, &st) != 0) {
        return 0;
    }

    // Check if it's a character device
    if (!S_ISCHR(st.st_mode)) {
        return 0;
    }

    // Try to open it
    int fd = open(device, O_RDWR);
    if (fd < 0) {
        return 0;
    }

    close(fd);
    return 1;
}

int drm_device_has_crtcs(const char *device) {
    int fd = open(device, O_RDWR);
    if (fd < 0) {
        return 0;
    }

    struct drm_mode_card_res res = {0};
    int ret = ioctl(fd, DRM_IOCTL_MODE_GETRESOURCES, &res);
    close(fd);

    return (ret == 0 && res.count_crtcs > 0);
}

int drm_find_device(char *device_out, size_t device_out_size) {
    // Try card0 through card9, pick the first with CRTCs
    for (int i = 0; i < 10; i++) {
        char device[64];
        snprintf(device, sizeof(device), "/dev/dri/card%d", i);

        if (drm_device_has_crtcs(device)) {
            snprintf(device_out, device_out_size, "%s", device);
            return 0;
        }
    }

    // Fallback: first accessible device (even without CRTCs)
    for (int i = 0; i < 10; i++) {
        char device[64];
        snprintf(device, sizeof(device), "/dev/dri/card%d", i);

        if (drm_device_accessible(device)) {
            snprintf(device_out, device_out_size, "%s", device);
            return 0;
        }
    }

    return -1;
}

int drm_find_all_devices(char (*devices)[256], int max_devices) {
    int count = 0;
    for (int i = 0; i < 10 && count < max_devices; i++) {
        char device[64];
        snprintf(device, sizeof(device), "/dev/dri/card%d", i);
        if (drm_device_has_crtcs(device)) {
            snprintf(devices[count], 256, "%s", device);
            count++;
        }
    }
    return count;
}

int drm_open_device(const char *preferred_device, char *device_out, size_t device_out_size) {
    int fd = -1;
    char actual_device[256] = {0};

    // Try preferred device first, but only if it has CRTCs
    if (preferred_device && preferred_device[0] != '\0') {
        if (drm_device_has_crtcs(preferred_device)) {
            fd = open(preferred_device, O_RDWR);
            if (fd >= 0) {
                snprintf(actual_device, sizeof(actual_device), "%s", preferred_device);
            }
        }
    }

    // If preferred device had no CRTCs or failed, auto-detect
    if (fd < 0) {
        char found_device[256];
        if (drm_find_device(found_device, sizeof(found_device)) == 0) {
            fd = open(found_device, O_RDWR);
            if (fd >= 0) {
                snprintf(actual_device, sizeof(actual_device), "%s", found_device);
            }
        }
    }

    // Store the device path we actually used
    if (fd >= 0 && device_out) {
        snprintf(device_out, device_out_size, "%s", actual_device);
    }

    return fd;
}
