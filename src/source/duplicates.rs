//! Exact decoded-key duplicate tracking. At most eight short keys stay in RAM;
//! wider objects use owned, unlinked temporary files and an on-disk hash table.
//! Hash equality always falls through to a byte comparison of the full key.
use std::fs::{File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::cell::RefCell;
use std::collections::BTreeMap;
use std::rc::{Rc, Weak};
use std::sync::atomic::{AtomicU64, Ordering};
use super::{SourceError, Span, SpanMember, DETAIL_IO};
use crate::error::{leanjson_err, leanjson_type};

static NEXT_FILE: AtomicU64 = AtomicU64::new(0);
const HEADER: usize = 72;
const SMALL_KEYS: usize = 8;
const SMALL_BYTES: usize = 4096;
fn io_error(_: std::io::Error) -> SourceError {
    SourceError { code: leanjson_err::LEANJSON_OK, detail: DETAIL_IO, offset: u64::MAX }
}
struct Temporary { file: File, path: Option<PathBuf> }
impl Temporary {
    fn new(directory: &Path) -> Result<Self, SourceError> {
        for _ in 0..64 {
            let id = NEXT_FILE.fetch_add(1, Ordering::Relaxed);
            let path = directory.join(format!("leanjson-index-{}-{id}", std::process::id()));
            let mut options = OpenOptions::new();
            options.read(true).write(true).create_new(true);
            #[cfg(unix)] { use std::os::unix::fs::OpenOptionsExt; options.mode(0o600); }
            match options.open(&path) {
                Ok(file) => {
                    // No pathname survives a suspended Lua operation on Unix.
                    #[cfg(unix)] { std::fs::remove_file(&path).map_err(io_error)?; return Ok(Self { file, path: None }); }
                    #[cfg(not(unix))] { return Ok(Self { file, path: Some(path) }); }
                },
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(error) => return Err(io_error(error)),
            }
        }
        Err(io_error(std::io::Error::other("temporary index collision")))
    }
}
impl Drop for Temporary { fn drop(&mut self) { if let Some(path) = &self.path { let _ = std::fs::remove_file(path); } } }
struct Store { temporary: Temporary, end: u64, free: BTreeMap<u64, u64>, live_regions: u64 }
impl Store {
    fn allocate(&mut self, capacity: u64) -> Result<u64, SourceError> {
        let available = self.free.iter().find_map(|(&base, &length)| (length >= capacity).then_some((base, length)));
        let base = if let Some((base, length)) = available {
            self.free.remove(&base);
            if length > capacity { self.free.insert(base + capacity, length - capacity); }
            base
        } else {
            let base = self.end;
            let end = base.checked_add(capacity).ok_or_else(|| io_error(std::io::Error::other("index overflow")))?;
            self.temporary.file.set_len(end).map_err(io_error)?;
            self.end = end;
            base
        };
        self.live_regions += 1;
        // Reused extents contain old hash slots and data. Every new virtual
        // region has file-like zero-filled contents before any partial writes.
        let zero = (|| {
            let buffer = [0; 8192];
            self.temporary.file.seek(SeekFrom::Start(base)).map_err(io_error)?;
            let mut remaining = capacity;
            while remaining != 0 {
                let count = remaining.min(buffer.len() as u64) as usize;
                self.temporary.file.write_all(&buffer[..count]).map_err(io_error)?;
                remaining -= count as u64;
            }
            Ok::<_, SourceError>(())
        })();
        if let Err(error) = zero { let _ = self.release(base, capacity); return Err(error); }
        Ok(base)
    }
    fn release(&mut self, mut base: u64, capacity: u64) -> Result<(), SourceError> {
        if capacity == 0 { return Ok(()); }
        self.live_regions -= 1;
        let mut end = base + capacity;
        if let Some((&left, &length)) = self.free.range(..base).next_back() {
            if left + length == base { self.free.remove(&left); base = left; }
        }
        if let Some((&right, &length)) = self.free.range(end..).next() {
            if right == end { self.free.remove(&right); end += length; }
        }
        if end == self.end {
            self.end = base;
            self.temporary.file.set_len(base).map_err(io_error)?;
        } else { self.free.insert(base, end - base); }
        Ok(())
    }
}
#[derive(Clone, Default)]
pub(crate) struct WorkspacePool(Rc<RefCell<Weak<RefCell<Store>>>>);
impl WorkspacePool {
    fn open(&self, directory: &Path) -> Result<Rc<RefCell<Store>>, SourceError> {
        if let Some(store) = self.0.borrow().upgrade() { return Ok(store); }
        let store = Rc::new(RefCell::new(Store { temporary: Temporary::new(directory)?, end: 0, free: BTreeMap::new(), live_regions: 0 }));
        *self.0.borrow_mut() = Rc::downgrade(&store);
        Ok(store)
    }
    pub(crate) fn stats(&self) -> Result<(u64, u64, u64), SourceError> {
        let Some(store) = self.0.borrow().upgrade() else { return Ok((0, 0, 0)); };
        let store = store.borrow();
        Ok((store.temporary.file.metadata().map_err(io_error)?.len(), store.live_regions, store.free.len() as u64))
    }
}
// Each active map has constant-size region descriptors. Regions grow by
// geometric relocation using one bounded stack buffer. All maps/readers of a
// source share one unlinked FD, including maps retained by parent traversal.
struct Region { store: Rc<RefCell<Store>>, base: u64, length: u64, capacity: u64 }
impl Region {
    fn new(store: Rc<RefCell<Store>>) -> Self { Self { store, base: 0, length: 0, capacity: 0 } }
    fn set_len(&mut self, length: u64) -> Result<(), SourceError> {
        if length > self.capacity {
            let capacity = length.checked_next_power_of_two().ok_or_else(|| io_error(std::io::Error::other("index overflow")))?;
            let mut store = self.store.borrow_mut();
            let base = store.allocate(capacity)?;
            let copy = (|| {
                let mut buffer = [0; 8192];
                let mut copied = 0;
                while copied < self.length {
                    let count = (self.length - copied).min(buffer.len() as u64) as usize;
                    store.temporary.file.seek(SeekFrom::Start(self.base + copied)).map_err(io_error)?;
                    store.temporary.file.read_exact(&mut buffer[..count]).map_err(io_error)?;
                    store.temporary.file.seek(SeekFrom::Start(base + copied)).map_err(io_error)?;
                    store.temporary.file.write_all(&buffer[..count]).map_err(io_error)?;
                    copied += count as u64;
                }
                Ok::<_, SourceError>(())
            })();
            if let Err(error) = copy { let _ = store.release(base, capacity); return Err(error); }
            let old = (self.base, self.capacity);
            self.base = base; self.capacity = capacity;
            store.release(old.0, old.1)?;
        }
        self.length = length;
        Ok(())
    }
}
impl Drop for Region {
    fn drop(&mut self) { let _ = self.store.borrow_mut().release(self.base, self.capacity); }
}
fn read_at(region: &mut Region, offset: u64, bytes: &mut [u8]) -> Result<(), SourceError> {
    if offset.checked_add(bytes.len() as u64).is_none_or(|end| end > region.length) {
        return Err(io_error(std::io::Error::other("invalid index read")));
    }
    let mut store = region.store.borrow_mut();
    store.temporary.file.seek(SeekFrom::Start(region.base + offset)).map_err(io_error)?;
    store.temporary.file.read_exact(bytes).map_err(io_error)
}
fn write_at(region: &mut Region, offset: u64, bytes: &[u8]) -> Result<(), SourceError> {
    let end = offset.checked_add(bytes.len() as u64).ok_or_else(|| io_error(std::io::Error::other("index overflow")))?;
    if end > region.length { region.set_len(end)?; }
    let mut store = region.store.borrow_mut();
    store.temporary.file.seek(SeekFrom::Start(region.base + offset)).map_err(io_error)?;
    store.temporary.file.write_all(bytes).map_err(io_error)
}
fn hash(key: &[u8]) -> u64 {
    let mut value = 0xcbf29ce484222325u64;
    for byte in key { value ^= *byte as u64; value = value.wrapping_mul(0x100000001b3); }
    value
}
fn pack(member: &SpanMember, fingerprint: u64) -> [u8; HEADER] {
    let fields = [member.ordinal, member.key_start, member.key_end,
        member.value.kind as u64 | ((member.value.flags as u64) << 32), member.value.raw_start,
        member.value.raw_end, member.value.child_count, member.key.len() as u64, fingerprint];
    let mut bytes = [0; HEADER];
    for (chunk, field) in bytes.chunks_exact_mut(8).zip(fields) { chunk.copy_from_slice(&field.to_le_bytes()); }
    bytes
}
fn fields(bytes: &[u8; HEADER]) -> [u64; 9] {
    let mut fields = [0; 9];
    for (field, chunk) in fields.iter_mut().zip(bytes.chunks_exact(8)) { *field = u64::from_le_bytes(chunk.try_into().unwrap()); }
    fields
}
fn member(fields: [u64; 9], key: Vec<u8>) -> SpanMember {
    let kind = match fields[3] as u32 {
        0 => leanjson_type::LEANJSON_T_NULL, 1 => leanjson_type::LEANJSON_T_BOOL,
        2 => leanjson_type::LEANJSON_T_NUM, 3 => leanjson_type::LEANJSON_T_STR,
        4 => leanjson_type::LEANJSON_T_ARR, _ => leanjson_type::LEANJSON_T_OBJ,
    };
    SpanMember { ordinal: fields[0], key_start: fields[1], key_end: fields[2], key,
        value: Span { kind, flags: (fields[3] >> 32) as u32, raw_start: fields[4], raw_end: fields[5], child_count: fields[6] } }
}
struct DiskMap { slots: Region, data: Region, capacity: u64, count: u64, end: u64, cursor: u64 }
impl DiskMap {
    fn new(directory: &Path, pool: &WorkspacePool) -> Result<Self, SourceError> {
        let store = pool.open(directory)?;
        let mut slots = Region::new(store.clone());
        slots.set_len(16 * 16)?;
        Ok(Self { slots, data: Region::new(store), capacity: 16, count: 0, end: 0, cursor: 0 })
    }
    fn slot(file: &mut Region, slot: u64) -> Result<(u64, u64), SourceError> {
        let mut bytes = [0; 16]; read_at(file, slot * 16, &mut bytes)?;
        Ok((u64::from_le_bytes(bytes[..8].try_into().unwrap()), u64::from_le_bytes(bytes[8..].try_into().unwrap())))
    }
    fn put_slot(file: &mut Region, slot: u64, hash: u64, offset: u64) -> Result<(), SourceError> {
        let mut bytes = [0; 16]; bytes[..8].copy_from_slice(&hash.to_le_bytes()); bytes[8..].copy_from_slice(&offset.to_le_bytes());
        write_at(file, slot * 16, &bytes)
    }
    fn grow(&mut self) -> Result<(), SourceError> {
        let mut next = Region::new(self.slots.store.clone());
        let capacity = self.capacity.checked_mul(2).ok_or_else(|| io_error(std::io::Error::other("index overflow")))?;
        next.set_len(capacity.checked_mul(16).ok_or_else(|| io_error(std::io::Error::other("index overflow")))?)?;
        for i in 0..self.capacity {
            let (hash, offset) = Self::slot(&mut self.slots, i)?;
            if offset == 0 { continue; }
            let mut slot = hash & (capacity - 1);
            while Self::slot(&mut next, slot)?.1 != 0 { slot = (slot + 1) & (capacity - 1); }
            Self::put_slot(&mut next, slot, hash, offset)?;
        }
        self.slots = next; self.capacity = capacity; Ok(())
    }
    fn key_equals(&mut self, offset: u64, key: &[u8]) -> Result<bool, SourceError> {
        let mut buffer = [0; 4096];
        for (i, chunk) in key.chunks(buffer.len()).enumerate() {
            read_at(&mut self.data, offset + (i * buffer.len()) as u64, &mut buffer[..chunk.len()])?;
            if &buffer[..chunk.len()] != chunk { return Ok(false); }
        }
        Ok(true)
    }
    fn insert(&mut self, entry: SpanMember) -> Result<bool, SourceError> {
        if self.count >= self.capacity * 3 / 4 { self.grow()?; }
        let fingerprint = hash(&entry.key);
        let mut slot = fingerprint & (self.capacity - 1);
        loop {
            let (candidate_hash, location) = Self::slot(&mut self.slots, slot)?;
            if location == 0 {
                let header = pack(&entry, fingerprint);
                write_at(&mut self.data, self.end, &header)?;
                write_at(&mut self.data, self.end + HEADER as u64, &entry.key)?;
                Self::put_slot(&mut self.slots, slot, fingerprint, self.end + 1)?;
                self.end += HEADER as u64 + entry.key.len() as u64;
                self.count += 1; return Ok(false);
            }
            if candidate_hash == fingerprint {
                let offset = location - 1;
                let mut bytes = [0; HEADER]; read_at(&mut self.data, offset, &mut bytes)?;
                let old = fields(&bytes);
                if old[7] == entry.key.len() as u64 && self.key_equals(offset + HEADER as u64, &entry.key)? {
                    let mut replacement = entry;
                    replacement.ordinal = old[0]; replacement.key_start = old[1]; replacement.key_end = old[2];
                    write_at(&mut self.data, offset, &pack(&replacement, fingerprint))?;
                    return Ok(true);
                }
            }
            slot = (slot + 1) & (self.capacity - 1);
        }
    }
    fn next(&mut self) -> Result<Option<SpanMember>, SourceError> {
        if self.cursor == self.end { return Ok(None); }
        let mut bytes = [0; HEADER]; read_at(&mut self.data, self.cursor, &mut bytes)?;
        let fields = fields(&bytes);
        let length = usize::try_from(fields[7]).map_err(|_| io_error(std::io::Error::other("key overflow")))?;
        let mut key = vec![0; length]; read_at(&mut self.data, self.cursor + HEADER as u64, &mut key)?;
        self.cursor += HEADER as u64 + fields[7];
        Ok(Some(member(fields, key)))
    }
}

pub(crate) struct KeyMap {
    small: Vec<SpanMember>, bytes: usize, disk: Option<DiskMap>, directory: PathBuf, pool: WorkspacePool,
    duplicates: bool, cursor: usize,
}
impl KeyMap {
    pub(crate) fn new(directory: PathBuf, pool: WorkspacePool) -> Self {
        Self { small: Vec::new(), bytes: 0, disk: None, directory, pool, duplicates: false, cursor: 0 }
    }
    pub(crate) fn had_duplicates(&self) -> bool { self.duplicates }
    pub(crate) fn insert_key(&mut self, key: &[u8]) -> Result<(), SourceError> {
        self.insert(SpanMember { ordinal: 0, key_start: 0, key_end: 0, key: key.to_vec(),
            value: Span { kind: leanjson_type::LEANJSON_T_NULL, flags: 1, raw_start: 0, raw_end: 0, child_count: 0 } })
    }
    pub(crate) fn insert(&mut self, entry: SpanMember) -> Result<(), SourceError> {
        if let Some(disk) = self.disk.as_mut() { self.duplicates |= disk.insert(entry)?; return Ok(()); }
        if let Some(old) = self.small.iter_mut().find(|old| old.key == entry.key) {
            old.value = entry.value; self.duplicates = true; return Ok(());
        }
        if self.small.len() < SMALL_KEYS && self.bytes + entry.key.len() <= SMALL_BYTES {
            self.bytes += entry.key.len(); self.small.push(entry); return Ok(());
        }
        let mut disk = DiskMap::new(&self.directory, &self.pool)?;
        for old in self.small.drain(..) { disk.insert(old)?; }
        self.small = Vec::new(); self.bytes = 0;
        disk.insert(entry)?; self.disk = Some(disk); Ok(())
    }
    pub(crate) fn next(&mut self) -> Result<Option<SpanMember>, SourceError> {
        if let Some(disk) = self.disk.as_mut() { return disk.next(); }
        if self.cursor >= self.small.len() { return Ok(None); }
        let old = &mut self.small[self.cursor]; self.cursor += 1;
        Ok(Some(SpanMember { ordinal: old.ordinal, key_start: old.key_start, key_end: old.key_end,
            key: std::mem::take(&mut old.key), value: old.value }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn entry(key: &[u8], start: u64) -> SpanMember {
        SpanMember { ordinal: start, key_start: 0, key_end: 0, key: key.to_vec(),
            value: Span { kind: leanjson_type::LEANJSON_T_NUM, flags: 1, raw_start: start, raw_end: start + 1, child_count: 0 } }
    }
    #[test]
    fn fingerprint_collision_still_compares_full_decoded_keys() {
        let pool = WorkspacePool::default();
        let mut map = DiskMap::new(&std::env::temp_dir(), &pool).unwrap();
        map.insert(entry(b"alpha", 1)).unwrap();
        // Give the existing slot the next key's fingerprint, simulating a
        // collision without relying on finding an accidental 64-bit collision.
        let old_slot = hash(b"alpha") & (map.capacity - 1);
        let old_location = DiskMap::slot(&mut map.slots, old_slot).unwrap().1;
        DiskMap::put_slot(&mut map.slots, old_slot, 0, 0).unwrap();
        let collision = hash(b"bravo");
        DiskMap::put_slot(&mut map.slots, collision & (map.capacity - 1), collision, old_location).unwrap();
        assert!(!map.insert(entry(b"bravo", 2)).unwrap());
        assert!(map.insert(entry(b"bravo", 3)).unwrap());
        let first = map.next().unwrap().unwrap();
        let second = map.next().unwrap().unwrap();
        assert_eq!((first.key.as_slice(), first.value.raw_start), (b"alpha".as_slice(), 1));
        assert_eq!((second.key.as_slice(), second.value.raw_start), (b"bravo".as_slice(), 3));
        assert!(map.next().unwrap().is_none());
    }
    #[test]
    fn held_workspace_does_not_accumulate_historical_traversal_regions() {
        let pool = WorkspacePool::default();
        let mut held = DiskMap::new(&std::env::temp_dir(), &pool).unwrap();
        for i in 0..256 { held.insert(entry(format!("held-{i}").as_bytes(), i)).unwrap(); }
        let store = held.slots.store.clone();
        let mut warm_bytes = 0;
        for pass in 0..24 {
            let mut temporary = DiskMap::new(&std::env::temp_dir(), &pool).unwrap();
            for i in 0..128 { temporary.insert(entry(format!("temporary-{i}").as_bytes(), i)).unwrap(); }
            drop(temporary);
            let bytes = store.borrow().end;
            if pass == 0 { warm_bytes = bytes; }
            assert!(bytes <= warm_bytes * 2, "held map accumulated historical regions: {bytes} > {}", warm_bytes * 2);
        }
        assert_eq!(held.next().unwrap().unwrap().key, b"held-0");
        drop(held);
        let store = store.borrow();
        assert_eq!(store.end, 0);
        assert_eq!(store.temporary.file.metadata().unwrap().len(), 0);
        assert_eq!(store.live_regions, 0);
        assert!(store.free.is_empty());
    }

}
