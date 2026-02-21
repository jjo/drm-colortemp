#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <xf86drm.h>
#include <xf86drmMode.h>
#include "drm_device.h"
#include "drm_colortemp_utils.h"

#define GAMMA_SIZE 256

int set_gamma_temp(int fd, uint32_t crtc_id, int gamma_size, int temp, double brightness) {
    uint16_t *red_lut, *green_lut, *blue_lut;

    if (gamma_size <= 0) {
        fprintf(stderr, "Invalid gamma size: %d\n", gamma_size);
        return -1;
    }

    // Allocate gamma ramps
    red_lut = malloc(gamma_size * sizeof(uint16_t));
    green_lut = malloc(gamma_size * sizeof(uint16_t));
    blue_lut = malloc(gamma_size * sizeof(uint16_t));

    if (!red_lut || !green_lut || !blue_lut) {
        fprintf(stderr, "Failed to allocate gamma tables\n");
        free(red_lut);
        free(green_lut);
        free(blue_lut);
        return -1;
    }

    fill_gamma_luts(gamma_size, temp, brightness, red_lut, green_lut, blue_lut);

    // Set gamma
    int ret = drmModeCrtcSetGamma(fd, crtc_id, gamma_size, red_lut, green_lut, blue_lut);

    free(red_lut);
    free(green_lut);
    free(blue_lut);

    return ret;
}

void print_usage(const char *prog) {
    printf("Usage: %s [OPTIONS]\n", prog);
    printf("Options:\n");
    printf("  -t TEMP      Color temperature in Kelvin (1000-10000, default: 6500)\n");
    printf("  -b BRIGHT    Brightness (0.1-1.0, default: 1.0)\n");
    printf("  -d DEVICE    DRM device (default: /dev/dri/card1)\n");
    printf("  -r           Reset to default (6500K, brightness 1.0)\n");
    printf("  -l           List available displays\n");
    printf("  -h           Show this help\n");
    printf("\nExamples:\n");
    printf("  %s -t 3500           # Warm (evening)\n", prog);
    printf("  %s -t 6500           # Neutral (daylight)\n", prog);
    printf("  %s -t 3500 -b 0.8    # Warm and slightly dimmed\n", prog);
    printf("  %s -r                # Reset to defaults\n", prog);
}

int main(int argc, char *argv[]) {
    const char *device = "/dev/dri/card1";
    int temp = 6500;
    double brightness = 1.0;
    int list_only = 0;
    int opt;
    int has_action = 0;  // Track if user specified any action
    
    // Parse command line arguments
    while ((opt = getopt(argc, argv, "t:b:d:rlh")) != -1) {
        switch (opt) {
            case 't':
                temp = atoi(optarg);
                if (temp < 1000 || temp > 10000) {
                    fprintf(stderr, "Temperature must be between 1000 and 10000K\n");
                    return 1;
                }
                has_action = 1;
                break;
            case 'b':
                brightness = atof(optarg);
                if (brightness < 0.1 || brightness > 1.0) {
                    fprintf(stderr, "Brightness must be between 0.1 and 1.0\n");
                    return 1;
                }
                has_action = 1;
                break;
            case 'd':
                device = optarg;
                break;
            case 'r':
                temp = 6500;
                brightness = 1.0;
                has_action = 1;
                break;
            case 'l':
                list_only = 1;
                has_action = 1;
                break;
            case 'h':
                print_usage(argv[0]);
                return 0;
            default:
                print_usage(argv[0]);
                return 1;
        }
    }
    
    // If no action specified, default to listing
    if (!has_action) {
        list_only = 1;
    }
    
    // Open DRM device (with auto-detection fallback)
    char actual_device[256];
    int fd = drm_open_device(device, actual_device, sizeof(actual_device));
    if (fd < 0) {
        fprintf(stderr, "Failed to open DRM device: %s\n", device);
        fprintf(stderr, "\nAvailable DRM devices:\n");
        system("ls -la /dev/dri/ 2>/dev/null");
        fprintf(stderr, "\nTry running with sudo or adding your user to the 'video' group\n");
        fprintf(stderr, "Or specify a device with: -d /dev/dri/cardX\n");
        return 1;
    }
    if (strcmp(actual_device, device) != 0) {
        printf("Using device: %s\n", actual_device);
    }
    
    // Try to become DRM master (will fail if compositor is running)
    if (drmSetMaster(fd) != 0) {
        fprintf(stderr, "\nWarning: Could not become DRM master (compositor is likely running)\n");
        fprintf(stderr, "This may cause 'Permission denied' errors.\n");
        fprintf(stderr, "\nTo fix this:\n");
        fprintf(stderr, "1. Switch to a TTY (Ctrl+Alt+F3), run the command there, then switch back\n");
        fprintf(stderr, "2. Or temporarily stop your compositor/display manager\n");
        fprintf(stderr, "\nContinuing anyway...\n\n");
    }
    
    // Get DRM resources
    drmModeRes *resources = drmModeGetResources(fd);
    if (!resources) {
        fprintf(stderr, "Failed to get DRM resources\n");
        close(fd);
        return 1;
    }
    
    if (list_only) {
        printf("Available displays:\n");
        for (int i = 0; i < resources->count_crtcs; i++) {
            printf("  CRTC %d: ID=%u\n", i, resources->crtcs[i]);
        }
        drmModeFreeResources(resources);
        close(fd);
        return 0;
    }
    
    printf("Setting color temperature to %dK with brightness %.2f\n", temp, brightness);
    
    // Apply to all CRTCs (displays)
    int success_count = 0;
    for (int i = 0; i < resources->count_crtcs; i++) {
        uint32_t crtc_id = resources->crtcs[i];
        drmModeCrtc *crtc = drmModeGetCrtc(fd, crtc_id);
        
        if (!crtc) {
            fprintf(stderr, "  ✗ Failed to get CRTC %u\n", crtc_id);
            continue;
        }
        
        // Skip inactive CRTCs (no mode set = no display connected)
        if (!crtc->mode_valid) {
            printf("  - Skipping inactive CRTC %u\n", crtc_id);
            drmModeFreeCrtc(crtc);
            continue;
        }
        
        // Get gamma size for this CRTC
        int gamma_size = crtc->gamma_size;
        if (gamma_size == 0) {
            fprintf(stderr, "  ✗ CRTC %u doesn't support gamma adjustment\n", crtc_id);
            drmModeFreeCrtc(crtc);
            continue;
        }
        
        printf("  Applying to CRTC %u (gamma size: %d)...", crtc_id, gamma_size);
        fflush(stdout);
        
        if (set_gamma_temp(fd, crtc_id, gamma_size, temp, brightness) == 0) {
            printf(" ✓\n");
            success_count++;
        } else {
            printf(" ✗ (error: %s)\n", strerror(errno));
        }
        
        drmModeFreeCrtc(crtc);
    }
    
    drmModeFreeResources(resources);
    close(fd);
    
    if (success_count == 0) {
        fprintf(stderr, "Failed to apply gamma to any display\n");
        return 1;
    }
    
    printf("Successfully adjusted %d display(s)\n", success_count);
    return 0;
}
