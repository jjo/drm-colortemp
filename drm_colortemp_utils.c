#include <stdint.h>
#include <math.h>
#include "drm_colortemp_utils.h"

// Color temperature algorithm based on Tanner Helland's work
// http://www.tannerhelland.com/4435/convert-temperature-rgb-algorithm-code/
void temp_to_rgb(int temp, double *red, double *green, double *blue) {
    double temp_kelvin = temp / 100.0;

    // Red calculation
    if (temp_kelvin <= 66) {
        *red = 1.0;
    } else {
        double r = temp_kelvin - 60;
        r = 329.698727446 * pow(r, -0.1332047592);
        *red = r / 255.0;
        if (*red < 0) *red = 0;
        if (*red > 1) *red = 1;
    }

    // Green calculation
    if (temp_kelvin <= 66) {
        double g = temp_kelvin;
        g = 99.4708025861 * log(g) - 161.1195681661;
        *green = g / 255.0;
    } else {
        double g = temp_kelvin - 60;
        g = 288.1221695283 * pow(g, -0.0755148492);
        *green = g / 255.0;
    }
    if (*green < 0) *green = 0;
    if (*green > 1) *green = 1;

    // Blue calculation
    if (temp_kelvin >= 66) {
        *blue = 1.0;
    } else if (temp_kelvin <= 19) {
        *blue = 0.0;
    } else {
        double b = temp_kelvin - 10;
        b = 138.5177312231 * log(b) - 305.0447927307;
        *blue = b / 255.0;
        if (*blue < 0) *blue = 0;
        if (*blue > 1) *blue = 1;
    }
}

void fill_gamma_luts(int gamma_size, int temp, double brightness,
                     uint16_t *red, uint16_t *green, uint16_t *blue) {
    double r_mult, g_mult, b_mult;

    temp_to_rgb(temp, &r_mult, &g_mult, &b_mult);

    r_mult *= brightness;
    g_mult *= brightness;
    b_mult *= brightness;

    for (int i = 0; i < gamma_size; i++) {
        double value = (double)i / (gamma_size - 1);
        red[i] = (uint16_t)(value * r_mult * 65535.0);
        green[i] = (uint16_t)(value * g_mult * 65535.0);
        blue[i] = (uint16_t)(value * b_mult * 65535.0);
    }
}
