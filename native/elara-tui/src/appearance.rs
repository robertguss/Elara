//! Local presentation preferences; no provider or session authority.
use ratatui::{style::Color, text::Line};
use serde_json::{Value, json};
use std::{fs, path::PathBuf};

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum ViewLayout {
    #[default]
    Ember,
    Observatory,
    Workbench,
}
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Theme {
    #[default]
    Ember,
    Observatory,
    Workbench,
    Forest,
}
macro_rules! choices {
    ($ty:ident, $($variant:ident => $name:literal),+) => {
        impl $ty {
            pub const ALL: &'static [Self] = &[$(Self::$variant),+];
            pub fn name(self) -> &'static str { match self { $(Self::$variant => $name),+ } }
            pub fn parse(value: &str) -> Result<Self, String> { Self::ALL.iter().copied().find(|v| v.name() == value).ok_or_else(|| format!("invalid {}: {value}", stringify!($ty))) }
            pub fn previous(self) -> Self { let i = Self::ALL.iter().position(|v| *v == self).unwrap(); Self::ALL[(i+Self::ALL.len()-1)%Self::ALL.len()] }
            pub fn next(self) -> Self { let i = Self::ALL.iter().position(|v| *v == self).unwrap(); Self::ALL[(i+1)%Self::ALL.len()] }
        }
    }
}
choices!(ViewLayout, Ember => "ember", Observatory => "observatory", Workbench => "workbench");
choices!(Theme, Ember => "ember", Observatory => "observatory", Workbench => "workbench", Forest => "forest");
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Appearance {
    pub layout: ViewLayout,
    pub theme: Theme,
    /// Show the dense connection/head/outcome status row under the footer.
    pub diagnostics: bool,
}
impl Appearance {
    pub fn path() -> PathBuf {
        std::env::var_os("ELARA_TUI_APPEARANCE_FILE")
            .map(PathBuf::from)
            .unwrap_or_else(|| {
                PathBuf::from(std::env::var_os("HOME").unwrap_or_default())
                    .join(".elara/tui-appearance.json")
            })
    }
    pub fn load() -> Result<Self, String> {
        Self::read(&Self::path())
    }
    pub fn read(path: &std::path::Path) -> Result<Self, String> {
        let bytes = match fs::read(path) {
            Ok(v) => v,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Self::default()),
            Err(e) => return Err(format!("Cannot read appearance: {e}")),
        };
        let v: Value = serde_json::from_slice(&bytes)
            .map_err(|e| format!("Invalid appearance preferences: {e}"))?;
        let diagnostics = match &v["diagnostics"] {
            Value::Null => false,
            Value::Bool(flag) => *flag,
            other => {
                return Err(format!(
                    "Invalid appearance preferences: diagnostics {other}"
                ));
            }
        };
        Ok(Self {
            layout: ViewLayout::parse(v["layout"].as_str().unwrap_or(""))?,
            theme: Theme::parse(v["theme"].as_str().unwrap_or(""))?,
            diagnostics,
        })
    }
    pub fn save(self) -> Result<(), String> {
        self.write(&Self::path())
    }
    pub fn write(self, path: &std::path::Path) -> Result<(), String> {
        if let Some(parent) = path.parent().filter(|p| !p.as_os_str().is_empty()) {
            fs::create_dir_all(parent).map_err(|e| e.to_string())?;
        }
        let temporary = path.with_extension(format!("{}.tmp", std::process::id()));
        fs::write(
            &temporary,
            json!({
                "layout": self.layout.name(),
                "theme": self.theme.name(),
                "diagnostics": self.diagnostics
            })
            .to_string(),
        )
        .map_err(|e| e.to_string())?;
        fs::rename(temporary, path).map_err(|e| format!("Cannot save appearance: {e}"))
    }
    pub fn lines(self) -> Vec<Line<'static>> {
        vec![
            Line::from("APPEARANCE · local presentation"),
            Line::from(""),
            Line::from(format!(
                "l / Left / Right · Layout:      {}",
                self.layout.name()
            )),
            Line::from(format!(
                "t / Up / Down    · Theme:       {}",
                self.theme.name()
            )),
            Line::from(format!(
                "d                · Diagnostics: {}",
                if self.diagnostics { "on" } else { "off" }
            )),
            Line::from(""),
            Line::from("Enter apply · s save defaults + apply · Esc cancel"),
            Line::from("F3 appearance · F4 hide/show thinking · F5 thinking view"),
            Line::from("F6 turns · Tab transcript · End follow live work · /diagnostics"),
        ]
    }
}

/// Theme-independent placeholder colors. Draw sites use these; the final
/// buffer pass in `presentation::paint` resolves them to the active theme.
/// The indexed range is reserved: nothing else in the TUI emits it.
pub mod slot {
    use ratatui::style::Color;
    pub const BASE: u8 = 232;
    pub const BACKGROUND: Color = Color::Indexed(BASE);
    pub const SURFACE: Color = Color::Indexed(BASE + 1);
    pub const THINKING_SURFACE: Color = Color::Indexed(BASE + 2);
    pub const LINE: Color = Color::Indexed(BASE + 3);
    pub const TEXT: Color = Color::Indexed(BASE + 4);
    pub const MUTED: Color = Color::Indexed(BASE + 5);
    pub const ACCENT: Color = Color::Indexed(BASE + 6);
    pub const SELECTION: Color = Color::Indexed(BASE + 7);
    pub const SUCCESS: Color = Color::Indexed(BASE + 8);
    pub const FAILURE: Color = Color::Indexed(BASE + 9);
    pub const ADDED: Color = Color::Indexed(BASE + 10);
    pub const ADDED_SURFACE: Color = Color::Indexed(BASE + 11);
    pub const REMOVED: Color = Color::Indexed(BASE + 12);
    pub const REMOVED_SURFACE: Color = Color::Indexed(BASE + 13);
    pub const LAST: u8 = BASE + 13;
}

/// All text tokens meet WCAG 4.5:1 on background, surface and selection.
#[derive(Clone, Copy, Debug)]
pub struct Tokens {
    pub background: Color,
    pub surface: Color,
    pub thinking_surface: Color,
    pub line: Color,
    pub text: Color,
    pub secondary: Color,
    pub focus: Color,
    pub selection: Color,
    pub reasoning: Color,
    pub success: Color,
    pub failure: Color,
    pub added: Color,
    pub added_surface: Color,
    pub removed: Color,
    pub removed_surface: Color,
}
const fn rgb(v: u32) -> Color {
    Color::Rgb((v >> 16) as u8, (v >> 8) as u8, v as u8)
}
impl Theme {
    // Ember/Observatory/Workbench use the approved study palettes verbatim
    // (docs/design/elara-tui-prototypes.html); Forest follows the Amp reference.
    pub fn tokens(self) -> Tokens {
        let (bg, surface, thinking, line, text, muted, accent, selection) = match self {
            Self::Ember => (
                0x151413, 0x1e1c19, 0x1e1c19, 0x39342c, 0xe5dfd4, 0xa49b8c, 0xdeb57a, 0x342e27,
            ),
            Self::Observatory => (
                0x10171b, 0x182328, 0x131e23, 0x2c4149, 0xdde9eb, 0xa0b6be, 0x8ad8cb, 0x29424a,
            ),
            Self::Workbench => (
                0x14141d, 0x20202e, 0x20202e, 0x39384e, 0xe5e3f1, 0xafabc7, 0xb9a4f5, 0x3a3452,
            ),
            Self::Forest => (
                0x0d1712, 0x18271e, 0x132019, 0x2d4234, 0xe0eee2, 0xb2cbb6, 0xc0e3ac, 0x304334,
            ),
        };
        Tokens {
            background: rgb(bg),
            surface: rgb(surface),
            thinking_surface: rgb(thinking),
            line: rgb(line),
            text: rgb(text),
            secondary: rgb(muted),
            focus: rgb(accent),
            selection: rgb(selection),
            reasoning: rgb(muted),
            success: rgb(0xa3c799),
            failure: rgb(0xe0a59d),
            added: rgb(0xafd0a5),
            added_surface: rgb(0x253028),
            removed: rgb(0xd5a59d),
            removed_surface: rgb(0x342524),
        }
    }
}
impl Tokens {
    /// Resolve a semantic slot; other colors pass through unchanged.
    pub fn resolve(&self, color: Color) -> Color {
        match color {
            Color::Indexed(index) if (slot::BASE..=slot::LAST).contains(&index) => {
                match Color::Indexed(index) {
                    slot::BACKGROUND => self.background,
                    slot::SURFACE => self.surface,
                    slot::THINKING_SURFACE => self.thinking_surface,
                    slot::LINE => self.line,
                    slot::TEXT => self.text,
                    slot::MUTED => self.secondary,
                    slot::ACCENT => self.focus,
                    slot::SELECTION => self.selection,
                    slot::SUCCESS => self.success,
                    slot::FAILURE => self.failure,
                    slot::ADDED => self.added,
                    slot::ADDED_SURFACE => self.added_surface,
                    slot::REMOVED => self.removed,
                    slot::REMOVED_SURFACE => self.removed_surface,
                    _ => unreachable!("slot range is exhaustive"),
                }
            }
            other => other,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn luminance(c: Color) -> f64 {
        let Color::Rgb(r, g, b) = c else {
            panic!("theme colors must be explicit RGB");
        };
        let linear = |v: u8| {
            let c = f64::from(v) / 255.0;
            if c <= 0.04045 {
                c / 12.92
            } else {
                ((c + 0.055) / 1.055).powf(2.4)
            }
        };
        linear(r) * 0.2126 + linear(g) * 0.7152 + linear(b) * 0.0722
    }
    fn contrast(a: Color, b: Color) -> f64 {
        let a = luminance(a);
        let b = luminance(b);
        (a.max(b) + 0.05) / (a.min(b) + 0.05)
    }
    #[test]
    fn every_text_token_has_readable_contrast_on_each_surface() {
        for theme in Theme::ALL {
            let t = theme.tokens();
            for fg in [
                t.text,
                t.secondary,
                t.focus,
                t.reasoning,
                t.success,
                t.failure,
                t.added,
                t.removed,
            ] {
                for bg in [t.background, t.surface, t.thinking_surface, t.selection] {
                    assert!(contrast(fg, bg) >= 4.5, "{theme:?} {fg:?} on {bg:?}");
                }
            }
            assert!(contrast(t.added, t.added_surface) >= 4.5);
            assert!(contrast(t.removed, t.removed_surface) >= 4.5);
        }
    }
    #[test]
    fn every_slot_resolves_and_other_colors_pass_through() {
        let t = Theme::Ember.tokens();
        for index in slot::BASE..=slot::LAST {
            assert!(matches!(t.resolve(Color::Indexed(index)), Color::Rgb(..)));
        }
        assert_eq!(t.resolve(Color::Indexed(1)), Color::Indexed(1));
        assert_eq!(t.resolve(Color::Reset), Color::Reset);
        assert_eq!(t.resolve(slot::ACCENT), t.focus);
        assert_eq!(t.resolve(slot::REMOVED_SURFACE), t.removed_surface);
    }
    #[test]
    fn preferences_round_trip_and_reject_invalid_values_without_rewriting() {
        let path =
            std::env::temp_dir().join(format!("elara-appearance-test-{}.json", std::process::id()));
        let choice = Appearance {
            layout: ViewLayout::Workbench,
            theme: Theme::Forest,
            diagnostics: true,
        };
        choice.write(&path).unwrap();
        assert_eq!(Appearance::read(&path).unwrap(), choice);
        // Preferences written before the diagnostics flag existed still load quietly.
        fs::write(&path, "{\"layout\":\"ember\",\"theme\":\"forest\"}").unwrap();
        assert!(!Appearance::read(&path).unwrap().diagnostics);
        fs::write(&path, "{\"layout\":\"bogus\",\"theme\":\"forest\"}").unwrap();
        assert!(Appearance::read(&path).is_err());
        fs::write(
            &path,
            "{\"layout\":\"ember\",\"theme\":\"forest\",\"diagnostics\":\"yes\"}",
        )
        .unwrap();
        assert!(Appearance::read(&path).is_err());
        assert!(fs::read_to_string(&path).unwrap().contains("yes"));
        fs::remove_file(path).unwrap();
        assert_eq!(choice.layout.next().previous(), choice.layout);
        assert_eq!(choice.theme.previous().next(), choice.theme);
    }
}
