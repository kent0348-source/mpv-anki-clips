use std::path::{Path, PathBuf};

#[cfg(any(target_os = "linux", target_os = "macos"))]
use std::process::Command;

const EXTENSIONS: &[(&str, &str)] = &[
    ("mp4", "video/mp4"),
    ("mkv", "video/x-matroska"),
    ("webm", "video/webm"),
    ("mov", "video/quicktime"),
    ("avi", "video/x-msvideo"),
    ("m4v", "video/x-m4v"),
    ("mpeg", "video/mpeg"),
    ("mpg", "video/mpeg"),
    ("ts", "video/mp2t"),
    ("mp3", "audio/mpeg"),
    ("m4a", "audio/mp4"),
    ("flac", "audio/flac"),
    ("ogg", "audio/ogg"),
    ("opus", "audio/opus"),
    ("wav", "audio/wav"),
];

pub struct AssociationResult {
    pub extension: &'static str,
    pub handler: Option<String>,
    pub executable: Option<PathBuf>,
    pub error: Option<String>,
}

impl AssociationResult {
    fn missing(extension: &'static str) -> Self {
        Self {
            extension,
            handler: None,
            executable: None,
            error: None,
        }
    }

    fn error(extension: &'static str, error: String) -> Self {
        Self {
            extension,
            handler: None,
            executable: None,
            error: Some(error),
        }
    }
}

pub fn scan() -> Vec<AssociationResult> {
    #[cfg(target_os = "windows")]
    {
        return scan_windows();
    }
    #[cfg(target_os = "linux")]
    {
        return scan_linux();
    }
    #[cfg(target_os = "macos")]
    {
        return scan_macos();
    }
    #[allow(unreachable_code)]
    EXTENSIONS
        .iter()
        .map(|(extension, _)| {
            AssociationResult::error(
                extension,
                "Default media app lookup is not supported on this platform.".to_owned(),
            )
        })
        .collect()
}

pub fn is_mpv_handler(handler: Option<&str>, executable: Option<&Path>) -> bool {
    let handler_matches = handler.is_some_and(|handler| {
        let lower = handler.to_ascii_lowercase();
        lower.contains("mpv") || lower == "io.mpv.mpv"
    });
    let executable_matches = executable.and_then(Path::file_name).is_some_and(|name| {
        name.to_string_lossy()
            .to_ascii_lowercase()
            .starts_with("mpv")
    });
    handler_matches || executable_matches
}

#[cfg(target_os = "windows")]
fn scan_windows() -> Vec<AssociationResult> {
    EXTENSIONS
        .iter()
        .map(|(extension, _)| scan_windows_extension(extension))
        .collect()
}

#[cfg(target_os = "windows")]
fn scan_windows_extension(extension: &'static str) -> AssociationResult {
    let extension_key = format!(".{extension}");
    let user_choice = format!(
        "Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\FileExts\\{extension_key}\\UserChoice"
    );
    let prog_id = match registry_string(RegistryRoot::CurrentUser, &user_choice, "ProgId") {
        Ok(Some(prog_id)) => Some(prog_id),
        Ok(None) => match registry_string(
            RegistryRoot::CurrentUser,
            &format!("Software\\Classes\\{extension_key}"),
            "",
        ) {
            Ok(Some(prog_id)) => Some(prog_id),
            Ok(None) => match registry_string(RegistryRoot::Classes, &extension_key, "") {
                Ok(prog_id) => prog_id,
                Err(error) => return AssociationResult::error(extension, error),
            },
            Err(error) => return AssociationResult::error(extension, error),
        },
        Err(error) => return AssociationResult::error(extension, error),
    };

    let Some(prog_id) = prog_id else {
        return AssociationResult::missing(extension);
    };

    let command_key = format!("{prog_id}\\shell\\open\\command");
    let open_command = match registry_string(RegistryRoot::Classes, &command_key, "") {
        Ok(command) => command,
        Err(error) => {
            return AssociationResult {
                extension,
                handler: Some(prog_id),
                executable: None,
                error: Some(error),
            };
        }
    };
    let executable = open_command
        .as_deref()
        .and_then(windows_command_executable)
        .filter(|path| path.is_file());
    let error = if open_command.is_none() {
        Some("The handler has no registered open command.".to_owned())
    } else if executable.is_none() {
        Some("The handler's open command does not resolve to an existing executable.".to_owned())
    } else {
        None
    };

    AssociationResult {
        extension,
        handler: Some(prog_id),
        executable,
        error,
    }
}

#[cfg(target_os = "windows")]
fn windows_command_executable(command: &str) -> Option<PathBuf> {
    let command = expand_windows_environment(command.trim());
    let candidate = if let Some(quoted) = command.strip_prefix('"') {
        quoted.split('"').next()?.to_owned()
    } else {
        let lower = command.to_ascii_lowercase();
        let end = lower.find(".exe")? + ".exe".len();
        command[..end].trim().to_owned()
    };
    Some(PathBuf::from(candidate))
}

#[cfg(target_os = "windows")]
fn expand_windows_environment(value: &str) -> String {
    let mut expanded = String::new();
    let mut remaining = value;
    while let Some(start) = remaining.find('%') {
        expanded.push_str(&remaining[..start]);
        let variable_start = start + 1;
        let Some(end_offset) = remaining[variable_start..].find('%') else {
            expanded.push_str(&remaining[start..]);
            return expanded;
        };
        let end = variable_start + end_offset;
        let variable = &remaining[variable_start..end];
        if let Some(value) = std::env::var_os(variable) {
            expanded.push_str(&value.to_string_lossy());
        } else {
            expanded.push_str(&remaining[start..=end]);
        }
        remaining = &remaining[end + 1..];
    }
    expanded.push_str(remaining);
    expanded
}

#[cfg(target_os = "windows")]
#[derive(Clone, Copy)]
enum RegistryRoot {
    CurrentUser,
    Classes,
}

#[cfg(target_os = "windows")]
fn registry_string(
    root: RegistryRoot,
    subkey: &str,
    value_name: &str,
) -> Result<Option<String>, String> {
    use std::{ffi::c_void, ptr};

    type Hkey = *mut c_void;
    type Dword = u32;
    const ERROR_SUCCESS: i32 = 0;
    const ERROR_FILE_NOT_FOUND: i32 = 2;
    const KEY_READ: Dword = 0x20019;
    const REG_SZ: Dword = 1;
    const REG_EXPAND_SZ: Dword = 2;
    const HKEY_CURRENT_USER: Hkey = 0x80000001u32 as usize as Hkey;
    const HKEY_CLASSES_ROOT: Hkey = 0x80000000u32 as usize as Hkey;

    #[link(name = "advapi32")]
    extern "system" {
        fn RegOpenKeyExW(
            key: Hkey,
            subkey: *const u16,
            options: Dword,
            access: Dword,
            result: *mut Hkey,
        ) -> i32;
        fn RegQueryValueExW(
            key: Hkey,
            value_name: *const u16,
            reserved: *mut Dword,
            value_type: *mut Dword,
            data: *mut u8,
            data_size: *mut Dword,
        ) -> i32;
        fn RegCloseKey(key: Hkey) -> i32;
    }

    let root_key = match root {
        RegistryRoot::CurrentUser => HKEY_CURRENT_USER,
        RegistryRoot::Classes => HKEY_CLASSES_ROOT,
    };
    let subkey: Vec<u16> = subkey.encode_utf16().chain(Some(0)).collect();
    let value_name: Vec<u16> = value_name.encode_utf16().chain(Some(0)).collect();
    let mut key = ptr::null_mut();
    let open_result = unsafe { RegOpenKeyExW(root_key, subkey.as_ptr(), 0, KEY_READ, &mut key) };
    if open_result == ERROR_FILE_NOT_FOUND {
        return Ok(None);
    }
    if open_result != ERROR_SUCCESS {
        return Err(format!(
            "Could not read Windows file association (error {open_result})."
        ));
    }

    let mut value_type = 0;
    let mut byte_count = 0;
    let size_result = unsafe {
        RegQueryValueExW(
            key,
            value_name.as_ptr(),
            ptr::null_mut(),
            &mut value_type,
            ptr::null_mut(),
            &mut byte_count,
        )
    };
    if size_result == ERROR_FILE_NOT_FOUND {
        unsafe { RegCloseKey(key) };
        return Ok(None);
    }
    if size_result != ERROR_SUCCESS || !matches!(value_type, REG_SZ | REG_EXPAND_SZ) {
        unsafe { RegCloseKey(key) };
        return Err(format!(
            "Could not read Windows association value (error {size_result})."
        ));
    }

    let mut data = vec![0u8; byte_count as usize];
    let read_result = unsafe {
        RegQueryValueExW(
            key,
            value_name.as_ptr(),
            ptr::null_mut(),
            &mut value_type,
            data.as_mut_ptr(),
            &mut byte_count,
        )
    };
    unsafe { RegCloseKey(key) };
    if read_result != ERROR_SUCCESS {
        return Err(format!(
            "Could not read Windows association value (error {read_result})."
        ));
    }
    let wide: Vec<u16> = data[..byte_count as usize]
        .chunks_exact(2)
        .map(|pair| u16::from_le_bytes([pair[0], pair[1]]))
        .take_while(|unit| *unit != 0)
        .collect();
    Ok(Some(String::from_utf16_lossy(&wide)))
}

#[cfg(target_os = "linux")]
fn scan_linux() -> Vec<AssociationResult> {
    EXTENSIONS
        .iter()
        .map(|(extension, mime)| {
            let output = Command::new("xdg-mime")
                .args(["query", "default", mime])
                .output();
            let output = match output {
                Ok(output) => output,
                Err(error) => {
                    return AssociationResult::error(
                        extension,
                        format!("Could not query the desktop default handler with xdg-mime: {error}"),
                    )
                }
            };
            if !output.status.success() {
                return AssociationResult::error(
                    extension,
                    format!(
                        "xdg-mime could not query {mime}: {}",
                        String::from_utf8_lossy(&output.stderr).trim()
                    ),
                );
            }
            let desktop_id = String::from_utf8_lossy(&output.stdout).trim().to_owned();
            if desktop_id.is_empty() {
                return AssociationResult::missing(extension);
            }
            let desktop_file = linux_desktop_file(&desktop_id);
            let (handler, executable, error) = match desktop_file {
                Some(path) => match std::fs::read_to_string(&path) {
                    Ok(contents) => {
                        let handler = desktop_value(&contents, "Name")
                            .unwrap_or_else(|| desktop_id.clone());
                        let executable = desktop_value(&contents, "Exec")
                            .and_then(|command| linux_command_executable(&command));
                        let error = executable.is_none().then(|| {
                            format!(
                                "The handler is {desktop_id}, but its executable could not be resolved."
                            )
                        });
                        (handler, executable, error)
                    }
                    Err(error) => (
                        desktop_id.clone(),
                        None,
                        Some(format!("Could not read desktop entry {}: {error}", path.display())),
                    ),
                },
                None => (
                    desktop_id.clone(),
                    None,
                    Some(format!("Could not locate desktop entry {desktop_id}.")),
                ),
            };
            AssociationResult {
                extension,
                handler: Some(format!("{handler} ({desktop_id})")),
                executable,
                error,
            }
        })
        .collect()
}

#[cfg(target_os = "linux")]
fn linux_desktop_file(desktop_id: &str) -> Option<PathBuf> {
    let mut data_dirs = Vec::new();
    if let Some(user_data) = std::env::var_os("XDG_DATA_HOME") {
        data_dirs.push(PathBuf::from(user_data));
    } else if let Some(home) = dirs::home_dir() {
        data_dirs.push(home.join(".local/share"));
    }
    let system_dirs = std::env::var_os("XDG_DATA_DIRS")
        .map(|value| std::env::split_paths(&value).collect::<Vec<_>>())
        .filter(|dirs| !dirs.is_empty())
        .unwrap_or_else(|| {
            ["/usr/local/share", "/usr/share"]
                .into_iter()
                .map(PathBuf::from)
                .collect()
        });
    data_dirs.extend(system_dirs);
    let desktop_paths = [
        PathBuf::from(desktop_id),
        PathBuf::from(desktop_id.replace('-', "/")),
    ];
    for directory in data_dirs {
        for desktop_path in &desktop_paths {
            let path = directory.join("applications").join(desktop_path);
            if path.is_file() {
                return Some(path);
            }
        }
    }
    None
}

#[cfg(any(target_os = "linux", test))]
fn desktop_value(contents: &str, key: &str) -> Option<String> {
    let mut in_desktop_entry = false;
    for line in contents.lines() {
        if line.starts_with('[') {
            in_desktop_entry = line == "[Desktop Entry]";
            continue;
        }
        if in_desktop_entry {
            if let Some(value) = line.strip_prefix(&format!("{key}=")) {
                return Some(value.to_owned());
            }
        }
    }
    None
}

#[cfg(target_os = "linux")]
fn linux_command_executable(command: &str) -> Option<PathBuf> {
    let command = command.trim();
    let executable = if let Some(quoted) = command.strip_prefix('"') {
        quoted.split('"').next()?
    } else {
        command.split_whitespace().next()?
    };
    let executable = PathBuf::from(executable);
    if executable.is_absolute() {
        return executable.is_file().then_some(executable);
    }
    std::env::var_os("PATH")
        .into_iter()
        .flat_map(|paths| std::env::split_paths(&paths).collect::<Vec<_>>())
        .map(|directory| directory.join(&executable))
        .find(|path| path.is_file())
}

#[cfg(target_os = "macos")]
fn scan_macos() -> Vec<AssociationResult> {
    let extensions = EXTENSIONS
        .iter()
        .map(|(extension, _)| format!("\"{extension}\""))
        .collect::<Vec<_>>()
        .join(", ");
    let script = format!(
        r#"import AppKit
let extensions = [{extensions}]
for ext in extensions {{
    let url = URL(fileURLWithPath: "/tmp/association-check.\(ext)")
    if let appURL = NSWorkspace.shared.urlForApplication(toOpen: url),
       let bundle = Bundle(url: appURL) {{
        let identifier = bundle.bundleIdentifier ?? ""
        let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? appURL.deletingPathExtension().lastPathComponent
        let executableName = bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String ?? ""
        let executable = appURL.appendingPathComponent("Contents/MacOS").appendingPathComponent(executableName).path
        print([ext, identifier, name, appURL.path, executable].joined(separator: "\t"))
    }} else {{
        print(ext)
    }}
}}
"#
    );
    let output = Command::new("/usr/bin/swift")
        .args(["-e", &script])
        .output();
    let output = match output {
        Ok(output) => output,
        Err(error) => {
            return EXTENSIONS
                .iter()
                .map(|(extension, _)| {
                    AssociationResult::error(
                        extension,
                        format!("Could not query Launch Services using Swift: {error}"),
                    )
                })
                .collect()
        }
    };
    if !output.status.success() {
        let error = format!(
            "Could not query Launch Services using Swift: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        );
        return EXTENSIONS
            .iter()
            .map(|(extension, _)| AssociationResult::error(extension, error.clone()))
            .collect();
    }
    let rows = String::from_utf8_lossy(&output.stdout);
    let mut parsed = rows.lines().filter_map(|line| {
        let mut fields = line.split('\t');
        let extension = fields.next()?;
        let identifier = fields.next()?;
        let name = fields.next()?;
        let _app_path = fields.next()?;
        let executable = fields.next()?;
        let executable_path = PathBuf::from(executable);
        let executable_resolved = executable_path.is_file();
        Some((
            extension,
            AssociationResult {
                extension: EXTENSIONS
                    .iter()
                    .find(|(candidate, _)| *candidate == extension)
                    .map(|(candidate, _)| *candidate)?,
                handler: Some(if identifier.is_empty() {
                    name.to_owned()
                } else {
                    format!("{name} ({identifier})")
                }),
                executable: executable_resolved.then_some(executable_path),
                error: (!executable_resolved).then(|| {
                    "The handler was found, but its executable path could not be resolved."
                        .to_owned()
                }),
            },
        ))
    });
    EXTENSIONS
        .iter()
        .map(|(extension, _)| {
            parsed
                .find(|(candidate, _)| candidate == extension)
                .map(|(_, result)| result)
                .unwrap_or_else(|| AssociationResult::missing(extension))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scan_covers_common_video_and_audio_extensions() {
        let extensions = EXTENSIONS
            .iter()
            .map(|(extension, _)| *extension)
            .collect::<Vec<_>>();
        for extension in [
            "mp4", "mkv", "webm", "mov", "avi", "m4v", "mp3", "m4a", "flac", "ogg", "opus", "wav",
        ] {
            assert!(extensions.contains(&extension));
        }
    }

    #[test]
    fn mpv_handler_detection_uses_handler_identity_or_executable_name() {
        assert!(is_mpv_handler(Some("mpv.desktop"), None));
        assert!(is_mpv_handler(
            Some("Video Player"),
            Some(Path::new("/usr/bin/mpv"))
        ));
        assert!(!is_mpv_handler(
            Some("VLC media player"),
            Some(Path::new("/usr/bin/vlc"))
        ));
    }

    #[test]
    fn linux_desktop_values_are_read_from_desktop_entry() {
        let contents = "[Desktop Entry]\nName=Example Player\nExec=\"/opt/player/bin/player\" %U\n[Desktop Action]\nName=wrong\n";
        assert_eq!(
            desktop_value(contents, "Name").as_deref(),
            Some("Example Player")
        );
        assert_eq!(
            desktop_value(contents, "Exec").as_deref(),
            Some("\"/opt/player/bin/player\" %U")
        );
        assert_eq!(
            desktop_value("[Desktop Action]\nName=wrong\n", "Name"),
            None
        );
    }

    #[cfg(target_os = "windows")]
    #[test]
    fn windows_open_command_extracts_quoted_and_unquoted_paths() {
        assert_eq!(
            windows_command_executable(r#""C:\Program Files\mpv\mpv.exe" "%1""#),
            Some(PathBuf::from(r"C:\Program Files\mpv\mpv.exe"))
        );
        assert_eq!(
            windows_command_executable(r#"C:\mpv\mpv.exe "%1""#),
            Some(PathBuf::from(r"C:\mpv\mpv.exe"))
        );
    }
}
