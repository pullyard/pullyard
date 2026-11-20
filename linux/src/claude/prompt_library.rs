use std::cell::RefCell;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct SavedPrompt {
    pub id: String,
    pub title: String,
    pub text: String,
}

pub struct PromptLibrary {
    prompts: Vec<SavedPrompt>,
    file: Option<PathBuf>,
}

pub fn title_for(text: &str) -> String {
    let line = text.trim().lines().next().unwrap_or("").trim_end();
    if line.chars().count() > 48 {
        format!("{}…", line.chars().take(47).collect::<String>())
    } else {
        line.to_string()
    }
}

impl PromptLibrary {
    pub fn new(file: Option<PathBuf>) -> Self {
        let prompts: Vec<SavedPrompt> = file.as_ref().and_then(|f| std::fs::read(f).ok()).and_then(|d| serde_json::from_slice(&d).ok()).unwrap_or_default();
        PromptLibrary { prompts, file }
    }

    pub fn prompts(&self) -> &[SavedPrompt] {
        &self.prompts
    }

    pub fn add(&mut self, raw: &str, title: Option<&str>) -> Option<SavedPrompt> {
        let text = raw.trim();
        if text.is_empty() {
            return None;
        }
        if let Some(existing) = self.prompts.iter().find(|p| p.text == text) {
            return Some(existing.clone());
        }
        let name = title.map(|t| t.trim()).unwrap_or("");
        let prompt = SavedPrompt { id: uuid::Uuid::new_v4().to_string(), title: if name.is_empty() { title_for(text) } else { name.to_string() }, text: text.to_string() };
        self.prompts.push(prompt.clone());
        self.save();
        Some(prompt)
    }

    pub fn update(&mut self, prompt: SavedPrompt) {
        let Some(index) = self.prompts.iter().position(|p| p.id == prompt.id) else { return };
        self.prompts[index] = prompt;
        self.save();
    }

    pub fn remove(&mut self, id: &str) {
        self.prompts.retain(|p| p.id != id);
        self.save();
    }

    fn save(&self) {
        let Some(file) = &self.file else { return };
        if let Some(dir) = file.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        if let Ok(data) = serde_json::to_vec(&self.prompts) {
            let tmp = file.with_extension("json.tmp");
            if std::fs::write(&tmp, data).is_ok() {
                let _ = std::fs::rename(&tmp, file);
            }
        }
    }
}

thread_local! {
    static LIBRARY: RefCell<Option<PromptLibrary>> = const { RefCell::new(None) };
}

fn default_file() -> Option<PathBuf> {
    if cfg!(test) {
        None
    } else {
        Some(crate::settings::data_dir().join("saved-prompts.json"))
    }
}

fn with<T>(f: impl FnOnce(&mut PromptLibrary) -> T) -> T {
    LIBRARY.with(|l| {
        let mut l = l.borrow_mut();
        f(l.get_or_insert_with(|| PromptLibrary::new(default_file())))
    })
}

pub fn all() -> Vec<SavedPrompt> {
    with(|l| l.prompts().to_vec())
}

pub fn add(text: &str, title: Option<&str>) -> Option<SavedPrompt> {
    with(|l| l.add(text, title))
}

pub fn update(prompt: SavedPrompt) {
    with(|l| l.update(prompt));
}

pub fn remove(id: &str) {
    with(|l| l.remove(id));
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_file() -> PathBuf {
        std::env::temp_dir().join(format!("pullyard-prompts-{}.json", uuid::Uuid::new_v4()))
    }

    #[test]
    fn add_deduplicates_and_persists() {
        let file = temp_file();
        let mut lib = PromptLibrary::new(Some(file.clone()));
        assert!(lib.add("   ", None).is_none());
        let first = lib.add("  Review my changes\nand list risks  ", None).expect("added");
        assert_eq!(first.title, "Review my changes");
        assert_eq!(first.text, "Review my changes\nand list risks");
        assert_eq!(lib.add("Review my changes\nand list risks", None).map(|p| p.id), Some(first.id.clone()));
        assert_eq!(lib.prompts().len(), 1);
        assert_eq!(PromptLibrary::new(Some(file.clone())).prompts(), lib.prompts());
        let _ = std::fs::remove_file(&file);
    }

    #[test]
    fn update_and_remove() {
        let file = temp_file();
        let mut lib = PromptLibrary::new(Some(file.clone()));
        let mut prompt = lib.add("one", Some(" First ")).expect("added");
        assert_eq!(prompt.title, "First");
        prompt.text = "two".into();
        lib.update(prompt.clone());
        assert_eq!(lib.prompts().first().map(|p| p.text.as_str()), Some("two"));
        lib.update(SavedPrompt { id: "missing".into(), title: "x".into(), text: "y".into() });
        assert_eq!(lib.prompts().len(), 1);
        lib.remove(&prompt.id);
        assert!(PromptLibrary::new(Some(file.clone())).prompts().is_empty());
        let _ = std::fs::remove_file(&file);
    }

    #[test]
    fn long_title_is_shortened() {
        assert_eq!(title_for(&"a".repeat(80)).chars().count(), 48);
        assert_eq!(title_for("  short\nrest"), "short");
        assert_eq!(title_for(""), "");
    }

    #[test]
    fn shared_library_works_without_a_file() {
        let added = add("Explain this module", None).expect("added");
        assert_eq!(all(), vec![added.clone()]);
        update(SavedPrompt { title: "Explain".into(), ..added.clone() });
        assert_eq!(all()[0].title, "Explain");
        remove(&added.id);
        assert!(all().is_empty());
    }
}
