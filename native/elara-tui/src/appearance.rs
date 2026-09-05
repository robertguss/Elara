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
        Ok(Self {
            layout: ViewLayout::parse(v["layout"].as_str().unwrap_or(""))?,
            theme: Theme::parse(v["theme"].as_str().unwrap_or(""))?,
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
            json!({"layout":self.layout.name(),"theme":self.theme.name()}).to_string(),
        )
        .map_err(|e| e.to_string())?;
        fs::rename(temporary, path).map_err(|e| format!("Cannot save appearance: {e}"))
    }
    pub fn lines(self) -> Vec<Line<'static>> {
        vec![
            Line::from("APPEARANCE · local presentation"),
            Line::from(""),
            Line::from(format!("l / Left / Right · Layout: {}", self.layout.name())),
            Line::from(format!("t / Up / Down    · Theme:  {}", self.theme.name())),
            Line::from(""),
            Line::from("Enter apply · s save defaults + apply · Esc cancel"),
            Line::from("F3 appearance · F4 hide/show thinking · F5 thinking view"),
            Line::from("F6 turns · Tab transcript · End follow live work"),
        ]
    }
}
/// All text tokens meet WCAG 4.5:1 on background, surface and selection.
#[derive(Clone, Copy, Debug)]
pub struct Tokens {
    pub background: Color,
    pub surface: Color,
    pub text: Color,
    pub secondary: Color,
    pub focus: Color,
    pub selection: Color,
    pub reasoning: Color,
    pub success: Color,
    pub failure: Color,
    pub added: Color,
    pub removed: Color,
}
const fn rgb(v: u32) -> Color {
    Color::Rgb((v >> 16) as u8, (v >> 8) as u8, v as u8)
}
impl Theme {
    pub fn tokens(self) -> Tokens {
        let (bg, surface, text, secondary, focus, selection) = match self {
            Self::Ember => (0x151413, 0x211e1a, 0xeee7dc, 0xb9af9f, 0xf0c58a, 0x433a2c),
            Self::Observatory => (0x10171b, 0x182328, 0xe3eef0, 0xaac4cc, 0x96e5d7, 0x29424a),
            Self::Workbench => (0x14141d, 0x20202e, 0xedeafa, 0xbeb8d7, 0xd0baff, 0x3a3452),
            Self::Forest => (0x0d1712, 0x18271e, 0xe0eee2, 0xb2cbb6, 0xc0e3ac, 0x304334),
        };
        Tokens {
            background: rgb(bg),
            surface: rgb(surface),
            text: rgb(text),
            secondary: rgb(secondary),
            focus: rgb(focus),
            selection: rgb(selection),
            reasoning: rgb(secondary),
            success: rgb(0xb8e3b0),
            failure: rgb(0xffb5b5),
            added: rgb(0xb8e3b0),
            removed: rgb(0xffb5b5),
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
                for bg in [t.background, t.surface, t.selection] {
                    let a = luminance(fg);
                    let b = luminance(bg);
                    assert!(
                        (a.max(b) + 0.05) / (a.min(b) + 0.05) >= 4.5,
                        "{theme:?} {fg:?} on {bg:?}"
                    );
                }
            }
        }
    }
    #[test]
    fn preferences_round_trip_and_reject_invalid_values_without_rewriting() {
        let path =
            std::env::temp_dir().join(format!("elara-appearance-test-{}.json", std::process::id()));
        let choice = Appearance {
            layout: ViewLayout::Workbench,
            theme: Theme::Forest,
        };
        choice.write(&path).unwrap();
        assert_eq!(Appearance::read(&path).unwrap(), choice);
        fs::write(&path, "{\"layout\":\"bogus\",\"theme\":\"forest\"}").unwrap();
        assert!(Appearance::read(&path).is_err());
        assert!(fs::read_to_string(&path).unwrap().contains("bogus"));
        fs::remove_file(path).unwrap();
        assert_eq!(choice.layout.next().previous(), choice.layout);
        assert_eq!(choice.theme.previous().next(), choice.theme);
    }
}
