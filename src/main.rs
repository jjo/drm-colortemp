//! DRM Color Temperature - Rust implementation
//!
//! Adjust screen color temperature via DRM gamma ramps. Tracks the C
//! implementation feature-for-feature (CLI + daemon).

mod config;
mod daemon;
mod device;
mod drm;
mod schedule;
mod temperature;
mod vt;

use clap::{CommandFactory, Parser};
use log::{debug, error, info, warn};
use nix::unistd::geteuid;
use std::process::ExitCode;

const DEFAULT_DEVICE: &str = "/dev/dri/card1";
const DEFAULT_DAEMON_CONFIG: &str = "/etc/default/drm-colortemp.conf";

#[derive(Parser, Debug)]
#[command(
    name = "drm-colortemp",
    author,
    version,
    about = "Adjust DRM color temperature",
    long_about = "A tool for adjusting screen color temperature via DRM (Direct Rendering Manager).\n\n\
    Examples:\n  drm-colortemp -t 6500           # Set temperature to 6500K\n  \
    drm-colortemp -t 3500 -b 0.8    # Warm temperature, 80% brightness\n  \
    drm-colortemp -l                # List available displays\n  \
    drm-colortemp -r                # Reset to defaults\n  \
    drm-colortemp --daemon -c /etc/default/drm-colortemp.conf"
)]
struct Args {
    /// Color temperature in Kelvin (1000-10000)
    #[arg(short = 't', long)]
    temperature: Option<u32>,

    /// Brightness multiplier (0.1-1.0)
    #[arg(short = 'b', long)]
    brightness: Option<f64>,

    /// DRM device path
    #[arg(short = 'd', long, default_value = DEFAULT_DEVICE)]
    device: String,

    /// Reset to default (6500K, brightness 1.0)
    #[arg(short = 'r', long)]
    reset: bool,

    /// List available displays
    #[arg(short = 'l', long)]
    list: bool,

    /// Run as daemon (background service)
    #[arg(short = 'D', long)]
    daemon: bool,

    /// Daemon config file (only used with --daemon)
    #[arg(short = 'c', long, default_value = DEFAULT_DAEMON_CONFIG)]
    config: String,

    /// Verbose output
    #[arg(short = 'v', long)]
    verbose: bool,
}

fn main() -> ExitCode {
    let args = Args::parse();
    init_logging(args.verbose);

    if args.daemon {
        if !geteuid().is_root() {
            eprintln!("Error: --daemon must run as root (DRM ioctls require it)");
            return ExitCode::from(1);
        }
        info!("Starting daemon with config: {}", args.config);
        return match daemon::run(&args.config) {
            Ok(()) => ExitCode::SUCCESS,
            Err(e) => {
                error!("Daemon error: {e}");
                eprintln!("Error: {e}");
                ExitCode::from(1)
            }
        };
    }

    if args.reset {
        info!("Resetting to default temperature (6500K)");
        return apply_temperature_cli(6500, 1.0, &args.device);
    }

    if args.list {
        return list_displays(&args.device);
    }

    if let Some(temp) = args.temperature {
        if !(1000..=10000).contains(&temp) {
            eprintln!("Temperature must be between 1000 and 10000K");
            return ExitCode::from(1);
        }
        let brightness = args.brightness.unwrap_or(1.0);
        if !(0.1..=1.0).contains(&brightness) {
            eprintln!("Brightness must be between 0.1 and 1.0");
            return ExitCode::from(1);
        }
        return apply_temperature_cli(temp, brightness, &args.device);
    }

    if let Some(brightness) = args.brightness {
        if !(0.1..=1.0).contains(&brightness) {
            eprintln!("Brightness must be between 0.1 and 1.0");
            return ExitCode::from(1);
        }
        return apply_temperature_cli(6500, brightness, &args.device);
    }

    let _ = Args::command().print_help();
    println!();
    ExitCode::SUCCESS
}

fn init_logging(verbose: bool) {
    let level = if verbose {
        log::LevelFilter::Debug
    } else {
        log::LevelFilter::Info
    };
    let _ = env_logger::Builder::from_default_env()
        .filter_level(level)
        .try_init();
}

fn apply_temperature_cli(temp: u32, brightness: f64, device_path: &str) -> ExitCode {
    info!("Setting {temp}K, brightness {brightness:.2}");

    let dev = match device::open_device(device_path) {
        Ok(d) => d,
        Err(e) => {
            error!("{e}");
            eprintln!("Error: {e}");
            eprintln!("\nAvailable DRM devices:");
            list_dev_dri_to_stderr();
            eprintln!(
                "\nTry running with sudo, or add your user to the 'video' group."
            );
            eprintln!("Or specify a device with: -d /dev/dri/cardX");
            return ExitCode::from(1);
        }
    };

    if dev.path() != device_path {
        info!("Using device: {} (preferred {} unusable)", dev.path(), device_path);
    }

    device::try_become_master(&dev);

    let res = match drm::get_resources(dev.fd()) {
        Ok(r) => r,
        Err(e) => {
            error!("GETRESOURCES failed: {e}");
            return ExitCode::from(1);
        }
    };
    if res.crtcs.is_empty() {
        error!("No CRTCs on {}", dev.path());
        return ExitCode::from(1);
    }

    let mut success = 0u32;
    for &crtc_id in &res.crtcs {
        let info = match drm::get_crtc(dev.fd(), crtc_id) {
            Ok(c) => c,
            Err(e) => {
                error!("GETCRTC {crtc_id}: {e}");
                continue;
            }
        };
        if !info.mode_valid {
            debug!("Skip inactive CRTC {crtc_id}");
            continue;
        }
        if info.gamma_size == 0 {
            warn!("CRTC {crtc_id} has no gamma support");
            continue;
        }
        let (r, g, b) =
            temperature::generate_gamma_luts(info.gamma_size as usize, temp, brightness);
        match drm::set_gamma(dev.fd(), crtc_id, &r, &g, &b) {
            Ok(()) => {
                info!("Applied to CRTC {crtc_id}");
                success += 1;
            }
            Err(e) => error!("SETGAMMA CRTC {crtc_id}: {e}"),
        }
    }

    if success == 0 {
        error!("Failed to apply gamma to any display");
        return ExitCode::from(1);
    }
    info!("Successfully adjusted {success} display(s)");
    ExitCode::SUCCESS
}

fn list_displays(device_path: &str) -> ExitCode {
    println!("Available DRM devices:");
    let devices = device::find_all_devices(8);
    if devices.is_empty() {
        println!("  No DRM devices found");
    } else {
        for (i, p) in devices.iter().enumerate() {
            let state = if device::device_accessible(p) {
                "accessible"
            } else {
                "not accessible"
            };
            println!("  {}: {p} ({state})", i + 1);
        }
    }

    println!();
    let dev = match device::open_device(device_path) {
        Ok(d) => d,
        Err(e) => {
            println!("Cannot open {device_path}: {e}");
            return ExitCode::SUCCESS;
        }
    };
    println!("Device {} details:", dev.path());
    match drm::get_resources(dev.fd()) {
        Ok(res) => {
            if res.crtcs.is_empty() {
                println!("  No CRTCs");
            } else {
                println!("  CRTCs:");
                for (i, &id) in res.crtcs.iter().enumerate() {
                    match drm::get_crtc(dev.fd(), id) {
                        Ok(info) => println!(
                            "    {}: ID={id}  gamma_size={}  mode_valid={}",
                            i, info.gamma_size, info.mode_valid
                        ),
                        Err(e) => println!("    {}: ID={id}  (GETCRTC failed: {e})", i),
                    }
                }
            }
            if !res.connectors.is_empty() {
                println!("  Connectors:");
                for &id in &res.connectors {
                    match drm::get_connector(dev.fd(), id) {
                        Ok(c) => {
                            let (long, short) = drm::connector_names(c.connector_type, c.connector_type_id);
                            println!(
                                "    ID={id}  {long} (alias {short})  encoder={}",
                                c.encoder_id
                            );
                        }
                        Err(e) => println!("    ID={id}  (GETCONNECTOR failed: {e})"),
                    }
                }
            }
        }
        Err(e) => println!("  GETRESOURCES failed: {e}"),
    }

    ExitCode::SUCCESS
}

fn list_dev_dri_to_stderr() {
    if let Ok(entries) = std::fs::read_dir("/dev/dri") {
        for entry in entries.flatten() {
            eprintln!("  {}", entry.path().display());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_temperature_validation() {
        assert!(temperature::temp_to_rgb(1000).0 >= 0.0);
        assert!(temperature::temp_to_rgb(10000).0 >= 0.0);
    }

    #[test]
    fn test_gamma_lut_sizes() {
        let (r, g, b) = temperature::generate_gamma_luts(256, 6500, 1.0);
        assert_eq!(r.len(), 256);
        assert_eq!(g.len(), 256);
        assert_eq!(b.len(), 256);
    }

    #[test]
    fn test_brightness_range_check() {
        assert!((0.1..=1.0).contains(&0.5));
        assert!(!(0.1..=1.0).contains(&0.05));
        assert!(!(0.1..=1.0).contains(&1.5));
    }
}
