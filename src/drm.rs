//! Low-level DRM FFI: ioctls for CRTC enumeration, gamma set, connector lookup.
//!
//! Mirrors the C code's direct ioctl path (no libdrm dependency).

use nix::{ioctl_none, ioctl_readwrite};
use std::os::unix::io::RawFd;
use thiserror::Error;

// DRM ioctl base char is 'd' (0x64). DRM_IOWR uses _IOWR(0x64, nr, ty).
const DRM_IOCTL_BASE: u8 = b'd';

#[repr(C)]
#[derive(Default)]
pub struct DrmModeCardRes {
    pub fb_id_ptr: u64,
    pub crtc_id_ptr: u64,
    pub connector_id_ptr: u64,
    pub encoder_id_ptr: u64,
    pub count_fbs: u32,
    pub count_crtcs: u32,
    pub count_connectors: u32,
    pub count_encoders: u32,
    pub min_width: u32,
    pub max_width: u32,
    pub min_height: u32,
    pub max_height: u32,
}

#[repr(C)]
#[derive(Default)]
pub struct DrmModeModeinfo {
    clock: u32,
    hdisplay: u16,
    hsync_start: u16,
    hsync_end: u16,
    htotal: u16,
    hskew: u16,
    vdisplay: u16,
    vsync_start: u16,
    vsync_end: u16,
    vtotal: u16,
    vscan: u16,
    vrefresh: u32,
    flags: u32,
    typ: u32,
    name: [u8; 32],
}

#[repr(C)]
#[derive(Default)]
pub struct DrmModeCrtc {
    pub set_connectors_ptr: u64,
    pub count_connectors: u32,
    pub crtc_id: u32,
    pub fb_id: u32,
    pub x: u32,
    pub y: u32,
    pub gamma_size: u32,
    pub mode_valid: u32,
    pub mode: DrmModeModeinfo,
}

#[repr(C)]
#[derive(Default)]
pub struct DrmModeCrtcLut {
    pub crtc_id: u32,
    pub gamma_size: u32,
    pub red: u64,
    pub green: u64,
    pub blue: u64,
}

#[repr(C)]
#[derive(Default)]
pub struct DrmModeGetConnector {
    pub encoders_ptr: u64,
    pub modes_ptr: u64,
    pub props_ptr: u64,
    pub prop_values_ptr: u64,
    pub count_modes: u32,
    pub count_props: u32,
    pub count_encoders: u32,
    pub encoder_id: u32,
    pub connector_id: u32,
    pub connector_type: u32,
    pub connector_type_id: u32,
    pub connection: u32,
    pub mm_width: u32,
    pub mm_height: u32,
    pub subpixel: u32,
    pub pad: u32,
}

#[repr(C)]
#[derive(Default)]
pub struct DrmModeGetEncoder {
    pub encoder_id: u32,
    pub encoder_type: u32,
    pub crtc_id: u32,
    pub possible_crtcs: u32,
    pub possible_clones: u32,
}

ioctl_readwrite!(drm_mode_getresources, DRM_IOCTL_BASE, 0xA0, DrmModeCardRes);
ioctl_readwrite!(drm_mode_getcrtc, DRM_IOCTL_BASE, 0xA1, DrmModeCrtc);
ioctl_readwrite!(drm_mode_setgamma, DRM_IOCTL_BASE, 0xA5, DrmModeCrtcLut);
ioctl_readwrite!(drm_mode_getencoder, DRM_IOCTL_BASE, 0xA6, DrmModeGetEncoder);
ioctl_readwrite!(
    drm_mode_getconnector,
    DRM_IOCTL_BASE,
    0xA7,
    DrmModeGetConnector
);
ioctl_none!(drm_set_master, DRM_IOCTL_BASE, 0x1e);

#[derive(Error, Debug)]
pub enum DrmIoctlError {
    #[error("DRM ioctl {0} failed: {1}")]
    Ioctl(&'static str, nix::Error),
}

/// Resources owned by a single DRM fd: crtc/connector/encoder id lists.
#[derive(Default)]
pub struct DrmResources {
    pub crtcs: Vec<u32>,
    pub connectors: Vec<u32>,
    // Encoder ids are kept in the kernel's resource struct; we don't
    // dereference them outside of the connector→encoder→crtc lookup path,
    // which uses GETENCODER directly. Keep the field for parity with the C
    // layout to make future debugging easier.
    #[allow(dead_code)]
    pub encoders: Vec<u32>,
}

/// Two-pass GETRESOURCES: first query counts, then allocate + fill.
pub fn get_resources(fd: RawFd) -> Result<DrmResources, DrmIoctlError> {
    let mut res = DrmModeCardRes::default();
    unsafe {
        drm_mode_getresources(fd, &mut res).map_err(|e| DrmIoctlError::Ioctl("GETRESOURCES", e))?;
    }

    let mut crtcs = vec![0u32; res.count_crtcs as usize];
    let mut connectors = vec![0u32; res.count_connectors as usize];
    let mut encoders = vec![0u32; res.count_encoders as usize];
    let mut fbs = vec![0u32; res.count_fbs.max(1) as usize];

    res.crtc_id_ptr = crtcs.as_mut_ptr() as u64;
    res.connector_id_ptr = connectors.as_mut_ptr() as u64;
    res.encoder_id_ptr = encoders.as_mut_ptr() as u64;
    res.fb_id_ptr = fbs.as_mut_ptr() as u64;

    unsafe {
        drm_mode_getresources(fd, &mut res).map_err(|e| DrmIoctlError::Ioctl("GETRESOURCES", e))?;
    }

    // Truncate to actual returned counts (kernel may report fewer on hot-unplug).
    crtcs.truncate(res.count_crtcs as usize);
    connectors.truncate(res.count_connectors as usize);
    encoders.truncate(res.count_encoders as usize);

    Ok(DrmResources {
        crtcs,
        connectors,
        encoders,
    })
}

pub struct CrtcInfo {
    pub gamma_size: u32,
    pub mode_valid: bool,
}

pub fn get_crtc(fd: RawFd, crtc_id: u32) -> Result<CrtcInfo, DrmIoctlError> {
    let mut c = DrmModeCrtc {
        crtc_id,
        ..Default::default()
    };
    unsafe {
        drm_mode_getcrtc(fd, &mut c).map_err(|e| DrmIoctlError::Ioctl("GETCRTC", e))?;
    }
    Ok(CrtcInfo {
        gamma_size: c.gamma_size,
        mode_valid: c.mode_valid != 0,
    })
}

pub fn set_gamma(
    fd: RawFd,
    crtc_id: u32,
    red: &[u16],
    green: &[u16],
    blue: &[u16],
) -> Result<(), DrmIoctlError> {
    debug_assert_eq!(red.len(), green.len());
    debug_assert_eq!(green.len(), blue.len());
    let mut lut = DrmModeCrtcLut {
        crtc_id,
        gamma_size: red.len() as u32,
        red: red.as_ptr() as u64,
        green: green.as_ptr() as u64,
        blue: blue.as_ptr() as u64,
    };
    unsafe {
        drm_mode_setgamma(fd, &mut lut).map_err(|e| DrmIoctlError::Ioctl("SETGAMMA", e))?;
    }
    Ok(())
}

/// Best-effort DRM master grab. C version warns and continues on failure.
pub fn try_set_master(fd: RawFd) -> Result<(), nix::Error> {
    unsafe { drm_set_master(fd) }.map(|_| ())
}

pub struct ConnectorInfo {
    pub encoder_id: u32,
    pub connector_type: u32,
    pub connector_type_id: u32,
}

pub fn get_connector(fd: RawFd, connector_id: u32) -> Result<ConnectorInfo, DrmIoctlError> {
    let mut c = DrmModeGetConnector {
        connector_id,
        ..Default::default()
    };
    unsafe {
        drm_mode_getconnector(fd, &mut c).map_err(|e| DrmIoctlError::Ioctl("GETCONNECTOR", e))?;
    }
    Ok(ConnectorInfo {
        encoder_id: c.encoder_id,
        connector_type: c.connector_type,
        connector_type_id: c.connector_type_id,
    })
}

pub fn get_encoder_crtc(fd: RawFd, encoder_id: u32) -> Result<u32, DrmIoctlError> {
    let mut e = DrmModeGetEncoder {
        encoder_id,
        ..Default::default()
    };
    unsafe {
        drm_mode_getencoder(fd, &mut e).map_err(|err| DrmIoctlError::Ioctl("GETENCODER", err))?;
    }
    Ok(e.crtc_id)
}

/// Canonical name "DisplayPort-1" and short alias "DP-1" / "HDMI-A-1" / "eDP-1".
/// Returns (long_name, short_name).
pub fn connector_names(conn_type: u32, type_id: u32) -> (String, String) {
    let (long, short) = match conn_type {
        1 => ("VGA", "VGA"),
        2 => ("DVII", "DVI-I"),
        3 => ("DVID", "DVI-D"),
        4 => ("DVIA", "DVI-A"),
        5 => ("Composite", "Composite"),
        6 => ("SVIDEO", "S-Video"),
        7 => ("LVDS", "LVDS"),
        8 => ("Component", "Component"),
        9 => ("9PinDIN", "DIN"),
        10 => ("DisplayPort", "DP"),
        11 => ("HDMIA", "HDMI-A"),
        12 => ("HDMIB", "HDMI-B"),
        13 => ("TV", "TV"),
        14 => ("eDP", "eDP"),
        15 => ("VIRTUAL", "Virtual"),
        16 => ("DSI", "DSI"),
        17 => ("DPI", "DPI"),
        18 => ("WRITEBACK", "Writeback"),
        19 => ("SPI", "SPI"),
        20 => ("USB", "USB"),
        _ => ("Unknown", "Unknown"),
    };
    (format!("{long}-{type_id}"), format!("{short}-{type_id}"))
}

/// Build bitmask of CRTC indices (within `crtcs` vec) that match the connector filter.
/// Empty filter => mask of all bits set => all CRTCs.
/// No connector matches => fall back to all CRTCs (matches C behaviour).
pub fn matching_crtc_mask(fd: RawFd, res: &DrmResources, filter: &str) -> u32 {
    if filter.is_empty() {
        return all_crtcs_mask(res.crtcs.len());
    }

    let mut mask: u32 = 0;
    for &conn_id in &res.connectors {
        let Ok(conn) = get_connector(fd, conn_id) else {
            continue;
        };
        let (long, short) = connector_names(conn.connector_type, conn.connector_type_id);
        if !filter.eq_ignore_ascii_case(&long) && !filter.eq_ignore_ascii_case(&short) {
            continue;
        }
        if conn.encoder_id == 0 {
            continue;
        }
        let Ok(crtc_id) = get_encoder_crtc(fd, conn.encoder_id) else {
            continue;
        };
        if let Some(idx) = res.crtcs.iter().position(|&c| c == crtc_id) {
            mask |= 1u32 << idx;
        }
    }

    if mask == 0 {
        all_crtcs_mask(res.crtcs.len())
    } else {
        mask
    }
}

fn all_crtcs_mask(n: usize) -> u32 {
    if n >= 32 {
        u32::MAX
    } else {
        (1u32 << n) - 1
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_connector_names() {
        let (long, short) = connector_names(10, 1);
        assert_eq!(long, "DisplayPort-1");
        assert_eq!(short, "DP-1");

        let (long, short) = connector_names(11, 2);
        assert_eq!(long, "HDMIA-2");
        assert_eq!(short, "HDMI-A-2");

        let (long, short) = connector_names(14, 1);
        assert_eq!(long, "eDP-1");
        assert_eq!(short, "eDP-1");
    }

    #[test]
    fn test_all_crtcs_mask() {
        assert_eq!(all_crtcs_mask(0), 0);
        assert_eq!(all_crtcs_mask(1), 0b1);
        assert_eq!(all_crtcs_mask(4), 0b1111);
        assert_eq!(all_crtcs_mask(32), u32::MAX);
    }
}
