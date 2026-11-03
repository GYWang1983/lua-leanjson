//! Native comment trivia with constant state and no retained payload.
#[derive(Clone, Copy)]
pub(super) enum Comment { Start, Line, Block, Star }
pub(super) enum Step { More, End, EndInput, Invalid, Unclosed }
impl Comment {
    pub(super) fn feed(&mut self, byte: u8) -> Step {
        use Comment::*;
        match (*self, byte) {
            (Start, b'/') => *self = Line,
            (Start, b'*') => *self = Block,
            (Start, _) => return Step::Invalid,
            (Line, b'\n') => return Step::End,
            (Line, 0) => return Step::EndInput,
            (Line, _) => {},
            (Block | Star, 0) => return Step::Unclosed,
            (Star, b'/') => return Step::End,
            (Block | Star, b'*') => *self = Star,
            (Block | Star, _) => *self = Block,
        }
        Step::More
    }
    pub(super) fn eof_error(self) -> Option<&'static str> {
        match self { Self::Start => Some("invalid token"), Self::Line => None,
            Self::Block | Self::Star => Some("unclosed multi-line comment") }
    }
}
