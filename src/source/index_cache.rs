//! Exact final lookup results only. Vector capacity and owned key bytes are
//! charged; there is no auxiliary hash table or retained sibling scan history.
use super::{Span, SpanMember};
use super::sparse::Lookup;
#[derive(Clone, Copy)]
struct CachedMember { ordinal: u64, key_start: u64, key_end: u64, value: Span }
struct Entry { container: u64, lookup: Lookup, member: Option<CachedMember> }
#[derive(Default)]
pub(crate) struct LookupCache { entries: Vec<Entry>, key_bytes: usize, pub hits: u64, pub misses: u64 }
impl LookupCache {
    pub(crate) fn bytes(&self) -> usize { self.entries.capacity() * std::mem::size_of::<Entry>() + self.key_bytes }
    pub(crate) fn clear(&mut self) { self.entries = Vec::new(); self.key_bytes = 0; }
    pub(crate) fn contains(&self, container: u64, lookup: &Lookup) -> bool {
        self.entries.iter().any(|entry| entry.container == container && &entry.lookup == lookup)
    }
    pub(crate) fn get(&mut self, container: u64, lookup: &Lookup) -> Option<Option<SpanMember>> {
        let entry = self.entries.iter().find(|entry| entry.container == container && &entry.lookup == lookup);
        if let Some(entry) = entry {
            self.hits = self.hits.saturating_add(1);
            Some(entry.member.map(|member| SpanMember { ordinal: member.ordinal, key_start: member.key_start,
                key_end: member.key_end, key: match &entry.lookup { Lookup::Key(key) => key.clone(), Lookup::Index(_) => Vec::new() }, value: member.value }))
        } else { self.misses = self.misses.saturating_add(1); None }
    }
    pub(crate) fn insertion_cost(&self, lookup: &Lookup) -> usize {
        let growth = if self.entries.len() == self.entries.capacity() { self.entries.capacity().max(1) } else { 0 };
        growth.saturating_mul(std::mem::size_of::<Entry>()).saturating_add(match lookup { Lookup::Key(key) => key.len(), Lookup::Index(_) => 0 })
    }
    pub(crate) fn insert(&mut self, container: u64, lookup: &Lookup, member: Option<&SpanMember>) {
        if self.contains(container, lookup) { return; }
        if self.entries.len() == self.entries.capacity() { self.entries.reserve_exact(self.entries.capacity().max(1)); }
        let lookup = match lookup { Lookup::Key(key) => {
            let key = key.clone().into_boxed_slice().into_vec(); self.key_bytes += key.capacity(); Lookup::Key(key)
        }, Lookup::Index(index) => Lookup::Index(*index) };
        self.entries.push(Entry { container, lookup, member: member.map(|member| CachedMember {
            ordinal: member.ordinal, key_start: member.key_start, key_end: member.key_end, value: member.value }) });
    }
}
