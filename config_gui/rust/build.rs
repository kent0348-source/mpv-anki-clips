fn main() {
    let config = slint_build::CompilerConfiguration::new().with_style("fluent-dark".into());
    slint_build::compile_with_config("ui/main.slint", config).expect("failed to compile Slint UI");

    println!("cargo:rerun-if-changed=assets/app_icon.ico");
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("windows") {
        let manifest_dir = std::env::var("CARGO_MANIFEST_DIR")
            .expect("Cargo sets CARGO_MANIFEST_DIR for build scripts");
        let icon_path = format!("{manifest_dir}/assets/app_icon.ico");
        winres::WindowsResource::new()
            .set_icon(&icon_path)
            .compile()
            .expect("failed to embed the Windows application icon");
    }
}
