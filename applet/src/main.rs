// SPDX-License-Identifier: Apache-2.0
//! COSMIC panel applet for drm-colortemp (https://github.com/jjo/drm-colortemp)
//!
//! Presents Auto / Night / Day buttons in a panel popup. Each button invokes
//! `sudo -n <bindir>/drm-colortemp-apply <mode>`, which performs the VT-switch
//! dance (chvt) that lets the drm-colortemp daemon apply gamma while COSMIC has
//! released DRM master. The accompanying sudoers rule allows exactly those three
//! commands, passwordless.

use cosmic::{
    app::{self, Core},
    applet::{menu_button, padded_control},
    cosmic_theme::Spacing,
    iced::{
        widget::column,
        window, Length,
    },
    surface, theme,
    widget::{divider, text},
    Element, Task,
};
use std::{path::Path, sync::OnceLock};

const ID: &str = "io.github.jjo.CosmicAppletColortemp";
const ICON: &str = "io.github.jjo.CosmicAppletColortemp-symbolic";
const CONF: &str = "/etc/default/drm-colortemp.conf";

/// Root helper locations, in precedence order: `install.sh` puts it in
/// `/usr/local/bin`, distro packages (.deb, AUR) in `/usr/bin`. Resolved at
/// runtime so one binary works with either layout, and so the path passed to
/// `sudo` matches the sudoers rule that was installed alongside the helper.
const HELPER_CANDIDATES: [&str; 2] = [
    "/usr/local/bin/drm-colortemp-apply",
    "/usr/bin/drm-colortemp-apply",
];

fn helper_path() -> &'static str {
    static HELPER: OnceLock<&'static str> = OnceLock::new();
    HELPER.get_or_init(|| {
        HELPER_CANDIDATES
            .into_iter()
            .find(|p| Path::new(p).exists())
            // Nothing installed: keep the source-install path so the error the
            // user sees names a concrete file.
            .unwrap_or(HELPER_CANDIDATES[0])
    })
}

fn main() -> cosmic::iced::Result {
    tracing_subscriber::fmt::init();
    cosmic::applet::run::<Window>(())
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Mode {
    Auto,
    Night,
    Day,
}

impl Mode {
    fn arg(self) -> &'static str {
        match self {
            Mode::Auto => "auto",
            Mode::Night => "night",
            Mode::Day => "day",
        }
    }

    fn label(self) -> &'static str {
        match self {
            Mode::Auto => "auto",
            Mode::Night => "night",
            Mode::Day => "day",
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq)]
enum Status {
    #[default]
    Idle,
    Applying(Mode),
    Done(Mode),
    Error(String),
}

#[derive(Debug, Clone)]
enum Message {
    TogglePopup,
    CloseRequested(window::Id),
    Apply(Mode),
    Applied(Mode, Result<(), String>),
    // Wiring point for libcosmic surface actions. Nothing in this applet emits
    // it yet (popups are driven directly via surface_task), but the handler in
    // update() is the required shape for when one does.
    #[allow(dead_code)]
    Surface(surface::Action),
}

#[derive(Default)]
struct Window {
    core: Core,
    popup: Option<window::Id>,
    status: Status,
    night_temp: u32,
    day_temp: u32,
}

/// Best-effort read of NIGHT_TEMP / DAY_TEMP from drm-colortemp's config so the
/// popup shows the temperatures that will actually be applied.
fn read_temps() -> (u32, u32) {
    let mut night = 3500;
    let mut day = 6500;
    if let Ok(conf) = std::fs::read_to_string(CONF) {
        for line in conf.lines() {
            let line = line.trim();
            for (key, slot) in [("NIGHT_TEMP=", &mut night), ("DAY_TEMP=", &mut day)] {
                if let Some(v) = line.strip_prefix(key) {
                    // Tolerate trailing whitespace/comments, matching the
                    // helper script's parsing, so the popup shows the same
                    // temps that actually get applied.
                    let v = v.split_whitespace().next().unwrap_or("");
                    if let Ok(n) = v.trim_matches(['"', '\'']).parse::<u32>() {
                        *slot = n;
                    }
                }
            }
        }
    }
    (night, day)
}

impl cosmic::Application for Window {
    type Executor = cosmic::SingleThreadExecutor;
    type Flags = ();
    type Message = Message;
    const APP_ID: &'static str = ID;

    fn core(&self) -> &Core {
        &self.core
    }

    fn core_mut(&mut self) -> &mut Core {
        &mut self.core
    }

    fn init(core: Core, _flags: Self::Flags) -> (Self, app::Task<Self::Message>) {
        let (night_temp, day_temp) = read_temps();
        (
            Self {
                core,
                popup: None,
                status: Status::Idle,
                night_temp,
                day_temp,
            },
            Task::none(),
        )
    }

    fn on_close_requested(&self, id: window::Id) -> Option<Message> {
        Some(Message::CloseRequested(id))
    }

    fn update(&mut self, message: Self::Message) -> app::Task<Self::Message> {
        match message {
            Message::TogglePopup => {
                if let Some(p) = self.popup.take() {
                    return cosmic::surface::surface_task(cosmic::surface::action::destroy_popup(
                        p,
                    ));
                } else {
                    // Refresh temps in case the config changed.
                    let (night, day) = read_temps();
                    self.night_temp = night;
                    self.day_temp = day;
                    return cosmic::surface::surface_task(cosmic::surface::action::app_popup(
                        |_| Default::default(),
                        |app: &mut Window| {
                            let new_id = window::Id::unique();
                            app.popup.replace(new_id);
                            app.core.applet.get_popup_settings(
                                app.core.main_window_id().unwrap(),
                                new_id,
                                Some((1, 1)),
                                None,
                                None,
                            )
                        },
                        None,
                    ));
                }
            }
            Message::CloseRequested(id) => {
                if Some(id) == self.popup {
                    self.popup = None;
                }
            }
            Message::Apply(mode) => {
                if matches!(self.status, Status::Applying(_)) {
                    return Task::none();
                }
                self.status = Status::Applying(mode);
                return cosmic::task::future(async move {
                    let out = tokio::process::Command::new("sudo")
                        .args(["-n", helper_path(), mode.arg()])
                        .output()
                        .await;
                    let result = match out {
                        Ok(o) if o.status.success() => Ok(()),
                        Ok(o) => {
                            let mut err =
                                String::from_utf8_lossy(&o.stderr).trim().to_string();
                            if err.contains("a password is required")
                                || err.contains("password is required")
                            {
                                err = "sudo rule missing — see /etc/sudoers.d/drm-colortemp-applet"
                                    .to_string();
                            } else if err.is_empty() {
                                err = format!("helper exited with {}", o.status);
                            }
                            Err(err)
                        }
                        Err(e) => Err(format!("could not run sudo: {e}")),
                    };
                    Message::Applied(mode, result)
                });
            }
            Message::Applied(mode, result) => {
                self.status = match result {
                    Ok(()) => Status::Done(mode),
                    Err(e) => {
                        tracing::error!("apply failed: {e}");
                        Status::Error(e)
                    }
                };
            }
            Message::Surface(a) => {
                return cosmic::task::message(cosmic::Action::Cosmic(
                    cosmic::app::Action::Surface(a),
                ));
            }
        }
        Task::none()
    }

    fn view(&self) -> Element<'_, Self::Message> {
        self.core
            .applet
            .icon_button(ICON)
            .on_press_down(Message::TogglePopup)
            .into()
    }

    fn view_window(&self, _id: window::Id) -> Element<'_, Self::Message> {
        let Spacing {
            space_xxs, space_s, ..
        } = theme::active().cosmic().spacing;

        let status_line: Element<'_, Message> = match &self.status {
            Status::Idle => {
                text::caption("Applies via a quick TTY switch — expect a brief flicker.").into()
            }
            Status::Applying(m) => {
                text::caption(format!("Applying {}\u{2026} screen will flicker", m.label()))
                    .into()
            }
            Status::Done(m) => text::caption(format!("Applied {} \u{2713}", m.label())).into(),
            Status::Error(e) => text::caption(format!("Error: {e}")).into(),
        };

        let content = column![
            menu_button(text::body("Auto (time-based)"))
                .on_press(Message::Apply(Mode::Auto)),
            menu_button(text::body(format!("Night — warm ({} K)", self.night_temp)))
                .on_press(Message::Apply(Mode::Night)),
            menu_button(text::body(format!("Day — neutral ({} K)", self.day_temp)))
                .on_press(Message::Apply(Mode::Day)),
            padded_control(divider::horizontal::default()).padding([space_xxs, space_s]),
            padded_control(status_line).width(Length::Fill),
        ]
        .padding([8, 0]);

        self.core.applet.popup_container(content).into()
    }

    fn style(&self) -> Option<cosmic::iced::theme::Style> {
        Some(cosmic::applet::style())
    }
}
