//! Configuration parsing for DRM color temperature.
//!
//! INI-style KEY=VALUE parser mirroring the C version's behaviour:
//! - Out-of-range numeric values warn and keep the previous (defaulted) value.
//! - Unknown keys are silently ignored.
//! - DEVICE / DEVICE1..DEVICE8 fill an ordered device list.
//! - If no devices are specified, auto-detection runs on `load_config`.

use crate::device;
use log::{info, warn};
use std::fs::File;
use std::io::{BufRead, BufReader};
use std::path::Path;
use thiserror::Error;

pub const MAX_DEVICES: usize = 8;
pub const GAMMA_SIZE_MIN: u32 = 64;
pub const GAMMA_SIZE_MAX: u32 = 4096;

#[derive(Debug, Clone)]
pub struct Config {
    pub devices: Vec<String>,
    pub day_temp: u32,
    pub night_temp: u32,
    pub sunset_hour: u8,
    pub sunrise_hour: u8,
    pub monitor_tty: i32,
    pub warm_tty: i32,
    pub cool_tty: i32,
    pub check_interval: u32,
    pub verbose: bool,
    pub latitude: f64,
    pub longitude: f64,
    pub has_location: bool,
    pub connector: String,
    pub gamma_size: u32,
}

impl Default for Config {
    fn default() -> Self {
        // Mirror C config_defaults().
        Self {
            devices: Vec::new(),
            day_temp: 6500,
            night_temp: 3500,
            sunset_hour: 20,
            sunrise_hour: 8,
            monitor_tty: 3,
            warm_tty: 4,
            cool_tty: 5,
            check_interval: 1,
            verbose: false,
            latitude: 0.0,
            longitude: 0.0,
            has_location: false,
            connector: String::new(),
            gamma_size: 0,
        }
    }
}

#[derive(Error, Debug)]
pub enum ConfigError {
    #[error("Failed to open config file {path}: {source}")]
    Open {
        path: String,
        #[source]
        source: std::io::Error,
    },
    #[error("Failed to read config file {path}: {source}")]
    Read {
        path: String,
        #[source]
        source: std::io::Error,
    },
}

pub fn load_config<P: AsRef<Path>>(path: P) -> Result<Config, ConfigError> {
    let path_ref = path.as_ref();
    let display = path_ref.display().to_string();
    let file = File::open(path_ref).map_err(|e| ConfigError::Open {
        path: display.clone(),
        source: e,
    })?;
    let reader = BufReader::new(file);
    let mut config = Config::default();
    // Numbered devices keyed by 0-based index to preserve user ordering across gaps.
    let mut numbered: [Option<String>; MAX_DEVICES] = Default::default();
    let mut legacy_device: Option<String> = None;
    let mut line_num = 0usize;

    for line in reader.lines() {
        line_num += 1;
        let line = line.map_err(|e| ConfigError::Read {
            path: display.clone(),
            source: e,
        })?;
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }
        let Some((key_raw, value_raw)) = trimmed.split_once('=') else {
            warn!("config:{line_num}: malformed line (no '=')");
            continue;
        };
        let key = key_raw.trim();
        let value = strip_quotes(value_raw.trim());

        if key == "DEVICE" {
            legacy_device = Some(value.to_string());
            continue;
        }
        if let Some(idx) = parse_device_index(key) {
            numbered[idx] = Some(value.to_string());
            continue;
        }

        match key {
            "DAY_TEMP" => set_int_u32(&mut config.day_temp, key, value, 1000, 10000),
            "NIGHT_TEMP" => set_int_u32(&mut config.night_temp, key, value, 1000, 10000),
            "SUNSET_HOUR" => set_int_u8(&mut config.sunset_hour, key, value, 0, 23),
            "SUNRISE_HOUR" => set_int_u8(&mut config.sunrise_hour, key, value, 0, 23),
            "MONITOR_TTY" => set_int_i32(&mut config.monitor_tty, key, value, 1, 12),
            "WARM_TTY" => set_int_i32(&mut config.warm_tty, key, value, 1, 12),
            "COOL_TTY" => set_int_i32(&mut config.cool_tty, key, value, 1, 12),
            "CHECK_INTERVAL" => set_int_u32(&mut config.check_interval, key, value, 1, 3600),
            "VERBOSE" => config.verbose = parse_bool(value),
            "CONNECTOR" => config.connector = value.to_string(),
            "GAMMA_SIZE" => {
                // 0 = auto (use hardware-reported size). Non-zero must lie in [MIN,MAX].
                if value == "0" {
                    config.gamma_size = 0;
                } else {
                    set_int_u32(&mut config.gamma_size, key, value, GAMMA_SIZE_MIN, GAMMA_SIZE_MAX);
                }
            }
            "LOCATION" => parse_location(&mut config, value),
            _ => {
                // Unknown keys silently ignored to match C behaviour.
            }
        }
    }

    let mut devices: Vec<String> = numbered.into_iter().flatten().collect();
    if devices.is_empty() {
        if let Some(d) = legacy_device {
            devices.push(d);
        }
    }
    if devices.is_empty() {
        let found = device::find_all_devices(MAX_DEVICES);
        if !found.is_empty() {
            info!("Auto-detected {} DRM device(s)", found.len());
            devices = found;
        } else if let Some(d) = device::find_device() {
            devices.push(d);
        }
    }
    if devices.is_empty() {
        // Last-resort fallback so the daemon has a path to log when no DRM is present.
        devices.push("/dev/dri/card0".to_string());
    }
    config.devices = devices;

    if config.verbose {
        for (i, d) in config.devices.iter().enumerate() {
            info!("Device[{i}]: {d}");
        }
        info!(
            "Day: {}K Night: {}K Sunset: {:02}:00 Sunrise: {:02}:00",
            config.day_temp, config.night_temp, config.sunset_hour, config.sunrise_hour
        );
    }

    Ok(config)
}

fn strip_quotes(s: &str) -> &str {
    let bytes = s.as_bytes();
    if bytes.len() >= 2
        && ((bytes[0] == b'"' && bytes[bytes.len() - 1] == b'"')
            || (bytes[0] == b'\'' && bytes[bytes.len() - 1] == b'\''))
    {
        &s[1..s.len() - 1]
    } else {
        s
    }
}

fn parse_device_index(key: &str) -> Option<usize> {
    let suffix = key.strip_prefix("DEVICE")?;
    let n: usize = suffix.parse().ok()?;
    if (1..=MAX_DEVICES).contains(&n) {
        Some(n - 1)
    } else {
        None
    }
}

fn parse_location(config: &mut Config, value: &str) {
    let Some((lat, lon)) = value.split_once(',') else {
        warn!("config: LOCATION must be 'lat,lon'");
        return;
    };
    match (lat.trim().parse::<f64>(), lon.trim().parse::<f64>()) {
        (Ok(la), Ok(lo)) => {
            config.latitude = la;
            config.longitude = lo;
            config.has_location = true;
        }
        _ => warn!("config: invalid LOCATION value '{value}'"),
    }
}

fn set_int_u32(slot: &mut u32, key: &str, value: &str, min: u32, max: u32) {
    match value.parse::<i64>() {
        Ok(v) if v >= min as i64 && v <= max as i64 => *slot = v as u32,
        Ok(v) => warn!(
            "config: {key}={v} out of range [{min},{max}], keeping {}",
            *slot
        ),
        Err(_) => warn!(
            "config: invalid integer for {key}: '{value}', keeping {}",
            *slot
        ),
    }
}

fn set_int_u8(slot: &mut u8, key: &str, value: &str, min: u8, max: u8) {
    let mut tmp = *slot as u32;
    set_int_u32(&mut tmp, key, value, min as u32, max as u32);
    *slot = tmp as u8;
}

fn set_int_i32(slot: &mut i32, key: &str, value: &str, min: i32, max: i32) {
    match value.parse::<i32>() {
        Ok(v) if v >= min && v <= max => *slot = v,
        Ok(v) => warn!(
            "config: {key}={v} out of range [{min},{max}], keeping {}",
            *slot
        ),
        Err(_) => warn!(
            "config: invalid integer for {key}: '{value}', keeping {}",
            *slot
        ),
    }
}

fn parse_bool(value: &str) -> bool {
    matches!(
        value.to_ascii_lowercase().as_str(),
        "1" | "true" | "yes" | "on"
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use tempfile::NamedTempFile;

    fn write_temp_config(content: &str) -> NamedTempFile {
        let mut file = NamedTempFile::new().unwrap();
        file.write_all(content.as_bytes()).unwrap();
        file.flush().unwrap();
        file
    }

    #[test]
    fn test_default_config() {
        let c = Config::default();
        assert_eq!(c.day_temp, 6500);
        assert_eq!(c.night_temp, 3500);
        assert_eq!(c.sunset_hour, 20);
        assert_eq!(c.sunrise_hour, 8);
        assert_eq!(c.monitor_tty, 3);
        assert_eq!(c.warm_tty, 4);
        assert_eq!(c.cool_tty, 5);
    }

    #[test]
    fn test_load_simple_config() {
        let f = write_temp_config("DAY_TEMP=5500\nNIGHT_TEMP=2700\n");
        let c = load_config(f.path()).unwrap();
        assert_eq!(c.day_temp, 5500);
        assert_eq!(c.night_temp, 2700);
    }

    #[test]
    fn test_load_device_config_ordered() {
        // Numbered devices preserve user order, even with gaps.
        let f = write_temp_config("DEVICE3=/dev/dri/card2\nDEVICE1=/dev/dri/card0\n");
        let c = load_config(f.path()).unwrap();
        assert_eq!(c.devices, vec!["/dev/dri/card0", "/dev/dri/card2"]);
    }

    #[test]
    fn test_load_legacy_device_config() {
        let f = write_temp_config("DEVICE=/dev/dri/card0\n");
        let c = load_config(f.path()).unwrap();
        assert_eq!(c.devices[0], "/dev/dri/card0");
    }

    #[test]
    fn test_invalid_temp_keeps_default() {
        // Out-of-range values must NOT change the field — and certainly not error out.
        let f = write_temp_config("DAY_TEMP=99999\n");
        let c = load_config(f.path()).unwrap();
        assert_eq!(c.day_temp, 6500);
    }

    #[test]
    fn test_garbage_keeps_default() {
        let f = write_temp_config("DAY_TEMP=banana\n");
        let c = load_config(f.path()).unwrap();
        assert_eq!(c.day_temp, 6500);
    }

    #[test]
    fn test_comments_ignored() {
        let f = write_temp_config("# Comment\nDAY_TEMP=5000\n  # Indented comment\n");
        let c = load_config(f.path()).unwrap();
        assert_eq!(c.day_temp, 5000);
    }

    #[test]
    fn test_gamma_size_zero_means_auto() {
        let f = write_temp_config("GAMMA_SIZE=0\n");
        let c = load_config(f.path()).unwrap();
        assert_eq!(c.gamma_size, 0);
    }

    #[test]
    fn test_gamma_size_too_small_rejected() {
        let f = write_temp_config("GAMMA_SIZE=32\n");
        let c = load_config(f.path()).unwrap();
        // 32 < 64, kept default (0)
        assert_eq!(c.gamma_size, 0);
    }

    #[test]
    fn test_quoted_string_stripped() {
        let f = write_temp_config("CONNECTOR=\"DP-1\"\n");
        let c = load_config(f.path()).unwrap();
        assert_eq!(c.connector, "DP-1");
    }

    #[test]
    fn test_location_parsing() {
        let f = write_temp_config("LOCATION=-33.45,-70.66\n");
        let c = load_config(f.path()).unwrap();
        assert!(c.has_location);
        assert!((c.latitude - -33.45).abs() < 1e-9);
        assert!((c.longitude - -70.66).abs() < 1e-9);
    }

    #[test]
    fn test_parse_bool_variants() {
        assert!(parse_bool("yes"));
        assert!(parse_bool("YES"));
        assert!(parse_bool("on"));
        assert!(parse_bool("1"));
        assert!(parse_bool("true"));
        assert!(!parse_bool("no"));
        assert!(!parse_bool("0"));
        assert!(!parse_bool(""));
    }

    #[test]
    fn test_missing_file_returns_error() {
        let r = load_config("/nonexistent/path/drm-colortemp.conf");
        assert!(matches!(r, Err(ConfigError::Open { .. })));
    }
}
