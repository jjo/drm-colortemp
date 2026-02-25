/*
 * drm_device.h - DRM device detection and management
 * 
 * Provides utilities for finding and opening DRM devices
 */

#ifndef DRM_DEVICE_H
#define DRM_DEVICE_H

#include <stddef.h>
#include <stdint.h>

/**
 * Find and open a DRM device
 * 
 * If preferred_device is NULL or cannot be opened, searches for card0-card9
 * 
 * @param preferred_device Preferred device path (e.g. "/dev/dri/card1") or NULL
 * @param device_out Buffer to store actual device path used (min 256 bytes)
 * @param device_out_size Size of device_out buffer
 * @return File descriptor on success, -1 on error
 */
int drm_open_device(const char *preferred_device, char *device_out, size_t device_out_size);

/**
 * Check if a DRM device exists and is accessible
 *
 * @param device Device path to check
 * @return 1 if accessible, 0 otherwise
 */
int drm_device_accessible(const char *device);

/**
 * Check if a DRM device has CRTCs (display outputs)
 *
 * Some GPUs (e.g. NVIDIA with proprietary driver) may be accessible
 * but expose no CRTCs via the legacy DRM API.
 *
 * @param device Device path to check
 * @return 1 if device has CRTCs, 0 otherwise
 */
int drm_device_has_crtcs(const char *device);

/**
 * Find first available DRM card device
 * 
 * @param device_out Buffer to store device path (min 256 bytes)
 * @param device_out_size Size of device_out buffer
 * @return 0 on success, -1 if no device found
 */
int drm_find_device(char *device_out, size_t device_out_size);

#endif /* DRM_DEVICE_H */
