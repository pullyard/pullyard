use std::env;
use std::fs;

fn main() {
    println!("cargo:rerun-if-changed=brand.env");
    println!("cargo:rerun-if-env-changed=PULLYARD_VERSION");
    println!("cargo:rerun-if-env-changed=PULLYARD_GITHUB_CLIENT_ID");
    let text = fs::read_to_string("brand.env").expect("brand.env is missing");
    let mut client_id = String::new();
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if let Some((key, value)) = line.split_once('=') {
            if key.trim() == "GITHUB_CLIENT_ID" {
                client_id = value.trim().trim_matches('"').to_string();
                continue;
            }
            println!("cargo:rustc-env=BRAND_{}={}", key.trim(), value.trim().trim_matches('"'));
        }
    }
    if let Some(id) = env::var("PULLYARD_GITHUB_CLIENT_ID").ok().map(|v| v.trim().to_string()).filter(|v| !v.is_empty()) {
        client_id = id;
    }
    let client_id: String = client_id.chars().filter(|c| c.is_ascii_alphanumeric() || *c == '.' || *c == '_' || *c == '-').collect();
    println!("cargo:rustc-env=BRAND_GITHUB_CLIENT_ID={client_id}");
    let version = env::var("PULLYARD_VERSION")
        .ok()
        .map(|v| v.trim().trim_start_matches(['v', 'V']).to_string())
        .filter(|v| !v.is_empty())
        .unwrap_or_else(|| env::var("CARGO_PKG_VERSION").unwrap_or_default());
    println!("cargo:rustc-env=BRAND_VERSION={version}");
}
