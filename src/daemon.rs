//! Daemon mode: VT-aware time-driven gamma adjustment with inotify config reload.

use crate::config::{load_config, Config};
use crate::device;
use crate::drm;
use crate::schedule;
use crate::temperature;
use crate::vt;
use inotify::{EventMask, Inotify, WatchMask};
use log::{debug, error, info, warn};
use nix::poll::{poll, PollFd, PollFlags};
use nix::sys::signal::{self, SigAction, SigHandler, SigSet, Signal};
use nix::sys::signal::SaFlags;
use std::os::fd::{AsRawFd, BorrowedFd};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};
use thiserror::Error;

#[derive(Error, Debug)]
pub enum DaemonError {
    #[error("Config error: {0}")]
    Config(#[from] crate::config::ConfigError),
    #[error("Signal setup failed: {0}")]
    Signal(nix::Error),
}

static RELOAD_REQUESTED: AtomicBool = AtomicBool::new(false);
static STOP_REQUESTED: AtomicBool = AtomicBool::new(false);

extern "C" fn sighup_handler(_: libc::c_int) {
    RELOAD_REQUESTED.store(true, Ordering::Relaxed);
}

extern "C" fn sigterm_handler(_: libc::c_int) {
    STOP_REQUESTED.store(true, Ordering::Relaxed);
}

fn install_signal_handlers() -> Result<(), DaemonError> {
    let hup = SigAction::new(
        SigHandler::Handler(sighup_handler),
        SaFlags::empty(),
        SigSet::empty(),
    );
    let term = SigAction::new(
        SigHandler::Handler(sigterm_handler),
        SaFlags::empty(),
        SigSet::empty(),
    );
    unsafe {
        signal::sigaction(Signal::SIGHUP, &hup).map_err(DaemonError::Signal)?;
        signal::sigaction(Signal::SIGTERM, &term).map_err(DaemonError::Signal)?;
        signal::sigaction(Signal::SIGINT, &term).map_err(DaemonError::Signal)?;
    }
    info!("Signal handlers installed (SIGHUP/SIGTERM/SIGINT)");
    Ok(())
}

/// Apply a temperature to every CRTC reachable from the configured devices,
/// honoring the connector filter and gamma-size override. Returns Ok(()) if
/// at least one CRTC was successfully updated.
fn apply_temperature(config: &Config, temp: u32) -> Result<(), &'static str> {
    let mut any_success = false;

    for path in &config.devices {
        let dev = match device::open_device(path) {
            Ok(d) => d,
            Err(e) => {
                warn!("Cannot open {path}: {e}");
                continue;
            }
        };
        // Compositor may already own master; we keep going either way.
        device::try_become_master(&dev);

        let res = match drm::get_resources(dev.fd()) {
            Ok(r) => r,
            Err(e) => {
                error!("get_resources on {}: {e}", dev.path());
                continue;
            }
        };
        if res.crtcs.is_empty() {
            warn!("No CRTCs on {}", dev.path());
            continue;
        }

        let mask = drm::matching_crtc_mask(dev.fd(), &res, &config.connector);

        for (i, &crtc_id) in res.crtcs.iter().enumerate() {
            if mask & (1u32 << i) == 0 {
                continue;
            }
            let info = match drm::get_crtc(dev.fd(), crtc_id) {
                Ok(c) => c,
                Err(e) => {
                    debug!("Skip CRTC {crtc_id}: {e}");
                    continue;
                }
            };
            if !info.mode_valid || info.gamma_size == 0 {
                debug!(
                    "Skip CRTC {crtc_id} (mode_valid={} gamma_size={})",
                    info.mode_valid, info.gamma_size
                );
                continue;
            }
            // Config can override the hardware-reported size; 0 keeps it.
            let effective_size = if config.gamma_size > 0 {
                config.gamma_size as usize
            } else {
                info.gamma_size as usize
            };
            let (r, g, b) = temperature::generate_gamma_luts(effective_size, temp, 1.0);
            match drm::set_gamma(dev.fd(), crtc_id, &r, &g, &b) {
                Ok(()) => {
                    any_success = true;
                    if config.verbose {
                        info!("Applied {temp}K to {} CRTC {crtc_id}", dev.path());
                    }
                }
                Err(e) => warn!("SETGAMMA on CRTC {crtc_id}: {e}"),
            }
        }
    }

    if any_success {
        Ok(())
    } else {
        Err("no CRTCs accepted the gamma change")
    }
}

pub fn run(config_path: &str) -> Result<(), DaemonError> {
    info!("Starting drm-colortemp daemon");
    info!("Config file: {config_path}");

    install_signal_handlers()?;

    let mut config = load_config(config_path)?;
    log_startup(&config);

    let parent = config_parent(Path::new(config_path));
    let basename = config_basename(Path::new(config_path));
    let inotify_buf = vec![0u8; 4096];
    let mut inotify = setup_inotify(&parent);

    let check_interval = Duration::from_secs(config.check_interval.max(1) as u64);
    let mut last_check = Instant::now() - check_interval;
    let mut last_applied_temp: Option<u32> = None;
    let mut prev_vt: Option<Option<i32>> = None;

    while !STOP_REQUESTED.load(Ordering::Relaxed) {
        // SIGHUP → explicit reload.
        if RELOAD_REQUESTED.swap(false, Ordering::Relaxed) {
            info!("SIGHUP received, reloading config");
            match load_config(config_path) {
                Ok(c) => {
                    config = c;
                    last_applied_temp = None;
                }
                Err(e) => error!("Reload failed: {e}"),
            }
        }

        // Inotify events on the parent dir; reload when our file is touched.
        if let Some(inot) = inotify.as_mut() {
            if drain_inotify(inot, &basename, &inotify_buf) {
                info!("Config file changed");
                // Brief settle delay matches the C version (vim/nano rename race).
                std::thread::sleep(Duration::from_millis(100));
                match load_config(config_path) {
                    Ok(c) => {
                        config = c;
                        last_applied_temp = None;
                    }
                    Err(e) => error!("Reload after file change failed: {e}"),
                }
            }
        }

        // Pick the target temperature: VT override beats time-of-day.
        let now = Instant::now();
        let active_vt = vt::active_vt();
        let target_temp = choose_target_temp(&config, active_vt);

        if prev_vt != Some(active_vt) {
            if let Some(prev) = prev_vt {
                debug!("VT changed: {prev:?} -> {active_vt:?}");
            }
            prev_vt = Some(active_vt);
        }

        let should_apply = last_applied_temp != Some(target_temp)
            && now.duration_since(last_check) >= Duration::from_millis(200);
        if should_apply {
            info!("Applying {target_temp}K (VT={:?})", active_vt);
            match apply_temperature(&config, target_temp) {
                Ok(()) => last_applied_temp = Some(target_temp),
                Err(e) => error!("Apply {target_temp}K failed: {e}"),
            }
            last_check = now;
        }

        // Sleep until inotify wakes us or check_interval elapses.
        wait_for_event(inotify.as_ref().map(|i| i.as_raw_fd()), check_interval);
    }

    info!("Daemon shutting down");
    Ok(())
}

fn choose_target_temp(config: &Config, active_vt: Option<i32>) -> u32 {
    let scheduled = schedule::current_temperature(config);
    let Some(vt_num) = active_vt else {
        return scheduled;
    };
    if vt_num == config.warm_tty {
        config.night_temp
    } else if vt_num == config.cool_tty {
        config.day_temp
    } else {
        // monitor_tty and any other VT both fall back to the time-based value.
        scheduled
    }
}

fn config_parent(p: &Path) -> PathBuf {
    p.parent()
        .filter(|p| !p.as_os_str().is_empty())
        .map(Path::to_path_buf)
        .unwrap_or_else(|| PathBuf::from("."))
}

fn config_basename(p: &Path) -> String {
    p.file_name()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_default()
}

fn setup_inotify(parent: &Path) -> Option<Inotify> {
    let inot = match Inotify::init() {
        Ok(i) => i,
        Err(e) => {
            warn!("inotify init failed: {e} (config auto-reload disabled)");
            return None;
        }
    };
    // Watch the parent directory so atomic editor renames (vim/nano) keep working.
    let mask = WatchMask::CREATE | WatchMask::MOVED_TO | WatchMask::MODIFY | WatchMask::CLOSE_WRITE;
    if let Err(e) = inot.watches().add(parent, mask) {
        warn!(
            "inotify watch {} failed: {e} (config auto-reload disabled)",
            parent.display()
        );
        return None;
    }
    info!("Watching directory: {}", parent.display());
    Some(inot)
}

fn drain_inotify(inotify: &mut Inotify, basename: &str, _buf: &[u8]) -> bool {
    // Allocate a fresh buffer per call — Inotify::read_events needs &mut [u8].
    let mut buffer = [0u8; 4096];
    let mut matched = false;
    loop {
        match inotify.read_events(&mut buffer) {
            Ok(events) => {
                for ev in events {
                    if let Some(name) = ev.name {
                        if name.to_string_lossy() == basename
                            && ev.mask.intersects(
                                EventMask::CREATE
                                    | EventMask::MOVED_TO
                                    | EventMask::MODIFY
                                    | EventMask::CLOSE_WRITE,
                            )
                        {
                            matched = true;
                        }
                    }
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => break,
            Err(e) => {
                warn!("inotify read failed: {e}");
                break;
            }
        }
    }
    matched
}

fn wait_for_event(inotify_fd: Option<i32>, timeout: Duration) {
    let Some(fd) = inotify_fd else {
        // No inotify; sleep is the only knob we have.
        std::thread::sleep(timeout);
        return;
    };
    let borrowed = unsafe { BorrowedFd::borrow_raw(fd) };
    let mut fds = [PollFd::new(&borrowed, PollFlags::POLLIN)];
    let ms = timeout
        .as_millis()
        .min(i32::MAX as u128) as i32;
    // EINTR (e.g. from SIGHUP/SIGTERM) is expected and silently breaks the wait.
    let _ = poll(&mut fds, ms);
}

fn log_startup(c: &Config) {
    info!(
        "Day: {}K  Night: {}K  Sunset: {:02}:00  Sunrise: {:02}:00",
        c.day_temp, c.night_temp, c.sunset_hour, c.sunrise_hour
    );
    info!(
        "Monitor TTY {} (auto), Warm TTY {} (night), Cool TTY {} (day)",
        c.monitor_tty, c.warm_tty, c.cool_tty
    );
    if !c.connector.is_empty() {
        info!("Connector filter: {}", c.connector);
    }
    if c.gamma_size > 0 {
        info!("Gamma size override: {}", c.gamma_size);
    }
    info!("Devices: {}", c.devices.join(", "));
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cfg() -> Config {
        Config {
            day_temp: 6500,
            night_temp: 3500,
            monitor_tty: 3,
            warm_tty: 4,
            cool_tty: 5,
            sunset_hour: 20,
            sunrise_hour: 8,
            ..Config::default()
        }
    }

    #[test]
    fn test_choose_target_vt_overrides() {
        let c = cfg();
        assert_eq!(choose_target_temp(&c, Some(4)), c.night_temp);
        assert_eq!(choose_target_temp(&c, Some(5)), c.day_temp);
    }

    #[test]
    fn test_choose_target_falls_through_to_schedule() {
        let c = cfg();
        // monitor_tty / unknown / no-vt: result is whatever the schedule picks.
        let v = choose_target_temp(&c, Some(3));
        assert!(v == c.day_temp || v == c.night_temp);
        let v = choose_target_temp(&c, None);
        assert!(v == c.day_temp || v == c.night_temp);
    }

    #[test]
    fn test_config_parent_handles_no_dir() {
        // file with no directory part should resolve to "."
        let p = config_parent(Path::new("foo.conf"));
        assert_eq!(p, PathBuf::from("."));
    }

    #[test]
    fn test_config_basename() {
        assert_eq!(config_basename(Path::new("/etc/drm-colortemp.conf")), "drm-colortemp.conf");
        assert_eq!(config_basename(Path::new("foo.conf")), "foo.conf");
    }
}
