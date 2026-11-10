//! Memorable generated passwords for new users ("swift-otter-0427").

const ADJECTIVES: &[&str] = &[
    "brave", "calm", "clever", "crisp", "eager", "fair", "golden", "happy", "jolly", "kind",
    "lively", "merry", "noble", "proud", "quick", "quiet", "rapid", "silver", "swift", "witty",
    "zesty",
];

const NOUNS: &[&str] = &[
    "otter", "badger", "falcon", "panda", "hawk", "tiger", "wolf", "lynx", "heron", "fox", "raven",
    "eagle", "lion", "ocelot", "koala", "bison", "dolphin", "crane", "sparrow",
];

#[must_use]
pub fn generate() -> String {
    let adjective = ADJECTIVES[rand::random_range(0..ADJECTIVES.len())];
    let noun = NOUNS[rand::random_range(0..NOUNS.len())];
    let number: u16 = rand::random_range(0..10_000);
    format!("{adjective}-{noun}-{number:04}")
}

#[cfg(test)]
mod tests {
    #[test]
    fn has_three_parts() {
        let password = super::generate();
        let parts: Vec<&str> = password.split('-').collect();
        assert_eq!(parts.len(), 3);
        assert_eq!(parts[2].len(), 4);
    }
}
