#ifndef DRM_COLORTEMP_UTILS_H
#define DRM_COLORTEMP_UTILS_H

#include <stdint.h>

// Color temperature to RGB multipliers (Tanner Helland algorithm)
void temp_to_rgb(int temp, double *red, double *green, double *blue);

// Fill pre-allocated gamma LUT arrays for given temperature and brightness
void fill_gamma_luts(int gamma_size, int temp, double brightness,
                     uint16_t *red, uint16_t *green, uint16_t *blue);

#endif
