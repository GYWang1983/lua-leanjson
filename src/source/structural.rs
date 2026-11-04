//! Selective structural offsets: validated value-string boundaries, never bodies.
//! Capacity (including unused slots) is charged to the shared source budget.
#[derive(Clone, Copy)]
pub(crate) struct StringSpan { pub start: u64, pub end: u64, pub flags: u32 }
#[derive(Default)]
pub(crate) struct StructuralIndex { entries: Vec<StringSpan> }
pub(crate) type SharedIndex = std::rc::Rc<std::cell::RefCell<StructuralIndex>>;
impl StructuralIndex {
    pub(crate) fn bytes(&self) -> usize { self.entries.capacity() * std::mem::size_of::<StringSpan>() }
    pub(crate) fn clear(&mut self) { self.entries = Vec::new(); }
    pub(crate) fn insert(&mut self, entry: StringSpan, available: usize) {
        if self.entries.len() == self.entries.capacity() {
            let growth = self.entries.capacity().max(1);
            if growth.saturating_mul(std::mem::size_of::<StringSpan>()) > available { return; }
            self.entries.reserve_exact(growth);
        }
        self.entries.push(entry);
    }
    pub(crate) fn get(&self, start: u64) -> Option<StringSpan> {
        self.entries.binary_search_by_key(&start, |entry| entry.start).ok().map(|index| self.entries[index])
    }
    pub(crate) fn read_length(&self, offset: u64, length: usize) -> usize {
        let index = self.entries.partition_point(|entry| entry.start < offset);
        match self.entries.get(index) {
            Some(entry) => length.min((entry.start - offset).saturating_add(1).min(usize::MAX as u64) as usize),
            None => length,
        }
    }
}
