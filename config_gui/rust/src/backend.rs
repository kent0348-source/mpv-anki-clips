use std::{
    collections::{BTreeMap, HashMap, HashSet},
    fs,
    io::{Read, Write},
    path::{Path, PathBuf},
};

use slint::{ModelRc, SharedString, VecModel};
use tempfile::NamedTempFile;

use crate::SettingRowData;

pub const BASE_PROFILE: &str = "mpv-anki-clips";
pub const BASE_CONFIG: &str = "mpv-anki-clips-base.conf";
pub const CORE_CONFIG: &str = "mpv-anki-clips-core.conf";
pub const PROFILES_CONFIG: &str = "mpv-anki-clips-profiles.conf";

const EXAMPLE_BASE: &str =
    include_str!("../../../src/mpv-anki-clips/exampleconfig/mpv-anki-clips-base.conf");
const EXAMPLE_CORE: &str =
    include_str!("../../../src/mpv-anki-clips/exampleconfig/mpv-anki-clips-core.conf");
const EXAMPLE_PROFILES: &str =
    include_str!("../../../src/mpv-anki-clips/exampleconfig/mpv-anki-clips-profiles.conf");

#[derive(Clone, Debug, Default)]
pub struct ConfigDocument {
    lines: Vec<String>,
}

impl ConfigDocument {
    pub fn from_text(text: &str) -> Self {
        Self {
            lines: text.split_inclusive('\n').map(str::to_owned).collect(),
        }
    }

    pub fn read(path: &Path) -> std::io::Result<Self> {
        let mut text = String::new();
        fs::File::open(path)?.read_to_string(&mut text)?;
        Ok(Self::from_text(
            text.strip_prefix('\u{feff}').unwrap_or(&text),
        ))
    }

    pub fn values(&self) -> BTreeMap<String, String> {
        let mut values = BTreeMap::new();
        for line in &self.lines {
            if let Some((key, value)) = parse_option(line) {
                values.insert(key, value);
            }
        }
        values
    }

    pub fn set_value(&mut self, key: &str, value: &str) -> Result<(), String> {
        if key.is_empty() || key.contains(['\n', '=']) {
            return Err(format!("Invalid config key: {key:?}"));
        }
        if value.contains(['\n', '\r']) {
            return Err(format!("Config values must be a single line: {key}"));
        }
        let matching: Vec<usize> = self
            .lines
            .iter()
            .enumerate()
            .filter_map(|(index, line)| {
                parse_option(line)
                    .is_some_and(|(existing, _)| existing == key)
                    .then_some(index)
            })
            .collect();
        if let Some(&index) = matching.last() {
            let line = &self.lines[index];
            let newline = if line.ends_with("\r\n") {
                "\r\n"
            } else if line.ends_with('\n') {
                "\n"
            } else {
                ""
            };
            let content = line.trim_end_matches(['\r', '\n']);
            let equals = content.find('=').expect("parsed option contains equals");
            let after_equals = &content[equals + 1..];
            let whitespace_len =
                after_equals.len() - after_equals.trim_start_matches([' ', '\t']).len();
            self.lines[index] = format!(
                "{}={}{}{}",
                &content[..equals],
                &after_equals[..whitespace_len],
                value,
                newline
            );
        } else {
            if let Some(last) = self.lines.last_mut() {
                if !last.ends_with(['\n', '\r']) {
                    last.push('\n');
                }
            }
            self.lines.push(format!("{key}={value}\n"));
        }
        Ok(())
    }

    pub fn remove_value(&mut self, key: &str) -> bool {
        let before = self.lines.len();
        self.lines
            .retain(|line| !parse_option(line).is_some_and(|(existing, _)| existing == key));
        before != self.lines.len()
    }

    pub fn text(&self) -> String {
        self.lines.concat()
    }

    pub fn write_atomic(&self, path: &Path, backup_dir: &Path) -> std::io::Result<()> {
        fs::create_dir_all(path.parent().unwrap_or_else(|| Path::new(".")))?;
        let text = self.text();
        if path.is_file() && fs::read_to_string(path)? == text {
            return Ok(());
        }
        if path.is_file() {
            fs::create_dir_all(backup_dir)?;
            fs::copy(
                path,
                backup_dir.join(format!(
                    "{}.bak",
                    path.file_name().unwrap_or_default().to_string_lossy()
                )),
            )?;
        }
        let parent = path.parent().unwrap_or_else(|| Path::new("."));
        let mut temporary = NamedTempFile::new_in(parent)?;
        temporary.write_all(text.as_bytes())?;
        temporary.as_file().sync_all()?;
        temporary.persist(path).map_err(|error| error.error)?;
        Ok(())
    }
}

fn parse_option(line: &str) -> Option<(String, String)> {
    let content = line.trim();
    if content.starts_with(['#', ';']) {
        return None;
    }
    let (key, value) = content.split_once('=')?;
    let key = key.trim();
    if key.is_empty() {
        return None;
    }
    Some((key.to_owned(), value.trim().to_owned()))
}

#[derive(Clone, Debug, Default)]
pub struct Category {
    pub name: String,
    pub keys: Vec<String>,
}

#[derive(Clone, Debug, Default)]
pub struct SettingsCatalog {
    pub profile_categories: Vec<Category>,
    pub core_categories: Vec<Category>,
    pub profile_defaults: BTreeMap<String, String>,
    pub core_defaults: BTreeMap<String, String>,
    pub profile_descriptions: BTreeMap<String, String>,
    pub core_descriptions: BTreeMap<String, String>,
}

impl SettingsCatalog {
    pub fn load() -> Self {
        let (profile_categories, profile_defaults, profile_descriptions) =
            read_catalog(EXAMPLE_BASE);
        let (core_categories, core_defaults, core_descriptions) = read_catalog(EXAMPLE_CORE);
        Self {
            profile_categories,
            core_categories,
            profile_defaults,
            core_defaults,
            profile_descriptions,
            core_descriptions,
        }
    }
}

fn read_catalog(
    text: &str,
) -> (
    Vec<Category>,
    BTreeMap<String, String>,
    BTreeMap<String, String>,
) {
    let mut categories = vec![Category {
        name: "Other settings".to_owned(),
        keys: Vec::new(),
    }];
    let mut defaults = BTreeMap::new();
    let mut descriptions = BTreeMap::new();
    let mut comments = Vec::new();
    for line in text.lines() {
        let trimmed = line.trim();
        if let Some(name) = trimmed
            .strip_prefix("## ")
            .filter(|_| !trimmed.starts_with("### "))
        {
            let name = name.trim().to_owned();
            if !categories.iter().any(|category| category.name == name) {
                categories.push(Category {
                    name: name.clone(),
                    keys: Vec::new(),
                });
            }
            comments.clear();
            continue;
        }
        if let Some(comment) = trimmed
            .strip_prefix('#')
            .filter(|_| !trimmed.starts_with("##"))
        {
            comments.push(comment.strip_prefix(' ').unwrap_or(comment).to_owned());
            continue;
        }
        if trimmed.is_empty() {
            comments.clear();
            continue;
        }
        if !trimmed.starts_with(';') {
            if let Some((key, value)) = trimmed.split_once('=') {
                let key = key.trim().to_owned();
                if !key.is_empty() {
                    categories
                        .last_mut()
                        .expect("catalog has a category")
                        .keys
                        .push(key.clone());
                    defaults.insert(key.clone(), value.trim().to_owned());
                    let description = comments.join("\n").trim().to_owned();
                    if !description.is_empty() {
                        descriptions.insert(key, description);
                    }
                }
            }
        }
        comments.clear();
    }
    categories.retain(|category| !category.keys.is_empty());
    (categories, defaults, descriptions)
}

pub fn choices_for(
    key: &str,
    current: &str,
    codec: &str,
    defaults: &BTreeMap<String, String>,
) -> Vec<String> {
    let static_choices: &[&str] = if key.starts_with("binding_scope_") {
        &["advanced-menu", "global"]
    } else {
        match key {
            "remove_arrows" => &["no", "yes", "join_arrow", "join"],
            "video_container" => &["mkv", "mp4", "webm"],
            "video_codec" => &[
                "libx264",
                "libx265",
                "libvpx",
                "libvpx-vp9",
                "libsvtav1",
                "librav1e",
                "libaom-av1",
                "av1_nvenc",
                "av1_amf",
                "av1_qsv",
            ],
            "video_quality_management" => &["enabled", "allow_combined_crf_bitrate", "disabled"],
            "video_filter" => &["enabled", "disabled"],
            "audio_codec" => &["libopus", "aac"],
            "audio_quality_management" => &["enabled", "allow_combined_vbr_bitrate", "disabled"],
            "autoclip_method" => &["clipboard", "goldendict", "custom_command"],
            "copy_text_mode" => &["single_line", "subtitle_content", "custom_pattern"],
            "copy_text_custom_scope" => &["all", "per_line"],
            "copy_text_custom_base_mode" => &["single_line", "subtitle_content"],
            "debug_level" => &["low", "basic", "advanced", "full"],
            "preview_video" => &["no", "yes", "toast"],
            "secondary_sub_visibility" => &["auto", "always", "never"],
            _ => &[],
        }
    };
    let mut choices: Vec<String> = if key == "video_preset" {
        match codec {
            "libx264" => [
                "ultrafast",
                "superfast",
                "veryfast",
                "faster",
                "fast",
                "medium",
                "slow",
                "slower",
                "veryslow",
            ]
            .iter()
            .map(|value| (*value).to_owned())
            .collect(),
            "libx265" => [
                "ultrafast",
                "superfast",
                "veryfast",
                "faster",
                "fast",
                "medium",
                "slow",
                "slower",
                "veryslow",
                "placebo",
            ]
            .iter()
            .map(|value| (*value).to_owned())
            .collect(),
            "libsvtav1" => (0..14).map(|value| value.to_string()).collect(),
            "librav1e" => (0..11).map(|value| value.to_string()).collect(),
            "libaom-av1" => (0..14).map(|value| value.to_string()).collect(),
            "av1_nvenc" => (1..9).map(|value| format!("p{value}")).collect(),
            "av1_amf" => ["quality", "balanced", "speed"]
                .iter()
                .map(|value| (*value).to_owned())
                .collect(),
            "av1_qsv" => (1..8).map(|value| value.to_string()).collect(),
            _ => Vec::new(),
        }
    } else if !static_choices.is_empty() {
        static_choices
            .iter()
            .map(|value| (*value).to_owned())
            .collect()
    } else if defaults
        .get(key)
        .is_some_and(|value| matches!(value.to_lowercase().as_str(), "yes" | "no"))
    {
        vec!["yes".to_owned(), "no".to_owned()]
    } else {
        Vec::new()
    };
    if !choices.is_empty() && !choices.iter().any(|choice| choice == current) {
        choices.push(current.to_owned());
    }
    choices
}

pub fn dependencies_met(key: &str, values: &BTreeMap<String, String>) -> bool {
    let dependencies: &[&str] = match key {
        "include_external_subtitles" => &["include_subtitles"],
        "external_subtitle_unknown_language" => &["include_external_subtitles"],
        "video_codec"
        | "video_quality_management"
        | "video_filter"
        | "video_bitrate"
        | "video_use_crf"
        | "video_crf"
        | "video_two_pass"
        | "video_width"
        | "video_height"
        | "video_fps"
        | "video_preset"
        | "video_custom_args"
        | "video_padding" => &["enable_video"],
        "audio_codec"
        | "audio_quality_management"
        | "audio_bitrate"
        | "audio_use_vbr"
        | "audio_custom_args"
        | "audio_fade_in"
        | "audio_fade_out"
        | "loudnorm_enabled" => &["enable_audio"],
        "loudnorm_two_pass" | "loudnorm_I" | "loudnorm_LRA" | "loudnorm_TP" | "loudnorm_linear" => {
            &["enable_audio", "loudnorm_enabled"]
        }
        _ => &[],
    };
    dependencies.iter().all(|dependency| {
        matches!(
            values
                .get(*dependency)
                .map(String::as_str)
                .unwrap_or("yes")
                .to_ascii_lowercase()
                .as_str(),
            "yes" | "true" | "1" | "enabled"
        )
    })
}

#[derive(Clone)]
pub struct ConfigStore {
    pub config_root: PathBuf,
    pub script_opts: PathBuf,
    pub backup_directory: PathBuf,
}

impl ConfigStore {
    pub fn new(root: PathBuf) -> std::io::Result<Self> {
        let root = if root.is_absolute() {
            root
        } else {
            std::env::current_dir()?.join(root)
        };
        let root = fs::canonicalize(&root).or_else(|_| Ok::<_, std::io::Error>(root.clone()))?;
        let backup_directory = std::env::current_exe()?
            .parent()
            .unwrap_or_else(|| Path::new("."))
            .join("config-backups");
        Ok(Self {
            script_opts: root.join("script-opts"),
            config_root: root,
            backup_directory,
        })
    }

    pub fn ensure_defaults(&self, catalog: &SettingsCatalog) -> Result<(), String> {
        fs::create_dir_all(&self.script_opts).map_err(|error| error.to_string())?;
        for (name, example) in [
            (CORE_CONFIG, EXAMPLE_CORE),
            (BASE_CONFIG, EXAMPLE_BASE),
            (PROFILES_CONFIG, EXAMPLE_PROFILES),
        ] {
            let target = self.script_opts.join(name);
            if !target.exists() {
                fs::write(target, example).map_err(|error| error.to_string())?;
            }
        }
        self.normalize(catalog)
    }

    fn read(&self, filename: &str) -> Result<ConfigDocument, String> {
        ConfigDocument::read(&self.script_opts.join(filename)).map_err(|error| error.to_string())
    }

    fn write(&self, filename: &str, document: &ConfigDocument) -> Result<(), String> {
        document
            .write_atomic(&self.script_opts.join(filename), &self.backup_directory)
            .map_err(|error| error.to_string())
    }

    pub fn read_core(&self) -> Result<ConfigDocument, String> {
        self.read(CORE_CONFIG)
    }
    pub fn read_profiles(&self) -> Result<ConfigDocument, String> {
        self.read(PROFILES_CONFIG)
    }

    pub fn profile_filename(profile: &str) -> Result<String, String> {
        validate_profile_name(profile)?;
        Ok(if profile == BASE_PROFILE {
            BASE_CONFIG.to_owned()
        } else {
            format!("{profile}.conf")
        })
    }

    pub fn read_profile(&self, profile: &str) -> Result<ConfigDocument, String> {
        self.read(&Self::profile_filename(profile)?)
    }

    pub fn profile_names(&self) -> Result<Vec<String>, String> {
        let values = self.read_profiles()?.values();
        let names: Vec<String> = values
            .get("profiles")
            .ok_or_else(|| format!("The profiles option is missing in {PROFILES_CONFIG}."))?
            .split(',')
            .map(str::trim)
            .filter(|name| !name.is_empty())
            .map(str::to_owned)
            .collect();
        if names.is_empty() {
            return Err(format!(
                "The profiles option is empty in {PROFILES_CONFIG}."
            ));
        }
        let unique: HashSet<&str> = names.iter().map(String::as_str).collect();
        if unique.len() != names.len() {
            return Err("The profiles option contains duplicate profile names.".to_owned());
        }
        for name in &names {
            validate_profile_name(name)?;
        }
        if !names.iter().any(|name| name == BASE_PROFILE) {
            return Err(format!(
                "The profile list must include the required base profile '{BASE_PROFILE}'."
            ));
        }
        Ok(names)
    }

    pub fn active_profile(&self) -> Result<String, String> {
        let values = self.read_profiles()?.values();
        let active = values
            .get("active")
            .map(String::as_str)
            .unwrap_or(BASE_PROFILE);
        if !self.profile_names()?.iter().any(|name| name == active) {
            return Err(format!(
                "The active profile '{active}' is not listed in {PROFILES_CONFIG}."
            ));
        }
        Ok(active.to_owned())
    }

    pub fn base_values(
        &self,
        catalog: &SettingsCatalog,
    ) -> Result<BTreeMap<String, String>, String> {
        let mut values = catalog.profile_defaults.clone();
        values.extend(self.read_profile(BASE_PROFILE)?.values());
        Ok(values)
    }

    pub fn effective_profile_values(
        &self,
        profile: &str,
        catalog: &SettingsCatalog,
    ) -> Result<BTreeMap<String, String>, String> {
        let mut values = self.base_values(catalog)?;
        if profile != BASE_PROFILE {
            values.extend(self.read_profile(profile)?.values());
        }
        Ok(values)
    }

    pub fn set_profile_names(&self, names: &[String], active: &str) -> Result<(), String> {
        if names.is_empty() || !names.iter().any(|name| name == BASE_PROFILE) {
            return Err(format!(
                "The required base profile '{BASE_PROFILE}' cannot be removed."
            ));
        }
        let unique: HashSet<&str> = names.iter().map(String::as_str).collect();
        if unique.len() != names.len() {
            return Err("Profile names must be unique.".to_owned());
        }
        for name in names {
            validate_profile_name(name)?;
        }
        if !names.iter().any(|name| name == active) {
            return Err("The active profile must be included in the profile list.".to_owned());
        }
        let mut document = self.read_profiles()?;
        document.set_value("profiles", &names.join(","))?;
        document.set_value("active", active)?;
        self.write(PROFILES_CONFIG, &document)
    }

    pub fn add_profile(&self, name: &str) -> Result<(), String> {
        validate_profile_name(name)?;
        let mut names = self.profile_names()?;
        if names.iter().any(|existing| existing == name) {
            return Err(format!("Profile '{name}' already exists."));
        }
        let filename = Self::profile_filename(name)?;
        let path = self.script_opts.join(&filename);
        if path.exists() {
            return Err(format!(
                "A config file already exists for profile '{name}': {}",
                path.display()
            ));
        }
        let document = ConfigDocument::from_text(&format!(
            "# Profile overrides for {name}.\n# Unspecified values inherit from {BASE_CONFIG}.\n"
        ));
        self.write(&filename, &document)?;
        names.push(name.to_owned());
        self.set_profile_names(&names, &self.active_profile()?)
    }

    pub fn rename_profile(&self, old: &str, new: &str) -> Result<(), String> {
        validate_profile_name(new)?;
        if old == BASE_PROFILE {
            return Err("The base profile cannot be renamed.".to_owned());
        }
        let names = self.profile_names()?;
        if !names.iter().any(|name| name == old) {
            return Err(format!("Profile '{old}' is not in the profile list."));
        }
        if names.iter().any(|name| name == new) {
            return Err(format!("Profile '{new}' already exists."));
        }
        let old_path = self.script_opts.join(Self::profile_filename(old)?);
        let new_path = self.script_opts.join(Self::profile_filename(new)?);
        if new_path.exists() {
            return Err(format!(
                "A config file already exists for profile '{new}': {}",
                new_path.display()
            ));
        }
        let active = self.active_profile()?;
        fs::rename(&old_path, &new_path).map_err(|error| error.to_string())?;
        let renamed: Vec<String> = names
            .iter()
            .map(|name| {
                if name == old {
                    new.to_owned()
                } else {
                    name.clone()
                }
            })
            .collect();
        let result = self.set_profile_names(&renamed, if active == old { new } else { &active });
        if result.is_err() {
            let _ = fs::rename(&new_path, &old_path);
        }
        result
    }

    pub fn remove_profile(&self, name: &str) -> Result<(), String> {
        if name == BASE_PROFILE {
            return Err("The base profile cannot be removed.".to_owned());
        }
        let names = self.profile_names()?;
        if !names.iter().any(|item| item == name) {
            return Err(format!("Profile '{name}' is not in the profile list."));
        }
        let active = self.active_profile()?;
        let remaining: Vec<String> = names.into_iter().filter(|item| item != name).collect();
        self.set_profile_names(
            &remaining,
            if active == name {
                BASE_PROFILE
            } else {
                &active
            },
        )
    }

    pub fn save_profile_values(
        &self,
        profile: &str,
        values: &BTreeMap<String, String>,
        base_values: &BTreeMap<String, String>,
    ) -> Result<(), String> {
        let filename = Self::profile_filename(profile)?;
        let mut document = self.read(&filename)?;
        for (key, value) in values {
            if profile != BASE_PROFILE && base_values.get(key) == Some(value) {
                document.remove_value(key);
            } else {
                document.set_value(key, value)?;
            }
        }
        self.write(&filename, &document)
    }

    fn normalize(&self, catalog: &SettingsCatalog) -> Result<(), String> {
        let names = self.profile_names()?;
        let active = self.active_profile()?;
        let mut core = self.read_core()?;
        let mut profile_docs = BTreeMap::new();
        for name in &names {
            profile_docs.insert(name.clone(), self.read_profile(name)?);
        }
        let mut core_values = core.values();
        if !core_values.contains_key("menu_key_open") {
            let default = catalog
                .core_defaults
                .get("menu_key_open")
                .ok_or("Bundled core config lacks menu_key_open")?;
            core.set_value("menu_key_open", default)?;
            core_values.insert("menu_key_open".to_owned(), default.clone());
        }

        let core_keys: HashSet<&str> = catalog.core_defaults.keys().map(String::as_str).collect();
        let profile_keys: HashSet<&str> = catalog
            .profile_defaults
            .keys()
            .map(String::as_str)
            .collect();
        let mut migration_order = vec![active, BASE_PROFILE.to_owned()];
        for name in &names {
            if !migration_order.contains(name) {
                migration_order.push(name.clone());
            }
        }
        let mut migrated_core: HashMap<String, Vec<String>> = HashMap::new();
        for name in &migration_order {
            for (key, value) in profile_docs[name].values() {
                if core_keys.contains(key.as_str()) && !profile_keys.contains(key.as_str()) {
                    migrated_core.entry(key).or_default().push(value);
                }
            }
        }
        for (key, candidates) in migrated_core {
            let current = core_values.get(&key);
            let default = &catalog.core_defaults[&key];
            if current.is_none_or(|value| value == default) {
                let migrated = candidates
                    .iter()
                    .find(|value| *value != default)
                    .unwrap_or(&candidates[0]);
                if current != Some(migrated) {
                    core.set_value(&key, migrated)?;
                    core_values.insert(key, migrated.clone());
                }
            }
        }
        let mut base = profile_docs
            .get(BASE_PROFILE)
            .cloned()
            .ok_or("Required base profile is missing")?;
        let mut base_values = base.values();
        for (key, value) in core.values() {
            if profile_keys.contains(key.as_str()) && !core_keys.contains(key.as_str()) {
                let default = &catalog.profile_defaults[&key];
                let current = base_values.get(&key);
                if (current.is_none() || current == Some(default)) && value != *default {
                    base.set_value(&key, &value)?;
                    base_values.insert(key, value);
                }
            }
        }
        profile_docs.insert(BASE_PROFILE.to_owned(), base);

        let profile_list_keys: HashSet<String> = ConfigDocument::from_text(EXAMPLE_PROFILES)
            .values()
            .into_keys()
            .collect();
        for key in core.values().keys().cloned().collect::<Vec<_>>() {
            if !catalog.core_defaults.contains_key(&key) {
                core.remove_value(&key);
            }
        }
        for key in self
            .read_profiles()?
            .values()
            .keys()
            .cloned()
            .collect::<Vec<_>>()
        {
            if !profile_list_keys.contains(&key) {
                let mut doc = self.read_profiles()?;
                doc.remove_value(&key);
                self.write(PROFILES_CONFIG, &doc)?;
            }
        }
        for (name, mut document) in profile_docs {
            let filename = Self::profile_filename(&name)?;
            for key in document.values().keys().cloned().collect::<Vec<_>>() {
                if !catalog.profile_defaults.contains_key(&key) {
                    document.remove_value(&key);
                }
            }
            self.write(&filename, &document)?;
        }
        self.write(CORE_CONFIG, &core)
    }
}

pub fn validate_profile_name(name: &str) -> Result<(), String> {
    let bytes = name.as_bytes();
    if bytes.is_empty()
        || bytes.len() > 64
        || !bytes[0].is_ascii_alphanumeric()
        || !bytes
            .iter()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-'))
    {
        return Err("Profile names must start with a letter or number and contain only letters, numbers, underscores, or hyphens (up to 64 characters).".to_owned());
    }
    Ok(())
}

fn row_model(rows: Vec<SettingRowData>) -> ModelRc<SettingRowData> {
    ModelRc::new(VecModel::from(rows))
}

#[derive(Clone, Copy)]
pub enum PageKind {
    Core,
    Bindings,
    Profile,
}

pub struct SettingsPage {
    pub kind: PageKind,
    pub profile: Option<String>,
    pub values: BTreeMap<String, String>,
    pub base_values: BTreeMap<String, String>,
    pub original_values: BTreeMap<String, String>,
    pub original_raw: BTreeMap<String, String>,
    pub rows: Vec<SettingRowData>,
}

impl SettingsPage {
    pub fn new(kind: PageKind) -> Self {
        Self {
            kind,
            profile: None,
            values: BTreeMap::new(),
            base_values: BTreeMap::new(),
            original_values: BTreeMap::new(),
            original_raw: BTreeMap::new(),
            rows: Vec::new(),
        }
    }

    pub fn is_dirty(&self) -> bool {
        self.values != self.original_values
    }

    pub fn build_rows(&mut self, catalog: &SettingsCatalog) {
        if matches!(self.kind, PageKind::Bindings) {
            self.rows = build_binding_rows(self, catalog);
            return;
        }

        let (categories, defaults, descriptions) = match self.kind {
            PageKind::Core | PageKind::Bindings => (
                &catalog.core_categories,
                &catalog.core_defaults,
                &catalog.core_descriptions,
            ),
            PageKind::Profile => (
                &catalog.profile_categories,
                &catalog.profile_defaults,
                &catalog.profile_descriptions,
            ),
        };
        let mut rows = Vec::new();
        for category in categories {
            let keys: Vec<&String> = category
                .keys
                .iter()
                .filter(|key| match self.kind {
                    PageKind::Core => {
                        !key.starts_with("menu_key_")
                            && !key.starts_with("global_key_")
                            && !key.starts_with("binding_scope_")
                    }
                    PageKind::Bindings => false,
                    PageKind::Profile => true,
                })
                .collect();
            if keys.is_empty() {
                continue;
            }
            rows.push(make_row(
                category.name.clone(),
                String::new(),
                RowOptions {
                    category: true,
                    ..RowOptions::default()
                },
            ));
            for key in keys {
                let value = self.values.get(key).cloned().unwrap_or_default();
                let label = key
                    .strip_prefix("binding_scope_")
                    .map(|setting| {
                        let action = setting
                            .strip_prefix("menu_key_")
                            .or_else(|| setting.strip_prefix("global_key_"))
                            .unwrap_or(setting);
                        format!("Scope: {}", action.replace('_', " "))
                    })
                    .or_else(|| {
                        key.strip_prefix("menu_key_")
                            .or_else(|| key.strip_prefix("global_key_"))
                            .map(|action| format!("Key: {}", action.replace('_', " ")))
                    })
                    .unwrap_or_else(|| key.replace('_', " "));
                let codec = self
                    .values
                    .get("video_codec")
                    .map(String::as_str)
                    .unwrap_or("libsvtav1");
                let choices = choices_for(key, &value, codec, defaults);
                let choice_index = choices
                    .iter()
                    .position(|choice| choice == &value)
                    .unwrap_or(0) as i32;
                let enabled = dependencies_met(key, &self.values);
                let has_inherit = matches!(self.kind, PageKind::Profile)
                    && self.profile.as_deref() != Some(BASE_PROFILE);
                rows.push(make_row(
                    label,
                    key.clone(),
                    RowOptions {
                        base_value: self.base_values.get(key).cloned().unwrap_or_default(),
                        default_value: defaults.get(key).cloned().unwrap_or_default(),
                        choice_index,
                        choices,
                        scope_value: String::new(),
                        scope_choice_index: -1,
                        scope_choices: Vec::new(),
                        description: descriptions.get(key).cloned().unwrap_or_default(),
                        enabled,
                        has_inherit,
                        category: false,
                    },
                ));
            }
        }
        self.rows = rows;
    }
}

const BINDING_SCOPE_CHOICES: &[(&str, &str)] = &[
    ("advanced-menu", "Advanced menu only"),
    ("global", "Global (any time)"),
];

const BINDING_CATEGORY_ORDER: &[&str] = &[
    "Capture and timing",
    "Playback and subtitles",
    "Clipboard and auto-copy",
    "Export and Anki",
    "Menu and display",
];

fn binding_category(key: &str) -> &'static str {
    let action = key
        .strip_prefix("menu_key_")
        .or_else(|| key.strip_prefix("global_key_"))
        .unwrap_or(key);
    if action.starts_with("set_start")
        || action.starts_with("set_end")
        || matches!(
            action,
            "capture_current"
                | "clear_capture_resume"
                | "clear_capture_stop"
                | "toggle_capture"
                | "reset_all"
                | "load_last_timings"
        )
    {
        "Capture and timing"
    } else if action.starts_with("seek_")
        || action.starts_with("secondary_")
        || matches!(
            action,
            "sub_rewind"
                | "sub_replay"
                | "sub_play_to_next"
                | "restart_mpv_current_file"
                | "remove_current_subtitle"
                | "toggle_subtitle_export"
        )
    {
        "Playback and subtitles"
    } else if action.starts_with("copy_")
        || matches!(action, "toggle_autoclip" | "cycle_autoclip_method")
    {
        "Clipboard and auto-copy"
    } else if matches!(
        action,
        "gui_export"
            | "export_note"
            | "update_selected"
            | "overwrite_selected"
            | "update_last"
            | "overwrite_last"
            | "test_encode"
            | "refresh_anki_preview"
            | "toggle_target_preview"
            | "increment_cards"
            | "decrement_cards"
            | "repeat_export_overwrite"
            | "repeat_export_respect"
    ) {
        "Export and Anki"
    } else {
        "Menu and display"
    }
}

fn binding_action_label(key: &str) -> String {
    let action = key
        .strip_prefix("menu_key_")
        .or_else(|| key.strip_prefix("global_key_"))
        .unwrap_or(key);
    let mut label = action.replace('_', " ");
    if let Some(first) = label.get_mut(0..1) {
        first.make_ascii_uppercase();
    }
    label
}

fn build_binding_rows(page: &SettingsPage, catalog: &SettingsCatalog) -> Vec<SettingRowData> {
    let mut groups: BTreeMap<&str, Vec<&String>> = BTreeMap::new();
    for category in &catalog.core_categories {
        for key in &category.keys {
            if key.starts_with("menu_key_") || key.starts_with("global_key_") {
                groups.entry(binding_category(key)).or_default().push(key);
            }
        }
    }

    let mut rows = Vec::new();
    for category in BINDING_CATEGORY_ORDER {
        let Some(keys) = groups.get_mut(category) else {
            continue;
        };
        if keys.is_empty() {
            continue;
        }
        rows.push(make_row(
            (*category).to_owned(),
            String::new(),
            RowOptions {
                category: true,
                ..RowOptions::default()
            },
        ));
        keys.sort_by_key(|key| binding_action_label(key));
        for key in keys.iter() {
            let scope_key = format!("binding_scope_{key}");
            let scope = page
                .values
                .get(&scope_key)
                .map(String::as_str)
                .unwrap_or_default();
            let scope_choice_index = BINDING_SCOPE_CHOICES
                .iter()
                .position(|(value, _)| *value == scope)
                .map(|index| index as i32)
                .unwrap_or(-1);
            let scope_label = BINDING_SCOPE_CHOICES
                .iter()
                .find(|(value, _)| *value == scope)
                .map(|(_, label)| (*label).to_owned())
                .unwrap_or_else(|| format!("Invalid scope: {scope}"));
            rows.push(make_row(
                binding_action_label(key),
                (*key).clone(),
                RowOptions {
                    default_value: catalog.core_defaults.get(*key).cloned().unwrap_or_default(),
                    description: catalog
                        .core_descriptions
                        .get(*key)
                        .cloned()
                        .unwrap_or_default(),
                    enabled: true,
                    scope_value: scope_label,
                    scope_choice_index,
                    scope_choices: BINDING_SCOPE_CHOICES
                        .iter()
                        .map(|(_, label)| (*label).to_owned())
                        .collect(),
                    ..RowOptions::default()
                },
            ));
        }
    }
    rows
}

#[derive(Default)]
struct RowOptions {
    base_value: String,
    default_value: String,
    choice_index: i32,
    choices: Vec<String>,
    scope_value: String,
    scope_choice_index: i32,
    scope_choices: Vec<String>,
    description: String,
    enabled: bool,
    has_inherit: bool,
    category: bool,
}

fn make_row(label: String, key: String, options: RowOptions) -> SettingRowData {
    SettingRowData {
        key: SharedString::from(key),
        label: SharedString::from(label),
        value: SharedString::default(),
        base_value: SharedString::from(options.base_value),
        default_value: SharedString::from(options.default_value),
        choice_index: options.choice_index,
        choices: ModelRc::new(VecModel::from(
            options
                .choices
                .into_iter()
                .map(SharedString::from)
                .collect::<Vec<_>>(),
        )),
        scope_value: SharedString::from(options.scope_value),
        scope_choice_index: options.scope_choice_index,
        scope_choices: ModelRc::new(VecModel::from(
            options
                .scope_choices
                .into_iter()
                .map(SharedString::from)
                .collect::<Vec<_>>(),
        )),
        description: SharedString::from(options.description),
        enabled: options.enabled,
        has_inherit: options.has_inherit,
        category: options.category,
    }
}

pub fn update_rows(page: &mut SettingsPage, catalog: &SettingsCatalog) -> ModelRc<SettingRowData> {
    page.build_rows(catalog);
    for row in &mut page.rows {
        if !row.category {
            row.value = SharedString::from(
                page.values
                    .get(row.key.as_str())
                    .cloned()
                    .unwrap_or_default(),
            );
        }
    }
    row_model(page.rows.clone())
}

pub fn default_config_root() -> PathBuf {
    #[cfg(target_os = "windows")]
    {
        if let Some(appdata) = std::env::var_os("APPDATA") {
            return PathBuf::from(appdata).join("mpv");
        }
    }
    #[cfg(target_os = "macos")]
    {
        return dirs::home_dir()
            .unwrap_or_else(|| PathBuf::from("."))
            .join(".config/mpv");
    }
    let config = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .or_else(|| dirs::home_dir().map(|home| home.join(".config")))
        .unwrap_or_else(|| PathBuf::from(".config"));
    config.join("mpv")
}

pub fn validate_key_bindings(values: &BTreeMap<String, String>) -> Result<(), String> {
    let mut assigned: HashMap<(String, String), String> = HashMap::new();
    let modifiers = ["ctrl", "control", "alt", "shift", "meta", "cmd", "super"];
    let mut duplicates = Vec::new();
    for (key, raw) in values {
        let value = raw.trim();
        if !key.starts_with("menu_key_") && !key.starts_with("global_key_") {
            continue;
        }
        let scope_key = format!("binding_scope_{key}");
        let context = match values.get(&scope_key).map(String::as_str) {
            Some("advanced-menu") => "advanced-menu",
            Some("global") => "global",
            Some(scope) => {
                return Err(format!(
                    "Invalid binding scope '{scope}' for shortcut '{key}'; choose advanced-menu or global."
                ))
            }
            None => {
                return Err(format!(
                    "Missing binding scope setting '{scope_key}' for shortcut '{key}'."
                ))
            }
        };
        if value.is_empty() {
            continue;
        }
        if value.chars().any(char::is_whitespace) {
            return Err(format!(
                "Invalid mpv key binding '{value}': spaces are not allowed."
            ));
        }
        let mut parts: Vec<&str> = value.split('+').collect();
        if parts.len() < 2 || parts.iter().any(|part| part.is_empty()) {
            if parts.iter().any(|part| part.is_empty()) {
                return Err(format!(
                    "Invalid mpv key binding '{value}': empty key or modifier."
                ));
            }
            if !valid_key_token(parts[0])
                || modifiers.contains(&parts[0].to_ascii_lowercase().as_str())
            {
                return Err(format!(
                    "Invalid mpv key binding '{value}': enter one mpv key name."
                ));
            }
        } else {
            let key_part = parts.pop().unwrap_or_default();
            let mut used = HashSet::new();
            for modifier in &parts {
                let normalized = modifier.to_ascii_lowercase();
                if !modifiers.contains(&normalized.as_str()) {
                    return Err(format!("Invalid mpv key binding '{value}': modifiers must be Ctrl, Alt, Shift, Meta, Cmd, or Super."));
                }
                if !used.insert(normalized) {
                    return Err(format!(
                        "Invalid mpv key binding '{value}': a modifier is repeated."
                    ));
                }
            }
            if modifiers.contains(&key_part.to_ascii_lowercase().as_str())
                || !valid_key_token(key_part)
            {
                return Err(format!(
                    "Invalid mpv key binding '{value}': enter one mpv key name."
                ));
            }
        }
        let mut parts: Vec<&str> = value.split('+').collect();
        let key_name = parts.pop().unwrap_or_default();
        let mut normalized_modifiers: Vec<String> =
            parts.into_iter().map(str::to_ascii_lowercase).collect();
        normalized_modifiers.sort();
        normalized_modifiers.push(key_name.to_owned());
        let signature = normalized_modifiers.join("+");
        if let Some(previous) = assigned.insert((context.to_owned(), signature), key.clone()) {
            duplicates.push(format!(
                "{previous} and {key} both use {value} in the {context} context"
            ));
        }
    }
    if duplicates.is_empty() {
        Ok(())
    } else {
        Err(format!("Duplicate shortcuts: {}", duplicates.join("; ")))
    }
}

fn valid_key_token(key: &str) -> bool {
    !key.is_empty()
        && key.bytes().all(|byte| {
            byte.is_ascii_alphanumeric() || b"_. ,!?/\\;:'\"=(){}[]<>@#$%^&*`~-".contains(&byte)
        })
}

#[cfg(test)]
mod tests {
    use super::*;
    use slint::Model;
    use tempfile::tempdir;

    #[test]
    fn config_document_keeps_comments_and_line_endings() {
        let mut document = ConfigDocument::from_text("# keep\r\nknown = old\r\nvendor=keep\r\n");
        document.set_value("known", "new").unwrap();
        assert_eq!(document.text(), "# keep\r\nknown = new\r\nvendor=keep\r\n");
    }

    #[test]
    fn config_document_updates_last_duplicate_and_removes_all() {
        let mut document = ConfigDocument::from_text("key=first\nkey=last\n");
        assert_eq!(document.values()["key"], "last");
        document.set_value("key", "updated").unwrap();
        assert_eq!(document.text(), "key=first\nkey=updated\n");
        assert!(document.remove_value("key"));
        assert!(document.values().is_empty());
    }

    #[test]
    fn catalog_derives_settings_descriptions_and_dynamic_choices() {
        let catalog = SettingsCatalog::load();
        assert!(catalog.core_defaults.contains_key("copy_text_mode"));
        assert!(catalog.core_defaults.contains_key("ffmpeg_exec"));
        assert!(catalog.profile_descriptions["video_codec"].starts_with("Video codec selection"));
        assert_eq!(
            choices_for("video_preset", "p4", "av1_nvenc", &catalog.profile_defaults),
            (1..9).map(|value| format!("p{value}")).collect::<Vec<_>>()
        );
        assert!(dependencies_met(
            "video_codec",
            &BTreeMap::from([("enable_video".into(), "yes".into())])
        ));
        assert!(!dependencies_met(
            "video_codec",
            &BTreeMap::from([("enable_video".into(), "no".into())])
        ));
    }

    #[test]
    fn setting_rows_expose_default_and_inherited_values_for_color_coding() {
        let catalog = SettingsCatalog::load();
        let mut core_page = SettingsPage::new(PageKind::Core);
        core_page.values = catalog.core_defaults.clone();
        core_page.build_rows(&catalog);
        let core_row = core_page
            .rows
            .iter()
            .find(|row| row.key.as_str() == "copy_text_mode")
            .unwrap();
        assert_eq!(
            core_row.default_value.as_str(),
            catalog.core_defaults["copy_text_mode"]
        );

        let mut base_profile_page = SettingsPage::new(PageKind::Profile);
        base_profile_page.profile = Some(BASE_PROFILE.to_owned());
        base_profile_page.values = catalog.profile_defaults.clone();
        base_profile_page.build_rows(&catalog);
        let base_profile_row = base_profile_page
            .rows
            .iter()
            .find(|row| row.key.as_str() == "video_codec")
            .unwrap();
        assert!(!base_profile_row.has_inherit);
        assert_eq!(
            base_profile_row.default_value.as_str(),
            catalog.profile_defaults["video_codec"]
        );

        let mut profile_page = SettingsPage::new(PageKind::Profile);
        profile_page.profile = Some("custom".to_owned());
        profile_page.values = catalog.profile_defaults.clone();
        profile_page.base_values = catalog.profile_defaults.clone();
        profile_page.build_rows(&catalog);
        let profile_row = profile_page
            .rows
            .iter()
            .find(|row| row.key.as_str() == "video_codec")
            .unwrap();
        assert_eq!(
            profile_row.default_value.as_str(),
            catalog.profile_defaults["video_codec"]
        );
        assert_eq!(
            profile_row.base_value.as_str(),
            catalog.profile_defaults["video_codec"]
        );
        assert!(profile_row.has_inherit);
        let expected_index = choices_for(
            "video_codec",
            &catalog.profile_defaults["video_codec"],
            "libsvtav1",
            &catalog.profile_defaults,
        )
        .iter()
        .position(|choice| choice == &catalog.profile_defaults["video_codec"])
        .unwrap();
        assert_eq!(profile_row.choice_index as usize, expected_index);

        profile_page
            .values
            .insert("video_codec".to_owned(), "libx264".to_owned());
        profile_page
            .values
            .insert("enable_video".to_owned(), "no".to_owned());
        profile_page.build_rows(&catalog);
        let overridden_codec = profile_page
            .rows
            .iter()
            .find(|row| row.key.as_str() == "video_codec")
            .unwrap();
        let disabled_bitrate = profile_page
            .rows
            .iter()
            .find(|row| row.key.as_str() == "video_bitrate")
            .unwrap();
        assert!(overridden_codec.has_inherit);
        assert_eq!(
            overridden_codec.default_value.as_str(),
            catalog.profile_defaults["video_codec"]
        );
        assert_eq!(
            overridden_codec.base_value.as_str(),
            catalog.profile_defaults["video_codec"]
        );
        assert!(!disabled_bitrate.enabled);
    }

    #[test]
    fn profile_names_and_shortcuts_are_validated() {
        assert!(validate_profile_name("work_profile-2").is_ok());
        assert!(validate_profile_name("../oops").is_err());
        assert!(validate_key_bindings(&BTreeMap::from([
            ("menu_key_one".into(), "ctrl+a".into()),
            ("binding_scope_menu_key_one".into(), "advanced-menu".into()),
            ("menu_key_two".into(), "ctrl+a".into()),
            ("binding_scope_menu_key_two".into(), "advanced-menu".into()),
        ]))
        .is_err());
        assert!(validate_key_bindings(&BTreeMap::from([
            ("menu_key_one".into(), "ctrl+".into()),
            ("binding_scope_menu_key_one".into(), "advanced-menu".into()),
        ]))
        .is_err());
    }

    #[test]
    fn global_shortcuts_are_checked_separately_from_advanced_menu_shortcuts() {
        assert!(validate_key_bindings(&BTreeMap::from([
            ("global_key_one".into(), "ctrl+a".into()),
            ("binding_scope_global_key_one".into(), "global".into()),
            ("global_key_two".into(), "ctrl+a".into()),
            ("binding_scope_global_key_two".into(), "global".into()),
        ]))
        .is_err());
        assert!(validate_key_bindings(&BTreeMap::from([
            ("menu_key_one".into(), "ctrl+a".into()),
            ("binding_scope_menu_key_one".into(), "advanced-menu".into()),
            ("global_key_one".into(), "ctrl+a".into()),
            ("binding_scope_global_key_one".into(), "global".into()),
        ]))
        .is_ok());
        assert!(validate_key_bindings(&BTreeMap::from([
            ("menu_key_open".into(), "ctrl+a".into()),
            ("binding_scope_menu_key_open".into(), "global".into()),
            ("global_key_one".into(), "ctrl+a".into()),
            ("binding_scope_global_key_one".into(), "global".into()),
        ]))
        .is_err());
        assert!(validate_key_bindings(&BTreeMap::from([
            ("menu_key_one".into(), "ctrl+a".into()),
            ("binding_scope_menu_key_one".into(), "global".into()),
            ("global_key_one".into(), "ctrl+a".into()),
            ("binding_scope_global_key_one".into(), "global".into()),
        ]))
        .is_err());
        assert!(validate_key_bindings(&BTreeMap::from([
            ("menu_key_one".into(), "ctrl+a".into(),)
        ]))
        .is_err());
        assert!(validate_key_bindings(&BTreeMap::from([
            ("menu_key_one".into(), "ctrl+a".into()),
            ("binding_scope_menu_key_one".into(), "both".into()),
        ]))
        .is_err());
    }

    #[test]
    fn key_binding_page_pairs_shortcuts_with_scope_in_task_categories() {
        let catalog = SettingsCatalog::load();
        let action_keys: Vec<&String> = catalog
            .core_defaults
            .keys()
            .filter(|key| key.starts_with("menu_key_") || key.starts_with("global_key_"))
            .collect();
        let scope_keys: Vec<&String> = catalog
            .core_defaults
            .keys()
            .filter(|key| key.starts_with("binding_scope_"))
            .collect();
        assert_eq!(action_keys.len(), scope_keys.len());
        for key in &action_keys {
            let action_key = key.as_str();
            let scope_key = format!("binding_scope_{action_key}");
            let expected_scope =
                if action_key == "menu_key_open" || action_key.starts_with("global_key_") {
                    "global"
                } else {
                    "advanced-menu"
                };
            assert_eq!(
                catalog.core_defaults.get(&scope_key).map(String::as_str),
                Some(expected_scope)
            );
        }
        assert_eq!(
            catalog.core_defaults["binding_scope_menu_key_open"],
            "global"
        );
        assert_eq!(
            catalog.core_defaults["binding_scope_menu_key_seek_next"],
            "advanced-menu"
        );
        let mut bindings = SettingsPage::new(PageKind::Bindings);
        bindings.values = catalog.core_defaults.clone();
        bindings.build_rows(&catalog);
        let binding_keys: HashSet<&str> =
            bindings.rows.iter().map(|row| row.key.as_str()).collect();
        assert!(binding_keys.contains("global_key_copy_primary"));
        assert!(binding_keys.contains("menu_key_open"));
        assert!(binding_keys.contains("menu_key_seek_next"));
        assert!(!binding_keys.contains("binding_scope_global_key_copy_primary"));
        let action_rows: Vec<&SettingRowData> =
            bindings.rows.iter().filter(|row| !row.category).collect();
        assert_eq!(action_rows.len(), action_keys.len());
        assert!(action_rows
            .iter()
            .all(|row| { row.scope_choice_index >= 0 && row.scope_choices.row_count() == 2 }));
        let copy_primary = action_rows
            .iter()
            .find(|row| row.key.as_str() == "global_key_copy_primary")
            .unwrap();
        assert_eq!(copy_primary.scope_value, "Global (any time)");
        let seek_next = action_rows
            .iter()
            .find(|row| row.key.as_str() == "menu_key_seek_next")
            .unwrap();
        assert_eq!(seek_next.scope_value, "Advanced menu only");
        let category_labels: Vec<&str> = bindings
            .rows
            .iter()
            .filter(|row| row.category)
            .map(|row| row.label.as_str())
            .collect();
        assert!(category_labels.contains(&"Capture and timing"));
        assert!(category_labels.contains(&"Playback and subtitles"));
        assert!(category_labels.contains(&"Export and Anki"));
        assert!(!category_labels.contains(&"Global shortcut settings"));
        assert!(!category_labels.contains(&"Advanced-menu shortcut settings"));
        assert_eq!(
            choices_for(
                "binding_scope_menu_key_seek_next",
                "advanced-menu",
                "",
                &catalog.core_defaults,
            ),
            vec!["advanced-menu".to_owned(), "global".to_owned()]
        );

        let mut core = SettingsPage::new(PageKind::Core);
        core.values = catalog.core_defaults.clone();
        core.build_rows(&catalog);
        assert!(!core.rows.iter().any(|row| {
            row.key.as_str().starts_with("global_key_")
                || row.key.as_str().starts_with("binding_scope_")
        }));
    }

    #[test]
    fn config_store_creates_profiles_and_saves_only_custom_overrides() {
        let temporary = tempdir().unwrap();
        let mut store = ConfigStore::new(temporary.path().join("mpv")).unwrap();
        store.backup_directory = temporary.path().join("config-backups");
        let catalog = SettingsCatalog::load();
        store.ensure_defaults(&catalog).unwrap();
        store.add_profile("gaming").unwrap();
        assert!(store
            .profile_names()
            .unwrap()
            .contains(&"gaming".to_owned()));

        let base = store.base_values(&catalog).unwrap();
        store
            .save_profile_values(
                "gaming",
                &BTreeMap::from([("video_codec".to_owned(), "libx264".to_owned())]),
                &base,
            )
            .unwrap();
        assert_eq!(
            store.read_profile("gaming").unwrap().values()["video_codec"],
            "libx264"
        );
        store
            .save_profile_values(
                "gaming",
                &BTreeMap::from([("video_codec".to_owned(), base["video_codec"].clone())]),
                &base,
            )
            .unwrap();
        assert!(!store
            .read_profile("gaming")
            .unwrap()
            .values()
            .contains_key("video_codec"));
    }

    #[test]
    fn config_store_migrates_moved_values_and_removes_unknown_keys() {
        let temporary = tempdir().unwrap();
        let mut store = ConfigStore::new(temporary.path().join("mpv")).unwrap();
        store.backup_directory = temporary.path().join("config-backups");
        let catalog = SettingsCatalog::load();
        store.ensure_defaults(&catalog).unwrap();

        let mut base = store.read_profile(BASE_PROFILE).unwrap();
        base.set_value("copy_text_mode", "single_line").unwrap();
        base.set_value("unknown_profile_option", "discard").unwrap();
        store.write(BASE_CONFIG, &base).unwrap();
        let mut core = store.read_core().unwrap();
        core.set_value("copy_text_mode", "subtitle_content")
            .unwrap();
        core.set_value("unknown_core_option", "discard").unwrap();
        store.write(CORE_CONFIG, &core).unwrap();

        store.ensure_defaults(&catalog).unwrap();
        let core_values = store.read_core().unwrap().values();
        let base_values = store.read_profile(BASE_PROFILE).unwrap().values();
        assert_eq!(core_values["copy_text_mode"], "single_line");
        assert!(!core_values.contains_key("unknown_core_option"));
        assert!(!base_values.contains_key("copy_text_mode"));
        assert!(!base_values.contains_key("unknown_profile_option"));
        assert!((temporary
            .path()
            .join("config-backups")
            .join(format!("{CORE_CONFIG}.bak")))
        .is_file());
    }
}
