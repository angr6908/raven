#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Protocol {
    Chat,
    Messages,
    Responses,
    Generate,
}

impl Protocol {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Chat => "chat",
            Self::Messages => "messages",
            Self::Responses => "responses",
            Self::Generate => "generate",
        }
    }
}

impl std::fmt::Display for Protocol {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}
