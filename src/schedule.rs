//! Time-of-day → temperature mapping.
//!
//! Wraps the C version's behaviour: if the current local hour is in
//! `[sunset_hour, 24) ∪ [0, sunrise_hour)`, use the night temperature;
//! otherwise the day temperature. Handles the wrap when sunrise > sunset.

use crate::config::Config;
use chrono::{Local, Timelike};

pub fn current_temperature(config: &Config) -> u32 {
    let hour = Local::now().hour() as u8;
    hour_temperature(hour, config.sunset_hour, config.sunrise_hour, config.day_temp, config.night_temp)
}

fn hour_temperature(hour: u8, sunset: u8, sunrise: u8, day: u32, night: u32) -> u32 {
    // Night runs from sunset (inclusive) through sunrise (exclusive), wrapping past midnight.
    let is_night = if sunset > sunrise {
        hour >= sunset || hour < sunrise
    } else {
        // Inverted schedule (e.g. polar regions / debug configs)
        hour >= sunset && hour < sunrise
    };
    if is_night {
        night
    } else {
        day
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_evening_uses_night() {
        // sunset 20, sunrise 8, hour 22 -> night
        assert_eq!(hour_temperature(22, 20, 8, 6500, 3500), 3500);
    }

    #[test]
    fn test_predawn_uses_night() {
        // sunset 20, sunrise 8, hour 3 -> night
        assert_eq!(hour_temperature(3, 20, 8, 6500, 3500), 3500);
    }

    #[test]
    fn test_noon_uses_day() {
        assert_eq!(hour_temperature(12, 20, 8, 6500, 3500), 6500);
    }

    #[test]
    fn test_sunset_boundary_inclusive() {
        // sunset hour itself counts as night
        assert_eq!(hour_temperature(20, 20, 8, 6500, 3500), 3500);
    }

    #[test]
    fn test_sunrise_boundary_exclusive() {
        // sunrise hour itself is already day
        assert_eq!(hour_temperature(8, 20, 8, 6500, 3500), 6500);
    }
}
