//! DRM device open/auto-detect/access checks.

use crate::drm;
use log::debug;
use std::ffi::CString;
use std::os::unix::io::RawFd;
use std::path::Path;
use thiserror::Error;

/// Owned DRM device file descriptor. Closed on drop.
pub struct DrmDevice {
    path: String,
    fd: RawFd,
}

#[derive(Error, Debug)]
pub enum DeviceError {
    #[error("Cannot open {0}: {1}")]
    Open(String, std::io::Error),
    #[error("Invalid device path: {0}")]
    InvalidPath(String),
    #[error("No usable DRM device found")]
    NoDevice,
}

impl DrmDevice {
    pub fn fd(&self) -> RawFd {
        self.fd
    }
    pub fn path(&self) -> &str {
        &self.path
    }
}

impl Drop for DrmDevice {
    fn drop(&mut self) {
        if self.fd >= 0 {
            unsafe {
                libc::close(self.fd);
            }
        }
    }
}

/// Check character-device access without holding a fd. Matches C drm_device_accessible.
pub fn device_accessible(path: &str) -> bool {
    use std::os::unix::fs::FileTypeExt;
    let Ok(meta) = std::fs::metadata(path) else {
        return false;
    };
    if !meta.file_type().is_char_device() {
        return false;
    }
    // Try open to confirm we can read+write.
    let Ok(c_path) = CString::new(path) else {
        return false;
    };
    let fd = unsafe { libc::open(c_path.as_ptr(), libc::O_RDWR) };
    if fd < 0 {
        false
    } else {
        unsafe { libc::close(fd) };
        true
    }
}

/// True only if the device responds to DRM_IOCTL_MODE_GETRESOURCES with at least one CRTC.
pub fn device_has_crtcs(path: &str) -> bool {
    let Ok(c_path) = CString::new(path) else {
        return false;
    };
    let fd = unsafe { libc::open(c_path.as_ptr(), libc::O_RDWR) };
    if fd < 0 {
        return false;
    }
    let res = drm::get_resources(fd);
    unsafe { libc::close(fd) };
    matches!(res, Ok(r) if !r.crtcs.is_empty())
}

/// Find first /dev/dri/cardN with usable CRTCs; fall back to any accessible card.
pub fn find_device() -> Option<String> {
    for i in 0..10 {
        let dev = format!("/dev/dri/card{i}");
        if device_has_crtcs(&dev) {
            return Some(dev);
        }
    }
    for i in 0..10 {
        let dev = format!("/dev/dri/card{i}");
        if device_accessible(&dev) {
            return Some(dev);
        }
    }
    None
}

/// Find all /dev/dri/cardN with CRTCs, up to max_devices.
pub fn find_all_devices(max_devices: usize) -> Vec<String> {
    let mut out = Vec::new();
    for i in 0..10 {
        if out.len() >= max_devices {
            break;
        }
        let dev = format!("/dev/dri/card{i}");
        if device_has_crtcs(&dev) {
            out.push(dev);
        }
    }
    out
}

/// Open preferred device; if it lacks CRTCs or open fails, scan /dev/dri/cardN.
/// Returns the opened device along with the path actually used.
pub fn open_device(preferred: &str) -> Result<DrmDevice, DeviceError> {
    if !preferred.is_empty() && device_has_crtcs(preferred) {
        return open_raw(preferred);
    }
    debug!("Preferred device {preferred} unusable, auto-detecting");
    let found = find_device().ok_or(DeviceError::NoDevice)?;
    open_raw(&found)
}

fn open_raw(path: &str) -> Result<DrmDevice, DeviceError> {
    if !Path::new(path).exists() {
        return Err(DeviceError::InvalidPath(path.to_string()));
    }
    let c_path =
        CString::new(path).map_err(|_| DeviceError::InvalidPath(path.to_string()))?;
    let fd = unsafe { libc::open(c_path.as_ptr(), libc::O_RDWR) };
    if fd < 0 {
        return Err(DeviceError::Open(
            path.to_string(),
            std::io::Error::last_os_error(),
        ));
    }
    Ok(DrmDevice {
        path: path.to_string(),
        fd,
    })
}

/// Best-effort DRM master grab. Logs at debug on failure and continues.
/// Used by the one-shot CLI tool; the daemon skips this and relies on the
/// compositor releasing the master on TTY switch.
pub fn try_become_master(dev: &DrmDevice) {
    if let Err(e) = drm::try_set_master(dev.fd()) {
        debug!(
            "Could not become DRM master on {} ({}): compositor likely running.",
            dev.path(),
            e
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_device_accessible_nonexistent() {
        assert!(!device_accessible("/dev/dri/card99"));
    }

    #[test]
    fn test_find_all_devices_limit() {
        let devices = find_all_devices(8);
        assert!(devices.len() <= 8);
        for d in &devices {
            assert!(d.starts_with("/dev/dri/card"));
        }
    }
}
