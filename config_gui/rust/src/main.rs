#![cfg_attr(target_os = "windows", windows_subsystem = "windows")]

mod associations;
mod backend;
mod detection;

use std::{
    cell::RefCell,
    collections::BTreeMap,
    path::{Path, PathBuf},
    rc::Rc,
    thread,
};

#[cfg(any(target_os = "windows", target_os = "linux", target_os = "macos"))]
use std::process::Command;
#[cfg(target_os = "windows")]
use std::{os::windows::process::CommandExt, process::Stdio};

use backend::{
    default_config_root, update_rows, validate_key_bindings, ConfigDocument, ConfigStore, PageKind,
    SettingsCatalog, SettingsPage, BASE_PROFILE, CORE_CONFIG,
};
use rfd::{FileDialog, MessageButtons, MessageDialog, MessageDialogResult, MessageLevel};
use slint::{ComponentHandle, Model, ModelRc, SharedString, VecModel};

slint::include_modules!();

struct EditorState {
    catalog: SettingsCatalog,
    store: Option<ConfigStore>,
    core: SettingsPage,
    bindings: SettingsPage,
    profile: SettingsPage,
    profiles: Vec<String>,
    selected_profile: String,
    active_profile: String,
}

impl EditorState {
    fn new() -> Self {
        Self {
            catalog: SettingsCatalog::load(),
            store: None,
            core: SettingsPage::new(PageKind::Core),
            bindings: SettingsPage::new(PageKind::Bindings),
            profile: SettingsPage::new(PageKind::Profile),
            profiles: Vec::new(),
            selected_profile: BASE_PROFILE.to_owned(),
            active_profile: BASE_PROFILE.to_owned(),
        }
    }

    fn page(&self, index: i32) -> &SettingsPage {
        match index {
            1 => &self.bindings,
            2 => &self.profile,
            _ => &self.core,
        }
    }

    fn page_mut(&mut self, index: i32) -> &mut SettingsPage {
        match index {
            1 => &mut self.bindings,
            2 => &mut self.profile,
            _ => &mut self.core,
        }
    }

    fn update_ui(&mut self, ui: &MainWindow) {
        ui.set_core_rows(update_rows(&mut self.core, &self.catalog));
        ui.set_binding_rows(update_rows(&mut self.bindings, &self.catalog));
        ui.set_profile_rows(update_rows(&mut self.profile, &self.catalog));
        ui.set_profiles(ModelRc::new(VecModel::from(
            self.profiles
                .iter()
                .map(SharedString::from)
                .collect::<Vec<_>>(),
        )));
        ui.set_selected_profile(self.selected_profile.clone().into());
        ui.set_active_profile(self.active_profile.clone().into());
        let profile_path = self.store.as_ref().and_then(|store| {
            ConfigStore::profile_filename(&self.selected_profile)
                .ok()
                .map(|file| store.script_opts.join(file))
        });
        let hint = if let Some(path) = profile_path {
            if self.selected_profile == BASE_PROFILE {
                format!(
                    "Editing the base profile ({}). Changes set defaults shared by all profiles unless a custom profile overrides them.",
                    path.file_name().unwrap_or_default().to_string_lossy()
                )
            } else {
                format!(
                    "Editing custom profile '{}' ({}). Only values that differ from the base profile are saved as overrides; values matching the base are inherited.",
                    self.selected_profile,
                    path.file_name().unwrap_or_default().to_string_lossy()
                )
            }
        } else {
            String::new()
        };
        ui.set_profile_hint(hint.into());
    }
}

fn show_message(title: &str, message: &str, level: MessageLevel) {
    MessageDialog::new()
        .set_title(title)
        .set_description(message)
        .set_level(level)
        .set_buttons(MessageButtons::Ok)
        .show();
}

fn load_root(ui: &MainWindow, state: &Rc<RefCell<EditorState>>, path: PathBuf) {
    if path.as_os_str().is_empty() {
        show_message(
            "Choose a config folder",
            "Select mpv's config folder first.",
            MessageLevel::Warning,
        );
        return;
    }
    {
        let mut current = state.borrow_mut();
        if current
            .store
            .as_ref()
            .is_some_and(|store| store.config_root != path)
            && !confirm_unsaved(ui, &mut current)
        {
            return;
        }
        match ConfigStore::new(path) {
            Ok(store) => {
                if let Err(error) = store.ensure_defaults(&current.catalog) {
                    show_message("Could not load mpv config", &error, MessageLevel::Error);
                    return;
                }
                current.store = Some(store);
                if let Err(error) = load_pages(&mut current) {
                    current.store = None;
                    show_message("Could not load mpv config", &error, MessageLevel::Error);
                    return;
                }
                current.update_ui(ui);
                if let Some(store) = &current.store {
                    ui.set_config_root(store.config_root.display().to_string().into());
                    ui.set_path_status(
                        format!(
                            "Editing: {} · backups: {}",
                            store.script_opts.display(),
                            store.backup_directory.display()
                        )
                        .into(),
                    );
                }
                ui.set_status("".into());
                ui.set_profile_status("".into());
            }
            Err(error) => show_message(
                "Could not load mpv config",
                &error.to_string(),
                MessageLevel::Error,
            ),
        }
    }
}

fn load_pages(state: &mut EditorState) -> Result<(), String> {
    let store = state
        .store
        .as_ref()
        .ok_or("No config folder is loaded")?
        .clone();
    let core_doc = store.read_core()?;
    let raw = core_doc.values();
    let mut values = state.catalog.core_defaults.clone();
    values.extend(raw.clone());
    state.core = page_from_document(
        PageKind::Core,
        core_doc,
        values,
        BTreeMap::new(),
        None,
        &state.catalog,
    );

    let binding_doc = store.read_core()?;
    state.bindings = page_from_document(
        PageKind::Bindings,
        binding_doc,
        values_from_core(&store, &state.catalog)?,
        BTreeMap::new(),
        None,
        &state.catalog,
    );

    state.profiles = store.profile_names()?;
    state.active_profile = store.active_profile()?;
    if !state
        .profiles
        .iter()
        .any(|profile| profile == &state.selected_profile)
    {
        state.selected_profile = state.active_profile.clone();
    }
    load_profile_page(state)
}

fn values_from_core(
    store: &ConfigStore,
    catalog: &SettingsCatalog,
) -> Result<BTreeMap<String, String>, String> {
    let mut values = catalog.core_defaults.clone();
    values.extend(store.read_core()?.values());
    Ok(values)
}

fn page_from_document(
    kind: PageKind,
    document: ConfigDocument,
    values: BTreeMap<String, String>,
    base_values: BTreeMap<String, String>,
    profile: Option<String>,
    catalog: &SettingsCatalog,
) -> SettingsPage {
    let raw = document.values();
    let mut page = SettingsPage::new(kind);
    page.profile = profile;
    page.values = values.clone();
    page.original_values = values;
    page.original_raw = raw;
    page.base_values = base_values;
    page.build_rows(catalog);
    page
}

fn load_profile_page(state: &mut EditorState) -> Result<(), String> {
    let store = state
        .store
        .as_ref()
        .ok_or("No config folder is loaded")?
        .clone();
    let document = store.read_profile(&state.selected_profile)?;
    let base = store.base_values(&state.catalog)?;
    let values = store.effective_profile_values(&state.selected_profile, &state.catalog)?;
    state.profile = page_from_document(
        PageKind::Profile,
        document,
        values,
        if state.selected_profile == BASE_PROFILE {
            BTreeMap::new()
        } else {
            base
        },
        Some(state.selected_profile.clone()),
        &state.catalog,
    );
    Ok(())
}

fn confirm_unsaved(ui: &MainWindow, state: &mut EditorState) -> bool {
    let dirty: Vec<i32> = [0, 1, 2]
        .into_iter()
        .filter(|index| state.page(*index).is_dirty())
        .collect();
    if dirty.is_empty() {
        return true;
    }
    match MessageDialog::new()
        .set_title("Unsaved settings")
        .set_description("Save your unsaved changes before continuing? Choose No to discard them.")
        .set_level(MessageLevel::Warning)
        .set_buttons(MessageButtons::YesNoCancel)
        .show()
    {
        MessageDialogResult::Yes => dirty.into_iter().all(|page| save_page(ui, state, page)),
        MessageDialogResult::No => {
            if let Err(error) = load_pages(state) {
                show_message("Could not reload settings", &error, MessageLevel::Error);
                false
            } else {
                state.update_ui(ui);
                true
            }
        }
        _ => false,
    }
}

fn save_page(ui: &MainWindow, state: &mut EditorState, page_index: i32) -> bool {
    let Some(store) = state.store.as_ref().cloned() else {
        show_message(
            "No config loaded",
            "Load an mpv config folder before saving.",
            MessageLevel::Warning,
        );
        return false;
    };
    let mut page = std::mem::replace(
        state.page_mut(page_index),
        SettingsPage::new(PageKind::Core),
    );
    let result = save_page_data(&store, &state.catalog, &mut page);
    *state.page_mut(page_index) = page;
    match result {
        Ok(path) => {
            ui.set_status(
                format!(
                    "Saved to {}. Restart mpv for changes to take effect.",
                    path.display()
                )
                .into(),
            );
            if page_index == 2 {
                ui.set_profile_status(
                    format!(
                        "Saved profile '{}' to {}. Restart mpv for changes to take effect.",
                        state.selected_profile,
                        path.file_name().unwrap_or_default().to_string_lossy()
                    )
                    .into(),
                );
            }
            state.update_ui(ui);
            true
        }
        Err(error) => {
            show_message("Could not save settings", &error, MessageLevel::Error);
            false
        }
    }
}

fn save_page_data(
    store: &ConfigStore,
    catalog: &SettingsCatalog,
    page: &mut SettingsPage,
) -> Result<PathBuf, String> {
    if matches!(page.kind, PageKind::Bindings) {
        validate_key_bindings(&page.values)?;
    }
    for (key, value) in &page.values {
        if value.contains(['\n', '\r']) {
            return Err(format!("'{key}' must be a single-line value."));
        }
    }
    let changed: BTreeMap<String, String> = page
        .values
        .iter()
        .filter(|(key, value)| page.original_values.get(*key) != Some(*value))
        .map(|(key, value)| (key.clone(), value.clone()))
        .collect();

    let filename = match page.kind {
        PageKind::Core | PageKind::Bindings => CORE_CONFIG.to_owned(),
        PageKind::Profile => {
            ConfigStore::profile_filename(page.profile.as_deref().unwrap_or(BASE_PROFILE))?
        }
    };
    let path = store.script_opts.join(&filename);
    if matches!(page.kind, PageKind::Profile) {
        let profile = page.profile.as_deref().unwrap_or(BASE_PROFILE);
        let latest_raw = store.read_profile(profile)?.values();
        let latest_base = store.base_values(catalog)?;
        for key in changed.keys() {
            if latest_raw.get(key) != page.original_raw.get(key) {
                return Err(format!("'{key}' changed on disk since this profile was loaded. Reload it before saving."));
            }
            if profile != BASE_PROFILE && latest_base.get(key) != page.base_values.get(key) {
                return Err(format!("The base value for '{key}' changed while this profile was open. Reload the profile before saving."));
            }
        }
        store.save_profile_values(profile, &changed, &latest_base)?;
        page.original_raw = store.read_profile(profile)?.values();
        page.base_values = if profile == BASE_PROFILE {
            BTreeMap::new()
        } else {
            latest_base
        };
    } else {
        let mut latest = ConfigDocument::read(&path).map_err(|error| error.to_string())?;
        let latest_values = latest.values();
        for (key, value) in &changed {
            if latest_values.get(key) != page.original_raw.get(key)
                && latest_values.get(key) != Some(value)
            {
                return Err(format!("'{key}' changed on disk since this page was loaded. Reload the config before saving to avoid overwriting the other change."));
            }
            latest.set_value(key, value)?;
        }
        latest
            .write_atomic(&path, &store.backup_directory)
            .map_err(|error| error.to_string())?;
        page.original_raw = latest.values();
    }
    page.original_values = page.values.clone();
    Ok(path)
}

fn on_setting_edited(
    ui: &MainWindow,
    state: &mut EditorState,
    page_index: i32,
    row_index: i32,
    value: SharedString,
) {
    let page = state.page_mut(page_index);
    let mut choices_changed = false;
    if let Some(row) = page.rows.get(row_index.max(0) as usize) {
        let key = row.key.to_string();
        choices_changed = row.choices.row_count() > 0;
        if !key.is_empty() {
            page.values.insert(key, value.to_string());
        }
    }
    if choices_changed {
        state.update_ui(ui);
    }
}

fn on_inherit(ui: &MainWindow, state: &mut EditorState, page_index: i32, key: SharedString) {
    if page_index == 2 {
        if let Some(value) = state.profile.base_values.get(key.as_str()).cloned() {
            state.profile.values.insert(key.to_string(), value);
            state.update_ui(ui);
        }
    }
}

fn restore_shipped_default(
    state: &mut EditorState,
    page_index: i32,
    key: &str,
) -> Result<(), String> {
    let defaults = match page_index {
        0 | 1 => &state.catalog.core_defaults,
        2 if state.profile.profile.as_deref() == Some(BASE_PROFILE) => {
            &state.catalog.profile_defaults
        }
        2 => {
            return Err(
                "Shipped defaults can only be restored while editing the base profile.".to_owned(),
            )
        }
        _ => return Err(format!("Unknown settings page: {page_index}")),
    };
    let value = defaults
        .get(key)
        .cloned()
        .ok_or_else(|| format!("No shipped default is defined for '{key}'."))?;
    let scope_default =
        if page_index == 1 && (key.starts_with("menu_key_") || key.starts_with("global_key_")) {
            let scope_key = format!("binding_scope_{key}");
            Some((
                scope_key.clone(),
                defaults
                    .get(&scope_key)
                    .cloned()
                    .ok_or_else(|| format!("No shipped default is defined for '{scope_key}'."))?,
            ))
        } else {
            None
        };
    let page = state.page_mut(page_index);
    page.values.insert(key.to_owned(), value);
    if let Some((scope_key, scope_value)) = scope_default {
        page.values.insert(scope_key, scope_value);
    }
    Ok(())
}

fn set_binding_scope(state: &mut EditorState, key: &str, scope_label: &str) -> Result<(), String> {
    let scope = match scope_label {
        "Advanced menu only" => "advanced-menu",
        "Global (any time)" => "global",
        _ => return Err(format!("Unknown shortcut scope: {scope_label}")),
    };
    if !key.starts_with("menu_key_") && !key.starts_with("global_key_") {
        return Err(format!("'{key}' is not a shortcut action."));
    }
    let scope_key = format!("binding_scope_{key}");
    if !state.catalog.core_defaults.contains_key(&scope_key) {
        return Err(format!("No scope setting is defined for shortcut '{key}'."));
    }
    state.bindings.values.insert(scope_key, scope.to_owned());
    Ok(())
}

fn on_binding_scope_edited(
    ui: &MainWindow,
    state: &mut EditorState,
    key: SharedString,
    scope_label: SharedString,
) {
    if let Err(error) = set_binding_scope(state, key.as_str(), scope_label.as_str()) {
        show_message(
            "Could not change shortcut scope",
            &error,
            MessageLevel::Error,
        );
        return;
    }
    state.update_ui(ui);
}

fn on_setting_default(
    ui: &MainWindow,
    state: &mut EditorState,
    page_index: i32,
    key: SharedString,
) {
    if let Err(error) = restore_shipped_default(state, page_index, key.as_str()) {
        show_message(
            "Could not restore shipped default",
            &error,
            MessageLevel::Error,
        );
        return;
    }
    state.update_ui(ui);
}

fn select_profile(ui: &MainWindow, state: &mut EditorState, profile: String) {
    if profile == state.selected_profile {
        return;
    }
    if !confirm_unsaved(ui, state) {
        ui.set_selected_profile(state.selected_profile.clone().into());
        return;
    }
    state.selected_profile = profile;
    if let Err(error) = load_profile_page(state) {
        show_message("Could not load profile", &error, MessageLevel::Error);
    }
    state.update_ui(ui);
}

fn set_active_profile(ui: &MainWindow, state: &mut EditorState, selected: String) {
    let Some(store) = state.store.as_ref() else {
        return;
    };
    if let Err(error) = store.set_profile_names(&state.profiles, &selected) {
        show_message("Could not set active profile", &error, MessageLevel::Error);
        ui.set_active_profile(state.active_profile.clone().into());
        return;
    }
    state.active_profile = selected.clone();
    ui.set_profile_status(format!(
        "'{selected}' is set as the add-on's starting profile. Restart mpv or reload the add-on for it to take effect."
    ).into());
    ui.set_status(
        format!(
            "Saved to {}. Restart mpv for changes to take effect.",
            store.script_opts.join(backend::PROFILES_CONFIG).display()
        )
        .into(),
    );
    state.update_ui(ui);
}

fn add_profile(ui: &MainWindow, state: &mut EditorState, name: String) {
    if !confirm_unsaved(ui, state) {
        return;
    }
    let Some(store) = state.store.as_ref() else {
        return;
    };
    match store.add_profile(name.trim()) {
        Ok(()) => {
            state.selected_profile = name.trim().to_owned();
            if let Err(error) = load_pages(state) {
                show_message("Could not add profile", &error, MessageLevel::Error);
                return;
            }
            state.update_ui(ui);
            ui.set_profile_name("".into());
            ui.set_profile_status(
                format!(
                    "Created profile '{}'. Settings inherit from the base profile.",
                    state.selected_profile
                )
                .into(),
            );
        }
        Err(error) => show_message("Could not add profile", &error, MessageLevel::Error),
    }
}

fn rename_profile(ui: &MainWindow, state: &mut EditorState, name: String) {
    if !confirm_unsaved(ui, state) {
        return;
    }
    let Some(store) = state.store.as_ref() else {
        return;
    };
    let old = state.selected_profile.clone();
    match store.rename_profile(&old, name.trim()) {
        Ok(()) => {
            state.selected_profile = name.trim().to_owned();
            if let Err(error) = load_pages(state) {
                show_message("Could not rename profile", &error, MessageLevel::Error);
                return;
            }
            state.update_ui(ui);
            ui.set_profile_name("".into());
            ui.set_profile_status(
                format!("Renamed profile to '{}'.", state.selected_profile).into(),
            );
        }
        Err(error) => show_message("Could not rename profile", &error, MessageLevel::Error),
    }
}

fn remove_profile(ui: &MainWindow, state: &mut EditorState) {
    if !confirm_unsaved(ui, state) {
        return;
    }
    if state.selected_profile == BASE_PROFILE {
        show_message(
            "Base profile",
            "The base profile cannot be removed.",
            MessageLevel::Info,
        );
        return;
    }
    if MessageDialog::new()
        .set_title("Remove profile")
        .set_description(format!(
            "Remove '{}' from the profile list? Its config file will be kept.",
            state.selected_profile
        ))
        .set_level(MessageLevel::Warning)
        .set_buttons(MessageButtons::YesNo)
        .show()
        != MessageDialogResult::Yes
    {
        return;
    }
    let Some(store) = state.store.as_ref() else {
        return;
    };
    let removed = state.selected_profile.clone();
    match store.remove_profile(&removed) {
        Ok(()) => {
            state.selected_profile = BASE_PROFILE.to_owned();
            if let Err(error) = load_pages(state) {
                show_message("Could not remove profile", &error, MessageLevel::Error);
                return;
            }
            state.update_ui(ui);
            ui.set_profile_status(
                format!("Removed '{removed}' from the list. Its config file remains on disk.")
                    .into(),
            );
        }
        Err(error) => show_message("Could not remove profile", &error, MessageLevel::Error),
    }
}

fn browse_folder(initial: &str) -> Option<PathBuf> {
    let dialog = FileDialog::new().set_title("Choose mpv config folder");
    let dialog = if Path::new(initial).is_dir() {
        dialog.set_directory(initial)
    } else {
        dialog
    };
    dialog.pick_folder()
}

fn open_path(path: &Path) -> Result<(), String> {
    if !path.exists() {
        return Err(format!("Path does not exist: {}", path.display()));
    }

    #[cfg(any(target_os = "windows", target_os = "linux", target_os = "macos"))]
    {
        #[cfg(target_os = "windows")]
        let mut command = Command::new("explorer.exe");
        #[cfg(target_os = "linux")]
        let mut command = Command::new("xdg-open");
        #[cfg(target_os = "macos")]
        let mut command = Command::new("open");

        command
            .arg(path)
            .spawn()
            .map(|_| ())
            .map_err(|error| format!("Could not open '{}': {error}", path.display()))
    }

    #[cfg(not(any(target_os = "windows", target_os = "linux", target_os = "macos")))]
    {
        Err("Opening files and folders is not supported on this platform".to_owned())
    }
}

fn scan_async(ui: &MainWindow, selected: Option<PathBuf>) {
    ui.set_scan_results("Scanning PATH and known install/config locations…".into());
    ui.set_scan_tool_results(ModelRc::new(VecModel::from(Vec::<ToolScanRow>::new())));
    ui.set_scan_running(true);
    let weak = ui.as_weak();
    thread::spawn(move || {
        let result = detection::scan(selected.as_deref());
        let _ = slint::invoke_from_event_loop(move || {
            if let Some(ui) = weak.upgrade() {
                match result {
                    Ok(report) => {
                        let tools = report
                            .tools
                            .into_iter()
                            .map(|tool| ToolScanRow {
                                name: tool.name.into(),
                                found_on_path: tool.path.is_some(),
                                path: tool
                                    .path
                                    .map(|path| path.display().to_string())
                                    .unwrap_or_default()
                                    .into(),
                                other_paths: ModelRc::new(VecModel::from(
                                    tool.others
                                        .into_iter()
                                        .map(|path| path.display().to_string().into())
                                        .collect::<Vec<SharedString>>(),
                                )),
                            })
                            .collect::<Vec<_>>();
                        ui.set_scan_tool_results(ModelRc::new(VecModel::from(tools)));
                        ui.set_scan_results(report.details.into());
                    }
                    Err(error) => {
                        ui.set_scan_results(format!("Scan failed: {error}").into());
                    }
                }
                ui.set_scan_running(false);
            }
        });
    });
}

fn scan_media_associations_async(ui: &MainWindow) {
    ui.set_association_status("Checking OS default media handlers…".into());
    ui.set_association_results(ModelRc::new(VecModel::from(Vec::<AssociationRow>::new())));
    ui.set_association_running(true);
    let weak = ui.as_weak();
    thread::spawn(move || {
        let results = associations::scan();
        let _ = slint::invoke_from_event_loop(move || {
            if let Some(ui) = weak.upgrade() {
                let rows = results
                    .into_iter()
                    .map(|result| {
                        let is_mpv = associations::is_mpv_handler(
                            result.handler.as_deref(),
                            result.executable.as_deref(),
                        );
                        let state = if is_mpv {
                            "mpv"
                        } else if result.handler.is_some() {
                            "other"
                        } else {
                            "missing"
                        };
                        AssociationRow {
                            extension: result.extension.into(),
                            handler: result.handler.unwrap_or_default().into(),
                            executable: result
                                .executable
                                .map(|path| path.display().to_string())
                                .unwrap_or_default()
                                .into(),
                            state: state.into(),
                            message: result.error.unwrap_or_default().into(),
                        }
                    })
                    .collect::<Vec<_>>();
                ui.set_association_results(ModelRc::new(VecModel::from(rows)));
                ui.set_association_status("Read-only default-app check complete.".into());
                ui.set_association_running(false);
            }
        });
    });
}

fn create_shortcut() -> Result<(), String> {
    #[cfg(target_os = "windows")]
    {
        let executable = std::env::current_exe().map_err(|error| error.to_string())?;
        let appdata = std::env::var_os("APPDATA")
            .map(PathBuf::from)
            .unwrap_or_else(|| dirs::home_dir().unwrap_or_default());
        create_windows_shortcut(
            &executable,
            appdata.join("Microsoft/Windows/Start Menu/Programs/MPV Anki Clips Config.lnk"),
        )?;
        if ask_yes_no("Desktop shortcut", "Also create a shortcut on the Desktop?") {
            let desktop = dirs::home_dir()
                .unwrap_or_default()
                .join("Desktop/MPV Anki Clips Config.lnk");
            create_windows_shortcut(&executable, desktop)?;
        }
        Ok(())
    }
    #[cfg(not(target_os = "windows"))]
    {
        Err("Shortcut creation is currently supported only on Windows.".to_owned())
    }
}

fn ask_yes_no(title: &str, message: &str) -> bool {
    MessageDialog::new()
        .set_title(title)
        .set_description(message)
        .set_level(MessageLevel::Info)
        .set_buttons(MessageButtons::YesNo)
        .show()
        == MessageDialogResult::Yes
}

#[cfg(target_os = "windows")]
fn create_windows_shortcut(executable: &Path, shortcut: PathBuf) -> Result<(), String> {
    let parent = shortcut
        .parent()
        .ok_or("Shortcut path has no parent folder")?;
    std::fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    let escape = |value: &str| value.replace('\'', "''");
    let target = escape(&executable.to_string_lossy());
    let shortcut = escape(&shortcut.to_string_lossy());
    let directory = escape(
        &executable
            .parent()
            .unwrap_or_else(|| Path::new("."))
            .to_string_lossy(),
    );
    let script = format!(
        "$shell=New-Object -ComObject WScript.Shell;$link=$shell.CreateShortcut('{shortcut}');$link.TargetPath='{target}';$link.WorkingDirectory='{directory}';$link.Save()"
    );
    Command::new("powershell.exe")
        .args(["-NoProfile", "-NonInteractive", "-Command", &script])
        .creation_flags(0x08000000)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map_err(|error| error.to_string())
        .and_then(|status| {
            if status.success() {
                Ok(())
            } else {
                Err(format!("PowerShell exited with {status}"))
            }
        })
}

fn main() -> Result<(), slint::PlatformError> {
    let ui = MainWindow::new()?;
    let state = Rc::new(RefCell::new(EditorState::new()));
    ui.set_config_root(default_config_root().display().to_string().into());
    ui.set_scan_results(
        "Select Scan now to perform a lightweight search for known tool paths and likely mpv configuration folders.".into(),
    );
    ui.set_association_status(
        "Select Check media defaults to inspect OS file associations.".into(),
    );
    ui.set_association_results(ModelRc::new(VecModel::from(Vec::<AssociationRow>::new())));
    ui.set_shortcut_enabled(cfg!(target_os = "windows"));

    {
        let state = state.clone();
        let weak = ui.as_weak();
        ui.on_browse_root(move || {
            let initial = weak
                .upgrade()
                .map(|ui| ui.get_config_root().to_string())
                .unwrap_or_default();
            if let Some(path) = browse_folder(&initial) {
                if let Some(ui) = weak.upgrade() {
                    ui.set_config_root(path.display().to_string().into());
                    load_root(&ui, &state, path);
                }
            }
        });
    }
    {
        let state = state.clone();
        let weak = ui.as_weak();
        ui.on_load_root(move |path| {
            if let Some(ui) = weak.upgrade() {
                load_root(&ui, &state, PathBuf::from(path.as_str()));
            }
        });
    }
    {
        let state = state.clone();
        let weak = ui.as_weak();
        ui.on_open_current_config(move |tab| {
            let result = {
                let state = state.borrow();
                state
                    .store
                    .as_ref()
                    .ok_or_else(|| "No config folder is loaded".to_owned())
                    .and_then(|store| {
                        let filename = if tab == 2 {
                            ConfigStore::profile_filename(&state.selected_profile)?
                        } else {
                            CORE_CONFIG.to_owned()
                        };
                        open_path(&store.script_opts.join(filename))
                    })
            };
            if let Some(ui) = weak.upgrade() {
                match result {
                    Ok(()) => ui.set_status("Opened the current config file.".into()),
                    Err(error) => {
                        show_message("Could not open config file", &error, MessageLevel::Error)
                    }
                }
            }
        });
    }
    {
        let state = state.clone();
        let weak = ui.as_weak();
        ui.on_open_script_opts(move || {
            let result = state
                .borrow()
                .store
                .as_ref()
                .ok_or_else(|| "No config folder is loaded".to_owned())
                .and_then(|store| open_path(&store.script_opts));
            if let Some(ui) = weak.upgrade() {
                match result {
                    Ok(()) => ui.set_status("Opened the script-opts folder.".into()),
                    Err(error) => show_message(
                        "Could not open script-opts folder",
                        &error,
                        MessageLevel::Error,
                    ),
                }
            }
        });
    }
    {
        let state = state.clone();
        let weak = ui.as_weak();
        ui.on_scan_tools(move || {
            let selected = state
                .borrow()
                .store
                .as_ref()
                .map(|store| store.config_root.clone());
            if let Some(ui) = weak.upgrade() {
                scan_async(&ui, selected);
            }
        });
    }
    {
        let weak = ui.as_weak();
        ui.on_check_media_associations(move || {
            if let Some(ui) = weak.upgrade() {
                scan_media_associations_async(&ui);
            }
        });
    }
    {
        let state = state.clone();
        let weak = ui.as_weak();
        ui.on_setting_edited(move |page, row, value| {
            if let Some(ui) = weak.upgrade() {
                on_setting_edited(&ui, &mut state.borrow_mut(), page, row, value);
            }
        });
    }
    {
        let state = state.clone();
        let weak = ui.as_weak();
        ui.on_binding_scope_edited(move |key, scope| {
            if let Some(ui) = weak.upgrade() {
                on_binding_scope_edited(&ui, &mut state.borrow_mut(), key, scope);
            }
        });
    }
    {
        let state = state.clone();
        let weak = ui.as_weak();
        ui.on_setting_inherit(move |page, key| {
            if let Some(ui) = weak.upgrade() {
                on_inherit(&ui, &mut state.borrow_mut(), page, key);
            }
        });
    }
    {
        let state = state.clone();
        let weak = ui.as_weak();
        ui.on_setting_default(move |page, key| {
            if let Some(ui) = weak.upgrade() {
                on_setting_default(&ui, &mut state.borrow_mut(), page, key);
            }
        });
    }
    {
        let state = state.clone();
        let weak = ui.as_weak();
        ui.on_save_page(move |requested| {
            if let Some(ui) = weak.upgrade() {
                save_page(&ui, &mut state.borrow_mut(), requested);
            }
        });
    }
    {
        let state = state.clone();
        let weak = ui.as_weak();
        ui.on_select_profile(move |profile| {
            if let Some(ui) = weak.upgrade() {
                select_profile(&ui, &mut state.borrow_mut(), profile.to_string());
            }
        });
    }
    {
        let state = state.clone();
        let weak = ui.as_weak();
        ui.on_set_active_profile(move |profile| {
            if let Some(ui) = weak.upgrade() {
                set_active_profile(&ui, &mut state.borrow_mut(), profile.to_string());
            }
        });
    }
    {
        let state = state.clone();
        let weak = ui.as_weak();
        ui.on_add_profile(move |name| {
            if let Some(ui) = weak.upgrade() {
                add_profile(&ui, &mut state.borrow_mut(), name.to_string());
            }
        });
    }
    {
        let state = state.clone();
        let weak = ui.as_weak();
        ui.on_rename_profile(move |name| {
            if let Some(ui) = weak.upgrade() {
                rename_profile(&ui, &mut state.borrow_mut(), name.to_string());
            }
        });
    }
    {
        let state = state.clone();
        let weak = ui.as_weak();
        ui.on_remove_profile(move || {
            if let Some(ui) = weak.upgrade() {
                remove_profile(&ui, &mut state.borrow_mut());
            }
        });
    }
    {
        let weak = ui.as_weak();
        ui.on_create_shortcut(move || match create_shortcut() {
            Ok(()) => {
                if let Some(ui) = weak.upgrade() {
                    ui.set_status("Shortcut created.".into());
                }
            }
            Err(error) => show_message("Could not create shortcut", &error, MessageLevel::Error),
        });
    }

    load_root(&ui, &state, default_config_root());
    ui.run()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shipped_default_action_resets_core_bindings_and_base_profile() {
        let mut state = EditorState::new();

        let core_key = "copy_text_mode";
        let core_default = state.catalog.core_defaults[core_key].clone();
        state
            .core
            .values
            .insert(core_key.to_owned(), "custom-core-value".to_owned());
        restore_shipped_default(&mut state, 0, core_key).unwrap();
        assert_eq!(state.core.values[core_key], core_default);

        let binding_key = "menu_key_open";
        let binding_default = state.catalog.core_defaults[binding_key].clone();
        state
            .bindings
            .values
            .insert(binding_key.to_owned(), "custom-binding".to_owned());
        state.bindings.values.insert(
            "binding_scope_menu_key_open".to_owned(),
            "advanced-menu".to_owned(),
        );
        restore_shipped_default(&mut state, 1, binding_key).unwrap();
        assert_eq!(state.bindings.values[binding_key], binding_default);
        assert_eq!(
            state.bindings.values["binding_scope_menu_key_open"],
            state.catalog.core_defaults["binding_scope_menu_key_open"]
        );

        let profile_key = "video_codec";
        let profile_default = state.catalog.profile_defaults[profile_key].clone();
        state.profile.profile = Some(BASE_PROFILE.to_owned());
        state
            .profile
            .values
            .insert(profile_key.to_owned(), "custom-profile-value".to_owned());
        restore_shipped_default(&mut state, 2, profile_key).unwrap();
        assert_eq!(state.profile.values[profile_key], profile_default);
    }

    #[test]
    fn shipped_default_action_rejects_custom_profiles_and_unknown_settings() {
        let mut state = EditorState::new();
        state.profile.profile = Some("custom".to_owned());
        assert!(restore_shipped_default(&mut state, 2, "video_codec").is_err());
        assert!(restore_shipped_default(&mut state, 0, "unknown-setting").is_err());
    }

    #[test]
    fn binding_scope_choices_update_the_existing_scope_setting() {
        let mut state = EditorState::new();
        state.bindings.values = state.catalog.core_defaults.clone();
        state
            .bindings
            .values
            .insert("menu_key_seek_next".to_owned(), "ctrl+a".to_owned());
        state
            .bindings
            .values
            .insert("global_key_copy_primary".to_owned(), "ctrl+a".to_owned());
        set_binding_scope(&mut state, "menu_key_seek_next", "Global (any time)").unwrap();
        assert_eq!(
            state.bindings.values["binding_scope_menu_key_seek_next"],
            "global"
        );
        assert_eq!(state.bindings.values["menu_key_seek_next"], "ctrl+a");
        assert!(validate_key_bindings(&state.bindings.values).is_err());
        assert!(set_binding_scope(&mut state, "unknown", "Global (any time)").is_err());
        assert!(set_binding_scope(&mut state, "menu_key_seek_next", "Everywhere").is_err());
    }
}
