use std::{
    collections::HashSet,
    env, fs,
    path::{Path, PathBuf},
};

const TOOLS: &[(&str, &[&str])] = &[
    ("MPV", &["mpv", "mpv.exe", "io.mpv.Mpv"]),
    ("FFmpeg", &["ffmpeg", "ffmpeg.exe"]),
    (
        "Anki",
        &["anki", "anki.exe", "Anki.exe", "net.ankiweb.Anki"],
    ),
    ("SSH", &["ssh", "ssh.exe"]),
    ("curl", &["curl", "curl.exe"]),
    ("Wayland clipboard (wl-copy)", &["wl-copy", "wl-copy.exe"]),
    ("X11 clipboard (xclip)", &["xclip", "xclip.exe"]),
    ("macOS clipboard (pbcopy)", &["pbcopy"]),
    ("GoldenDict", &["goldendict", "goldendict.exe"]),
    (
        "PowerShell",
        &["pwsh", "pwsh.exe", "powershell", "powershell.exe"],
    ),
    ("Windows clipboard (clip.exe)", &["clip.exe"]),
    ("BurntToast (PowerShell module)", &[]),
];

pub struct ToolScanResult {
    pub name: &'static str,
    pub path: Option<PathBuf>,
    pub others: Vec<PathBuf>,
}

pub struct ScanReport {
    pub tools: Vec<ToolScanResult>,
    pub details: String,
}

#[derive(Default)]
struct MpvInstall {
    exe: PathBuf,
    kind: &'static str,
    config: Option<PathBuf>,
}

#[derive(Default)]
struct MpvConfig {
    root: PathBuf,
    kind: &'static str,
    addon: bool,
    mpv_exe: Option<PathBuf>,
}

pub fn scan(selected_root: Option<&Path>) -> Result<ScanReport, String> {
    let os = env::consts::OS;
    let home = dirs::home_dir().unwrap_or_else(|| PathBuf::from("."));
    let path_dirs: Vec<PathBuf> = env::var_os("PATH")
        .map(|path| env::split_paths(&path).collect())
        .unwrap_or_default();
    let candidates = common_directories(os, &home);
    let mut warnings = Vec::new();

    let mut tool_results = Vec::new();
    let mut mpv_executables = Vec::new();
    for (name, aliases) in TOOLS {
        let resolved = aliases
            .iter()
            .find_map(|alias| find_on_path(alias, &path_dirs));
        let mut other_paths = Vec::new();
        for directory in &candidates {
            for alias in *aliases {
                add_existing(&mut other_paths, &directory.join(alias));
            }
        }
        deduplicate(&mut other_paths);
        other_paths.retain(|path| {
            resolved
                .as_ref()
                .is_none_or(|found| !same_path(path, found))
        });
        if *name == "MPV" {
            if let Some(path) = &resolved {
                mpv_executables.push(path.clone());
            }
            mpv_executables.extend(other_paths.iter().cloned());
        }
        tool_results.push(ToolScanResult {
            name,
            path: resolved,
            others: other_paths,
        });
    }
    deduplicate(&mut mpv_executables);

    if os == "windows" {
        let module_paths = burnt_toast_paths();
        if let Some(result) = tool_results
            .iter_mut()
            .find(|result| result.name.starts_with("BurntToast"))
        {
            result.others = module_paths;
        }
    }

    let mut configs = system_config_roots(os);
    let mut installs = Vec::new();
    for executable in mpv_executables {
        let portable = executable
            .parent()
            .unwrap_or_else(|| Path::new("."))
            .join("portable_config");
        if portable.is_dir() {
            configs.push((portable.clone(), "portable"));
            installs.push(MpvInstall {
                exe: executable,
                kind: "portable",
                config: Some(portable),
            });
        } else {
            installs.push(MpvInstall {
                exe: executable,
                kind: "standard",
                config: None,
            });
        }
    }
    let mut findings = Vec::new();
    let mut seen = HashSet::new();
    for (root, kind) in configs {
        if !root.is_dir() {
            continue;
        }
        let canonical = fs::canonicalize(&root).unwrap_or(root);
        let key = canonical.to_string_lossy().to_ascii_lowercase();
        if seen.insert(key) {
            findings.push(MpvConfig {
                addon: addon_installed(&canonical, &mut warnings),
                mpv_exe: if kind == "portable" {
                    installs
                        .iter()
                        .find(|install| {
                            install
                                .config
                                .as_ref()
                                .is_some_and(|path| same_path(path, &canonical))
                        })
                        .map(|install| install.exe.clone())
                } else {
                    None
                },
                root: canonical,
                kind,
            });
        }
    }

    let mut lines = vec!["MPV installation candidates".to_owned()];
    if installs.is_empty() {
        lines.push("- No MPV executable candidates found.".to_owned());
    } else {
        for install in installs {
            let portable = install
                .config
                .map(|path| format!("; portable config: {}", path.display()))
                .unwrap_or_default();
            let label = if install.kind == "portable" {
                "portable install"
            } else {
                "standard install candidate"
            };
            lines.push(format!("- {} [{label}{portable}]", install.exe.display()));
        }
    }
    lines.extend(["".to_owned(), "MPV config candidates".to_owned()]);
    if findings.is_empty() {
        lines.push("- No standard config roots found.".to_owned());
    } else {
        for candidate in findings {
            let addon = if candidate.addon {
                "MPV Anki Clips found"
            } else {
                "add-on not found"
            };
            let exe = candidate
                .mpv_exe
                .map(|path| format!("; mpv executable: {}", path.display()))
                .unwrap_or_default();
            lines.push(format!(
                "- {} [{}; {addon}{exe}]",
                candidate.root.display(),
                candidate.kind
            ));
        }
    }
    if let Some(root) = selected_root {
        let root = fs::canonicalize(root).unwrap_or_else(|_| root.to_owned());
        let kind = if system_config_roots(os)
            .iter()
            .any(|(known, _)| same_path(known, &root))
        {
            "system"
        } else {
            "not classified by this scan"
        };
        lines.push(format!(
            "- Current editor target: {} [{}]",
            root.display(),
            kind
        ));
    }
    lines.extend([
        String::new(),
        "PATH shows the executable a terminal launch resolves. Multiple config candidates may exist; mpv command-line options such as --config-dir can override defaults.".to_owned(),
    ]);
    if !warnings.is_empty() {
        lines.extend(["".to_owned(), "Scan notes".to_owned()]);
        lines.extend(warnings.into_iter().map(|warning| format!("- {warning}")));
    }
    Ok(ScanReport {
        tools: tool_results,
        details: lines.join("\n"),
    })
}

fn common_directories(os: &str, home: &Path) -> Vec<PathBuf> {
    let mut result = Vec::new();
    if os == "windows" {
        for variable in ["ProgramFiles", "ProgramFiles(x86)"] {
            if let Some(root) = env::var_os(variable) {
                let root = PathBuf::from(root);
                result.extend([root.join("mpv"), root.join("ffmpeg/bin"), root.join("Anki")]);
            }
        }
        if let Some(local) = env::var_os("LOCALAPPDATA") {
            let local = PathBuf::from(local);
            result.extend([local.join("Programs/mpv"), local.join("Programs/Anki")]);
        }
        if let Some(appdata) = env::var_os("APPDATA") {
            result.push(PathBuf::from(appdata).join("AnkiProgramFiles"));
        }
    } else if os == "macos" {
        result.extend([
            PathBuf::from("/Applications/mpv.app/Contents/MacOS"),
            PathBuf::from("/Applications/Anki.app/Contents/MacOS"),
            PathBuf::from("/opt/homebrew/bin"),
            PathBuf::from("/usr/local/bin"),
            home.join(".local/share/flatpak/exports/bin"),
            PathBuf::from("/var/lib/flatpak/exports/bin"),
        ]);
    } else {
        result.extend([
            PathBuf::from("/usr/bin"),
            PathBuf::from("/usr/local/bin"),
            PathBuf::from("/opt/mpv"),
            home.join(".local/bin"),
            home.join(".local/share/Anki"),
        ]);
    }
    result
}

fn find_on_path(name: &str, directories: &[PathBuf]) -> Option<PathBuf> {
    directories
        .iter()
        .map(|directory| directory.join(name))
        .find(|path| path.is_file())
}

fn add_existing(paths: &mut Vec<PathBuf>, path: &Path) {
    if path.is_file() {
        paths.push(fs::canonicalize(path).unwrap_or_else(|_| path.to_owned()));
    }
}

fn deduplicate(paths: &mut Vec<PathBuf>) {
    let mut seen = HashSet::new();
    paths.retain(|path| seen.insert(path.to_string_lossy().to_ascii_lowercase()));
}

fn same_path(first: &Path, second: &Path) -> bool {
    fs::canonicalize(first)
        .unwrap_or_else(|_| first.to_owned())
        .to_string_lossy()
        .eq_ignore_ascii_case(
            &fs::canonicalize(second)
                .unwrap_or_else(|_| second.to_owned())
                .to_string_lossy(),
        )
}

fn system_config_roots(os: &str) -> Vec<(PathBuf, &'static str)> {
    if os == "windows" {
        env::var_os("APPDATA")
            .map(|path| vec![(PathBuf::from(path).join("mpv"), "system")])
            .unwrap_or_default()
    } else {
        let mut roots = Vec::new();
        if let Some(xdg) = env::var_os("XDG_CONFIG_HOME") {
            roots.push((PathBuf::from(xdg).join("mpv"), "system"));
        }
        if let Some(home) = dirs::home_dir() {
            roots.push((home.join(".config/mpv"), "system"));
            if os == "linux" {
                roots.push((home.join(".var/app/io.mpv.Mpv/config/mpv"), "Flatpak"));
            }
        }
        roots
    }
}

fn addon_installed(root: &Path, warnings: &mut Vec<String>) -> bool {
    let scripts = root.join("scripts");
    if scripts.join("mpv-anki-clips/mpv-anki-clips.lua").is_file() {
        return true;
    }
    match fs::read_dir(&scripts) {
        Ok(entries) => entries.flatten().any(|entry| {
            entry.path().is_dir() && entry.path().join("mpv-anki-clips.lua").is_file()
        }),
        Err(error) if scripts.is_dir() => {
            warnings.push(format!("Could not inspect {}: {error}", scripts.display()));
            false
        }
        _ => false,
    }
}

fn burnt_toast_paths() -> Vec<PathBuf> {
    let mut candidates = Vec::new();
    if let Some(profile) = env::var_os("USERPROFILE") {
        let docs = PathBuf::from(profile).join("Documents");
        candidates.extend([
            docs.join("PowerShell/Modules/BurntToast"),
            docs.join("WindowsPowerShell/Modules/BurntToast"),
        ]);
    }
    if let Some(program_files) = env::var_os("ProgramFiles") {
        let root = PathBuf::from(program_files);
        candidates.extend([
            root.join("WindowsPowerShell/Modules/BurntToast"),
            root.join("PowerShell/Modules/BurntToast"),
        ]);
    }
    if let Some(paths) = env::var_os("PSModulePath") {
        candidates.extend(env::split_paths(&paths).map(|path| path.join("BurntToast")));
    }
    candidates.retain(|path| path.is_dir());
    deduplicate(&mut candidates);
    candidates
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lightweight_scan_only_checks_path_and_known_locations() {
        let report = scan(None).unwrap();
        assert!(report.details.contains("MPV installation candidates"));
        assert!(report
            .details
            .contains("PATH shows the executable a terminal launch resolves."));
    }
}
