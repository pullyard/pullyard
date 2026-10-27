pub const APP_NAME: &str = env!("BRAND_APP_NAME");
pub const APP_ID: &str = env!("BRAND_APP_ID");
pub const BIN_NAME: &str = env!("BRAND_BIN_NAME");
pub const GITHUB_OWNER: &str = env!("BRAND_GITHUB_OWNER");
pub const GITHUB_REPO: &str = env!("BRAND_GITHUB_REPO");
pub const DONATE_URL: &str = env!("BRAND_DONATE_URL");
pub const URL_SCHEME: &str = env!("BRAND_URL_SCHEME");
pub const ENV_PREFIX: &str = env!("BRAND_ENV_PREFIX");
pub const TAGLINE: &str = env!("BRAND_APP_SUMMARY");
pub const VERSION: &str = env!("BRAND_VERSION");

pub const SKY: (&str, &str) = (env!("BRAND_COLOR_SKY"), env!("BRAND_COLOR_SKY_DARK"));
pub const VIOLET: (&str, &str) = (env!("BRAND_COLOR_VIOLET"), env!("BRAND_COLOR_VIOLET_DARK"));
pub const CORAL: (&str, &str) = (env!("BRAND_COLOR_CORAL"), env!("BRAND_COLOR_CORAL_DARK"));
pub const GREEN: (&str, &str) = (env!("BRAND_COLOR_GREEN"), env!("BRAND_COLOR_GREEN_DARK"));
pub const AMBER: (&str, &str) = (env!("BRAND_COLOR_AMBER"), env!("BRAND_COLOR_AMBER_DARK"));
pub const MARK_VIOLET: &str = env!("BRAND_MARK_VIOLET");
pub const MARK_SKY: &str = env!("BRAND_MARK_SKY");
pub const MARK_CORAL: &str = env!("BRAND_MARK_CORAL");
pub const MARK_CORAL_DEEP: &str = env!("BRAND_MARK_CORAL_DEEP");

pub fn rgb(hex: &str) -> (f64, f64, f64) {
    let h = hex.trim_start_matches('#');
    let channel = |i: usize| h.get(i..i + 2).and_then(|c| u8::from_str_radix(c, 16).ok()).unwrap_or(0) as f64 / 255.0;
    (channel(0), channel(2), channel(4))
}

pub fn pick(pair: (&'static str, &'static str), dark: bool) -> &'static str {
    if dark {
        pair.1
    } else {
        pair.0
    }
}

pub fn user_agent() -> String {
    format!("{APP_NAME}-Linux/{VERSION}")
}

pub fn repo_url() -> String {
    format!("https://github.com/{GITHUB_OWNER}/{GITHUB_REPO}")
}

pub fn releases_page() -> String {
    format!("{}/releases/latest", repo_url())
}

pub fn changelog_url(version: &str) -> String {
    format!("https://{GITHUB_OWNER}.github.io/{GITHUB_REPO}/changelog.html#v{version}")
}

pub fn latest_release_api() -> String {
    format!("https://api.github.com/repos/{GITHUB_OWNER}/{GITHUB_REPO}/releases/latest")
}

pub fn env_var(name: &str) -> Option<String> {
    std::env::var(format!("{ENV_PREFIX}_{name}")).ok().filter(|v| !v.is_empty())
}

pub fn env_key(name: &str) -> String {
    format!("{ENV_PREFIX}_{name}")
}

pub fn arch() -> &'static str {
    std::env::consts::ARCH
}

pub fn tarball_asset_name() -> String {
    format!("{APP_NAME}-linux-{}.tar.gz", arch())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn brand_colors_parse() {
        assert_eq!(rgb("#FF0080"), (1.0, 0.0, 128.0 / 255.0));
        for hex in [SKY.0, SKY.1, VIOLET.0, VIOLET.1, CORAL.0, CORAL.1, GREEN.0, GREEN.1, AMBER.0, AMBER.1, MARK_VIOLET, MARK_SKY, MARK_CORAL, MARK_CORAL_DEEP] {
            assert!(hex.starts_with('#') && hex.len() == 7, "{hex}");
        }
        assert_eq!(pick(CORAL, true), CORAL.1);
    }
}
