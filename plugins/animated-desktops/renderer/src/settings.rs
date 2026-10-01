//! What the person chose: the scene and the speed, from
//! ~/.config/hyprpeach/animated-desktops.json. The choices, their defaults and
//! what each means are in settings.schema.json beside the plugin's manifest,
//! which the CLI reads too; this compiles it in rather than repeating it.

use std::path::PathBuf;

use serde::Deserialize;
use serde_json::Value;

const SCHEMA: &str = include_str!("../../settings.schema.json");

/// How long a desktop switch takes (settings.schema.json says why each).
#[derive(Clone, Copy, Debug, PartialEq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Speed {
    Calm,
    Quick,
    Snappy,
}

impl Speed {
    pub fn seconds(self) -> f32 {
        match self {
            Speed::Calm => 1.6,
            Speed::Quick => 0.8,
            Speed::Snappy => 0.45,
        }
    }
}

pub struct Settings {
    pub scene: String,
    pub speed: Speed,
}

fn schema() -> Value {
    serde_json::from_str(SCHEMA).expect("settings.schema.json is JSON")
}

fn default_of(key: &str) -> Value {
    schema()["properties"][key]["default"].clone()
}

pub fn path() -> PathBuf {
    let configuration = std::env::var("XDG_CONFIG_HOME").map(PathBuf::from).unwrap_or_else(|_| PathBuf::from(std::env::var("HOME").unwrap_or_default()).join(".config"));
    configuration.join("hyprpeach/animated-desktops.json")
}

/// The file, each key falling back to the schema's default when it is missing,
/// or the file is, or a value is not one the schema allows -- said aloud, so a
/// typo in a hand edit is not silently a default.
pub fn read() -> Settings {
    let file: Value = std::fs::read_to_string(path()).ok().and_then(|text| serde_json::from_str(&text).ok()).unwrap_or(Value::Null);
    let chosen = |key: &str| -> Value {
        let value = &file[key];
        if value.is_null() { return default_of(key); }
        if schema()["properties"][key]["enum"].as_array().is_some_and(|allowed| allowed.contains(value)) { return value.clone(); }
        eprintln!("settings: {key} {value} is not one of {}; using the default", schema()["properties"][key]["enum"]);
        default_of(key)
    };
    Settings {
        scene: chosen("scene").as_str().unwrap_or_default().to_string(),
        speed: serde_json::from_value(chosen("speed")).expect("the schema's speeds are Speed's"),
    }
}

pub fn default_scene() -> String {
    default_of("scene").as_str().unwrap_or_default().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::renderer::SCENES;

    fn allowed(key: &str) -> Vec<String> {
        schema()["properties"][key]["enum"].as_array().unwrap().iter().map(|v| v.as_str().unwrap().to_string()).collect()
    }

    #[test]
    fn the_schema_lists_exactly_the_scene_files() {
        let mut files: Vec<String> = SCENES.iter().map(|(name, _)| name.to_string()).collect();
        let mut listed = allowed("scene");
        files.sort();
        listed.sort();
        assert_eq!(listed, files, "settings.schema.json's scenes and renderer/src/scenes/ disagree");
        assert!(files.contains(&default_scene()));
    }

    #[test]
    fn every_speed_in_the_schema_has_a_duration_and_the_default_is_faster_than_calm() {
        for name in allowed("speed") {
            let speed: Speed = serde_json::from_value(Value::String(name.clone())).unwrap_or_else(|_| panic!("{name} is not a Speed"));
            assert!(speed.seconds() > 0.0);
        }
        let default: Speed = serde_json::from_value(default_of("speed")).unwrap();
        assert!(default.seconds() < Speed::Calm.seconds());
    }
}
