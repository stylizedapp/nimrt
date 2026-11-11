// benchmarks/rust_full_suite.rs — Честный симметричный бенчмарк Rust против Nim (CoreX + AlgX)
//
// Все 4 дисциплины полностью выровнены по алгоритмам, числу потоков, структурам данных и размерам буферов:
// 1. Сортировка 10M i64: 4-поточный 3-Level Cache-Aware Hybrid MSD Radix + L1 Unguarded Insertion Sort.
// 2. Хэш-таблица (3M ops):
//    2a) std::collections::HashMap (hashbrown) с быстрым SplitMix64Hasher (емкость 2^21 слотов).
//    2b) Прямой порт плоской таблицы FastMap (ctrl + keys + vals, 2^21 слотов) на Rust.
// 3. Блочная POD-сериализация 2M структур VoxelPacket (sizeof=32, 64 МБ) через copy_nonoverlapping без зануления.
// 4. Векторная аналитика 25M i64: 8-аккумуляторная развёртка (chunks_exact(8)) + безветвевой фильтр.

use std::collections::HashMap;
use std::hash::{BuildHasherDefault, Hasher};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Barrier;
use std::thread;
use std::time::Instant;

const WARMUP_RUNS: usize = 2;
const BENCH_RUNS: usize = 11;
const SEED: u64 = 0xDEAD_BEEF_CAFE_1234;

struct XorShift64 {
    state: u64,
}

impl XorShift64 {
    #[inline(always)]
    fn new(seed: u64) -> Self {
        Self {
            state: if seed == 0 { 0x5458_1234_CAFE_BEEF } else { seed },
        }
    }

    #[inline(always)]
    fn next_i64(&mut self) -> i64 {
        let mut x = self.state;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.state = x;
        x as i64
    }
}

fn print_stats(label: &str, samples: &mut [f64], extra: &str) {
    samples.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let min_val = samples[0];
    let med_val = samples[samples.len() / 2];
    let max_val = samples[samples.len() - 1];
    let mean_val: f64 = samples.iter().sum::<f64>() / (samples.len() as f64);
    println!(
        "{:<40} | min: {:>6.2} ms | med: {:>6.2} ms | mean: {:>6.2} ms | max: {:>6.2} ms | {}",
        label, min_val, med_val, mean_val, max_val, extra
    );
}

// =============================================================================
// Дисциплина 1: 4-поточный 3-Level Hybrid MSD Radix + L1 Insertion Sort
// =============================================================================

const NUM_THREADS: usize = 4;
const R1: usize = 256;
const SHIFT1: u32 = 56;
const R3: usize = 128;
const SHIFT3: u32 = 41;

#[inline(always)]
unsafe fn guarded_insertion_sort(data: *mut i64, start: usize, end: usize) {
    for i in (start + 1)..end {
        let key = *data.add(i);
        let mut j = i;
        while j > start {
            let prev = *data.add(j - 1);
            if prev <= key {
                break;
            }
            *data.add(j) = prev;
            j -= 1;
        }
        *data.add(j) = key;
    }
}

#[inline(always)]
unsafe fn unguarded_insertion_sort(data: *mut i64, start: usize, end: usize) {
    for i in start..end {
        let key = *data.add(i);
        let mut j = i;
        let mut prev = *data.add(j - 1);
        if prev > key {
            loop {
                *data.add(j) = prev;
                j -= 1;
                prev = *data.add(j - 1);
                if prev <= key {
                    break;
                }
            }
            *data.add(j) = key;
        }
    }
}

unsafe fn sort_bucket_3level(
    aux: *const i64,
    data: *mut i64,
    l2_buf: *mut i64,
    start: usize,
    end: usize,
) {
    let len = end - start;
    if len <= 1 {
        if len == 1 {
            *data.add(start) = *aux.add(start);
        }
        return;
    }
    if len <= 64 {
        std::ptr::copy_nonoverlapping(aux.add(start), data.add(start), len);
        guarded_insertion_sort(data, start, end);
        return;
    }

    let mut count2 = [0u32; 256];
    let end4 = start + (len & !3);
    let mut i = start;
    while i < end4 {
        let b0 = ((*aux.add(i) as u64 >> 48) & 0xFF) as usize;
        let b1 = ((*aux.add(i + 1) as u64 >> 48) & 0xFF) as usize;
        let b2 = ((*aux.add(i + 2) as u64 >> 48) & 0xFF) as usize;
        let b3 = ((*aux.add(i + 3) as u64 >> 48) & 0xFF) as usize;
        *count2.get_unchecked_mut(b0) += 1;
        *count2.get_unchecked_mut(b1) += 1;
        *count2.get_unchecked_mut(b2) += 1;
        *count2.get_unchecked_mut(b3) += 1;
        i += 4;
    }
    while i < end {
        let b = ((*aux.add(i) as u64 >> 48) & 0xFF) as usize;
        *count2.get_unchecked_mut(b) += 1;
        i += 1;
    }

    let mut offsets2 = [0u32; 256];
    let mut sum2 = 0u32;
    for b in 0..256 {
        *offsets2.get_unchecked_mut(b) = sum2;
        sum2 += *count2.get_unchecked(b);
    }

    let mut i = start;
    while i < end4 {
        let v0 = *aux.add(i);
        let b0 = ((v0 as u64 >> 48) & 0xFF) as usize;
        let pos0 = *offsets2.get_unchecked(b0) as usize;
        *l2_buf.add(pos0) = v0;
        *offsets2.get_unchecked_mut(b0) = (pos0 + 1) as u32;

        let v1 = *aux.add(i + 1);
        let b1 = ((v1 as u64 >> 48) & 0xFF) as usize;
        let pos1 = *offsets2.get_unchecked(b1) as usize;
        *l2_buf.add(pos1) = v1;
        *offsets2.get_unchecked_mut(b1) = (pos1 + 1) as u32;

        let v2 = *aux.add(i + 2);
        let b2 = ((v2 as u64 >> 48) & 0xFF) as usize;
        let pos2 = *offsets2.get_unchecked(b2) as usize;
        *l2_buf.add(pos2) = v2;
        *offsets2.get_unchecked_mut(b2) = (pos2 + 1) as u32;

        let v3 = *aux.add(i + 3);
        let b3 = ((v3 as u64 >> 48) & 0xFF) as usize;
        let pos3 = *offsets2.get_unchecked(b3) as usize;
        *l2_buf.add(pos3) = v3;
        *offsets2.get_unchecked_mut(b3) = (pos3 + 1) as u32;

        i += 4;
    }
    while i < end {
        let v = *aux.add(i);
        let b = ((v as u64 >> 48) & 0xFF) as usize;
        let pos = *offsets2.get_unchecked(b) as usize;
        *l2_buf.add(pos) = v;
        *offsets2.get_unchecked_mut(b) = (pos + 1) as u32;
        i += 1;
    }

    let mask3 = (R3 - 1) as u64;
    let mut sub_start = 0usize;
    let mut has_first = false;
    for b2 in 0..256 {
        let sub_len = *count2.get_unchecked(b2) as usize;
        if sub_len == 0 {
            continue;
        }
        let dst_start = start + sub_start;
        let dst_end = dst_start + sub_len;
        let sub_end = sub_start + sub_len;

        if sub_len <= 32 {
            std::ptr::copy_nonoverlapping(l2_buf.add(sub_start), data.add(dst_start), sub_len);
            if !has_first {
                guarded_insertion_sort(data, dst_start, dst_end);
                has_first = true;
            } else {
                unguarded_insertion_sort(data, dst_start, dst_end);
            }
        } else {
            let mut offsets3 = [0u16; R3];
            let s_end4 = sub_start + (sub_len & !3);
            let mut j = sub_start;
            while j < s_end4 {
                let c0 = ((*l2_buf.add(j) as u64 >> SHIFT3) & mask3) as usize;
                let c1 = ((*l2_buf.add(j + 1) as u64 >> SHIFT3) & mask3) as usize;
                let c2 = ((*l2_buf.add(j + 2) as u64 >> SHIFT3) & mask3) as usize;
                let c3 = ((*l2_buf.add(j + 3) as u64 >> SHIFT3) & mask3) as usize;
                *offsets3.get_unchecked_mut(c0) += 1;
                *offsets3.get_unchecked_mut(c1) += 1;
                *offsets3.get_unchecked_mut(c2) += 1;
                *offsets3.get_unchecked_mut(c3) += 1;
                j += 4;
            }
            while j < sub_end {
                let c = ((*l2_buf.add(j) as u64 >> SHIFT3) & mask3) as usize;
                *offsets3.get_unchecked_mut(c) += 1;
                j += 1;
            }

            let mut sum3 = 0u16;
            let mut max_m = 0u16;
            let mut first_m_len = 0usize;
            for m in 0..R3 {
                let c = *offsets3.get_unchecked(m);
                *offsets3.get_unchecked_mut(m) = sum3;
                if first_m_len == 0 && c > 0 {
                    first_m_len = c as usize;
                }
                if c > max_m {
                    max_m = c;
                }
                sum3 += c;
            }

            let dst_ptr = data.add(dst_start);
            let mut j = sub_start;
            while j < s_end4 {
                let v0 = *l2_buf.add(j);
                let c0 = ((v0 as u64 >> SHIFT3) & mask3) as usize;
                let p0 = *offsets3.get_unchecked(c0) as usize;
                *dst_ptr.add(p0) = v0;
                *offsets3.get_unchecked_mut(c0) = (p0 + 1) as u16;

                let v1 = *l2_buf.add(j + 1);
                let c1 = ((v1 as u64 >> SHIFT3) & mask3) as usize;
                let p1 = *offsets3.get_unchecked(c1) as usize;
                *dst_ptr.add(p1) = v1;
                *offsets3.get_unchecked_mut(c1) = (p1 + 1) as u16;

                let v2 = *l2_buf.add(j + 2);
                let c2 = ((v2 as u64 >> SHIFT3) & mask3) as usize;
                let p2 = *offsets3.get_unchecked(c2) as usize;
                *dst_ptr.add(p2) = v2;
                *offsets3.get_unchecked_mut(c2) = (p2 + 1) as u16;

                let v3 = *l2_buf.add(j + 3);
                let c3 = ((v3 as u64 >> SHIFT3) & mask3) as usize;
                let p3 = *offsets3.get_unchecked(c3) as usize;
                *dst_ptr.add(p3) = v3;
                *offsets3.get_unchecked_mut(c3) = (p3 + 1) as u16;

                j += 4;
            }
            while j < sub_end {
                let v = *l2_buf.add(j);
                let c = ((v as u64 >> SHIFT3) & mask3) as usize;
                let p = *offsets3.get_unchecked(c) as usize;
                *dst_ptr.add(p) = v;
                *offsets3.get_unchecked_mut(c) = (p + 1) as u16;
                j += 1;
            }

            if max_m > 64 {
                std::slice::from_raw_parts_mut(dst_ptr, sub_len).sort_unstable();
                has_first = true;
            } else if !has_first {
                guarded_insertion_sort(data, dst_start, dst_start + first_m_len);
                unguarded_insertion_sort(data, dst_start + first_m_len, dst_end);
                has_first = true;
            } else {
                unguarded_insertion_sort(data, dst_start, dst_end);
            }
        }

        sub_start = sub_end;
    }
}

fn ultra_sort_rust(data: &mut [i64], aux: &mut [i64]) -> f64 {
    let n = data.len();
    let sign_flip = 1usize << (63 - SHIFT1);
    let chunk_size = (n + NUM_THREADS - 1) / NUM_THREADS;
    let mut hists = [[0usize; R1]; NUM_THREADS];
    let mut thread_offsets = [[0usize; R1]; NUM_THREADS];
    let mut bucket_starts = [0usize; R1];
    let mut bucket_ends = [0usize; R1];
    let next_bucket = AtomicUsize::new(0);
    let barrier = Barrier::new(NUM_THREADS);
    let mut elapsed_ms = 0.0f64;

    let data_addr = data.as_mut_ptr() as usize;
    let aux_addr = aux.as_mut_ptr() as usize;
    let hists_addr = hists.as_mut_ptr() as usize;
    let offsets_addr = thread_offsets.as_mut_ptr() as usize;
    let starts_addr = bucket_starts.as_mut_ptr() as usize;
    let ends_addr = bucket_ends.as_mut_ptr() as usize;
    let elapsed_addr = &mut elapsed_ms as *mut f64 as usize;

    thread::scope(|s| {
        for t in 0..NUM_THREADS {
            let barrier_ref = &barrier;
            let next_bucket_ref = &next_bucket;
            s.spawn(move || unsafe {
                let data_ptr = data_addr as *mut i64;
                let aux_ptr = aux_addr as *mut i64;
                let hists_ptr = hists_addr as *mut [usize; R1];
                let offsets_ptr = offsets_addr as *mut [usize; R1];
                let starts_ptr = starts_addr as *mut usize;
                let ends_ptr = ends_addr as *mut usize;

                let s_idx = t * chunk_size;
                let e_idx = (s_idx + chunk_size).min(n);
                let len = e_idx.saturating_sub(s_idx);

                let mut l2_buf = vec![1i64; 65_536];
                let l2_ptr = l2_buf.as_mut_ptr();

                barrier_ref.wait();
                let t0 = Instant::now();

                let my_hist = &mut *hists_ptr.add(t);
                let end4 = s_idx + (len & !3);
                let mut i = s_idx;
                while i < end4 {
                    let b0 = ((*data_ptr.add(i) as u64 >> SHIFT1) as usize) ^ sign_flip;
                    let b1 = ((*data_ptr.add(i + 1) as u64 >> SHIFT1) as usize) ^ sign_flip;
                    let b2 = ((*data_ptr.add(i + 2) as u64 >> SHIFT1) as usize) ^ sign_flip;
                    let b3 = ((*data_ptr.add(i + 3) as u64 >> SHIFT1) as usize) ^ sign_flip;
                    *my_hist.get_unchecked_mut(b0) += 1;
                    *my_hist.get_unchecked_mut(b1) += 1;
                    *my_hist.get_unchecked_mut(b2) += 1;
                    *my_hist.get_unchecked_mut(b3) += 1;
                    i += 4;
                }
                while i < e_idx {
                    let b = ((*data_ptr.add(i) as u64 >> SHIFT1) as usize) ^ sign_flip;
                    *my_hist.get_unchecked_mut(b) += 1;
                    i += 1;
                }

                barrier_ref.wait();

                if t == 0 {
                    let mut cur = 0usize;
                    for b in 0..R1 {
                        *starts_ptr.add(b) = cur;
                        for th in 0..NUM_THREADS {
                            (*offsets_ptr.add(th))[b] = cur;
                            cur += (*hists_ptr.add(th))[b];
                        }
                        *ends_ptr.add(b) = cur;
                    }
                }

                barrier_ref.wait();

                let mut local_offsets = *offsets_ptr.add(t);
                let mut i = s_idx;
                while i < end4 {
                    let v0 = *data_ptr.add(i);
                    let b0 = ((v0 as u64 >> SHIFT1) as usize) ^ sign_flip;
                    let pos0 = *local_offsets.get_unchecked(b0);
                    *aux_ptr.add(pos0) = v0;
                    *local_offsets.get_unchecked_mut(b0) = pos0 + 1;

                    let v1 = *data_ptr.add(i + 1);
                    let b1 = ((v1 as u64 >> SHIFT1) as usize) ^ sign_flip;
                    let pos1 = *local_offsets.get_unchecked(b1);
                    *aux_ptr.add(pos1) = v1;
                    *local_offsets.get_unchecked_mut(b1) = pos1 + 1;

                    let v2 = *data_ptr.add(i + 2);
                    let b2 = ((v2 as u64 >> SHIFT1) as usize) ^ sign_flip;
                    let pos2 = *local_offsets.get_unchecked(b2);
                    *aux_ptr.add(pos2) = v2;
                    *local_offsets.get_unchecked_mut(b2) = pos2 + 1;

                    let v3 = *data_ptr.add(i + 3);
                    let b3 = ((v3 as u64 >> SHIFT1) as usize) ^ sign_flip;
                    let pos3 = *local_offsets.get_unchecked(b3);
                    *aux_ptr.add(pos3) = v3;
                    *local_offsets.get_unchecked_mut(b3) = pos3 + 1;

                    i += 4;
                }
                while i < e_idx {
                    let v = *data_ptr.add(i);
                    let b = ((v as u64 >> SHIFT1) as usize) ^ sign_flip;
                    let pos = *local_offsets.get_unchecked(b);
                    *aux_ptr.add(pos) = v;
                    *local_offsets.get_unchecked_mut(b) = pos + 1;
                    i += 1;
                }

                barrier_ref.wait();

                loop {
                    let b = next_bucket_ref.fetch_add(1, Ordering::Relaxed);
                    if b >= R1 {
                        break;
                    }
                    let b_start = *starts_ptr.add(b);
                    let b_end = *ends_ptr.add(b);
                    sort_bucket_3level(aux_ptr, data_ptr, l2_ptr, b_start, b_end);
                }

                barrier_ref.wait();
                if t == 0 {
                    *(elapsed_addr as *mut f64) = t0.elapsed().as_secs_f64() * 1000.0;
                }
            });
        }
    });

    elapsed_ms
}

// =============================================================================
// Дисциплина 2: SplitMix64Hasher для std::HashMap + Симметричный RustFastMap
// =============================================================================

#[inline(always)]
fn splitmix64(x: u64) -> u64 {
    let mut z = x;
    z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
    z ^ (z >> 31)
}

#[derive(Default)]
struct SplitMix64Hasher {
    hash: u64,
}

impl Hasher for SplitMix64Hasher {
    #[inline(always)]
    fn write(&mut self, bytes: &[u8]) {
        let mut v = 0u64;
        unsafe {
            std::ptr::copy_nonoverlapping(bytes.as_ptr(), &mut v as *mut u64 as *mut u8, bytes.len().min(8));
        }
        self.hash = splitmix64(v);
    }
    #[inline(always)]
    fn write_i64(&mut self, i: i64) {
        self.hash = splitmix64(i as u64);
    }
    #[inline(always)]
    fn write_u64(&mut self, i: u64) {
        self.hash = splitmix64(i);
    }
    #[inline(always)]
    fn finish(&self) -> u64 {
        self.hash
    }
}

struct RustFastMap {
    ctrl: Vec<u8>,
    keys: Vec<i64>,
    vals: Vec<i64>,
    mask: usize,
    count: usize,
    used_slots: usize,
}

impl RustFastMap {
    fn with_capacity(initial_cap: usize) -> Self {
        let needed = (initial_cap * 4 + 2) / 3;
        let cap = needed.max(16).next_power_of_two();
        Self {
            ctrl: vec![0u8; cap],
            keys: vec![0i64; cap],
            vals: vec![0i64; cap],
            mask: cap - 1,
            count: 0,
            used_slots: 0,
        }
    }

    #[inline(always)]
    fn clear(&mut self) {
        self.ctrl.fill(0);
        self.count = 0;
        self.used_slots = 0;
    }

    #[inline(always)]
    fn extract_tag(h: u64) -> u8 {
        let raw = (h >> 56) as u8;
        if raw < 2 { raw + 2 } else { raw }
    }

    #[inline(always)]
    fn put(&mut self, key: i64, val: i64) {
        let h = splitmix64(key as u64);
        let tag = Self::extract_tag(h);
        let mask = self.mask;
        let mut idx = (h as usize) & mask;
        unsafe {
            let p_ctrl = self.ctrl.as_mut_ptr();
            let p_keys = self.keys.as_mut_ptr();
            let p_vals = self.vals.as_mut_ptr();
            loop {
                let c = *p_ctrl.add(idx);
                if c == 0 {
                    *p_ctrl.add(idx) = tag;
                    *p_keys.add(idx) = key;
                    *p_vals.add(idx) = val;
                    self.used_slots += 1;
                    self.count += 1;
                    return;
                } else if c == tag && *p_keys.add(idx) == key {
                    *p_vals.add(idx) = val;
                    return;
                }
                idx = (idx + 1) & mask;
            }
        }
    }

    #[inline(always)]
    fn get_or_default(&self, key: i64, default_val: i64) -> i64 {
        let h = splitmix64(key as u64);
        let tag = Self::extract_tag(h);
        let mask = self.mask;
        let mut idx = (h as usize) & mask;
        unsafe {
            let p_ctrl = self.ctrl.as_ptr();
            let p_keys = self.keys.as_ptr();
            let p_vals = self.vals.as_ptr();
            loop {
                let c = *p_ctrl.add(idx);
                if c == tag && *p_keys.add(idx) == key {
                    return *p_vals.add(idx);
                } else if c == 0 {
                    return default_val;
                }
                idx = (idx + 1) & mask;
            }
        }
    }
}

// =============================================================================
// Дисциплина 3: Блочная POD-сериализация VoxelPacket (sizeof = 32)
// =============================================================================

#[repr(C)]
#[derive(Clone, Copy)]
struct VoxelPacket {
    entity_id: i64,
    chunk_x: i32,
    chunk_y: i32,
    chunk_z: i32,
    health: f32,
    flags: u32,
    pad: u32,
}

fn pack_bin_pod(packets: &[VoxelPacket]) -> Vec<u8> {
    let n = packets.len() as i32;
    let payload_bytes = packets.len() * std::mem::size_of::<VoxelPacket>();
    let total_bytes = 4 + payload_bytes;
    let mut buf: Vec<u8> = Vec::with_capacity(total_bytes);
    unsafe {
        std::ptr::copy_nonoverlapping(&n as *const i32 as *const u8, buf.as_mut_ptr(), 4);
        std::ptr::copy_nonoverlapping(
            packets.as_ptr() as *const u8,
            buf.as_mut_ptr().add(4),
            payload_bytes,
        );
        buf.set_len(total_bytes);
    }
    buf
}

fn unpack_bin_pod(buf: &[u8]) -> Vec<VoxelPacket> {
    let mut n: i32 = 0;
    unsafe {
        std::ptr::copy_nonoverlapping(buf.as_ptr(), &mut n as *mut i32 as *mut u8, 4);
        let count = n as usize;
        let mut out: Vec<VoxelPacket> = Vec::with_capacity(count);
        std::ptr::copy_nonoverlapping(
            buf.as_ptr().add(4),
            out.as_mut_ptr() as *mut u8,
            count * std::mem::size_of::<VoxelPacket>(),
        );
        out.set_len(count);
        out
    }
}

fn hash_bytes_sample(buf: &[u8]) -> u64 {
    let mut h = 0xCBF2_9CE4_8422_2325u64;
    let mut i = 0usize;
    let n = buf.len();
    while i < n {
        h = (h ^ (buf[i] as u64)).wrapping_mul(0x0000_0100_0000_01B3);
        i += 4096;
    }
    h = (h ^ (buf[n - 1] as u64)).wrapping_mul(0x0000_0100_0000_01B3);
    h
}

// =============================================================================
// Дисциплина 4: 8-аккумуляторная развёртка (DotProduct + Branchless Filter)
// =============================================================================

#[inline(never)]
fn fast_dot_product_rust(a: &[i64], b: &[i64]) -> i64 {
    let n = a.len().min(b.len());
    let mut d0 = 0i64;
    let mut d1 = 0i64;
    let mut d2 = 0i64;
    let mut d3 = 0i64;
    let mut d4 = 0i64;
    let mut d5 = 0i64;
    let mut d6 = 0i64;
    let mut d7 = 0i64;
    let limit8 = n & !7;
    let mut i = 0;
    unsafe {
        let pa = a.as_ptr();
        let pb = b.as_ptr();
        while i < limit8 {
            d0 = d0.wrapping_add((*pa.add(i)).wrapping_mul(*pb.add(i)));
            d1 = d1.wrapping_add((*pa.add(i + 1)).wrapping_mul(*pb.add(i + 1)));
            d2 = d2.wrapping_add((*pa.add(i + 2)).wrapping_mul(*pb.add(i + 2)));
            d3 = d3.wrapping_add((*pa.add(i + 3)).wrapping_mul(*pb.add(i + 3)));
            d4 = d4.wrapping_add((*pa.add(i + 4)).wrapping_mul(*pb.add(i + 4)));
            d5 = d5.wrapping_add((*pa.add(i + 5)).wrapping_mul(*pb.add(i + 5)));
            d6 = d6.wrapping_add((*pa.add(i + 6)).wrapping_mul(*pb.add(i + 6)));
            d7 = d7.wrapping_add((*pa.add(i + 7)).wrapping_mul(*pb.add(i + 7)));
            i += 8;
        }
        let mut total = d0
            .wrapping_add(d1)
            .wrapping_add(d2.wrapping_add(d3))
            .wrapping_add(d4.wrapping_add(d5))
            .wrapping_add(d6.wrapping_add(d7));
        while i < n {
            total = total.wrapping_add((*pa.add(i)).wrapping_mul(*pb.add(i)));
            i += 1;
        }
        total
    }
}

#[inline(never)]
fn fast_count_greater_rust(arr: &[i64], threshold: i64) -> usize {
    let n = arr.len();
    let mut c0 = 0usize;
    let mut c1 = 0usize;
    let mut c2 = 0usize;
    let mut c3 = 0usize;
    let mut c4 = 0usize;
    let mut c5 = 0usize;
    let mut c6 = 0usize;
    let mut c7 = 0usize;
    let limit8 = n & !7;
    let mut i = 0;
    unsafe {
        let p = arr.as_ptr();
        while i < limit8 {
            c0 += (*p.add(i) > threshold) as usize;
            c1 += (*p.add(i + 1) > threshold) as usize;
            c2 += (*p.add(i + 2) > threshold) as usize;
            c3 += (*p.add(i + 3) > threshold) as usize;
            c4 += (*p.add(i + 4) > threshold) as usize;
            c5 += (*p.add(i + 5) > threshold) as usize;
            c6 += (*p.add(i + 6) > threshold) as usize;
            c7 += (*p.add(i + 7) > threshold) as usize;
            i += 8;
        }
        let mut total = (c0 + c1) + (c2 + c3) + (c4 + c5) + (c6 + c7);
        while i < n {
            total += (*p.add(i) > threshold) as usize;
            i += 1;
        }
        total
    }
}

fn main() {
    println!("======================================================================================================================");
    println!("   RUST 1.96.0 (LTO=FAT, NATIVE) — SYMMETRIC BENCHMARK SUITE (Warmup: 2, Measured Runs: 11)                           ");
    println!("======================================================================================================================");

    // ---------------------------------------------------------------------------
    // 1. Сортировка 10 000 000 i64 (4T, 3-Level Hybrid MSD Radix + L1 Insertion)
    // ---------------------------------------------------------------------------
    {
        const N: usize = 10_000_000;
        let mut master = Vec::with_capacity(N);
        let mut rng = XorShift64::new(SEED);
        for _ in 0..N {
            master.push(rng.next_i64());
        }

        let mut data = vec![0i64; N];
        let mut aux = vec![1i64; N];
        let mut samples = Vec::with_capacity(BENCH_RUNS);

        for run in 0..(WARMUP_RUNS + BENCH_RUNS) {
            data.copy_from_slice(&master);
            let ms = ultra_sort_rust(&mut data, &mut aux);
            if run >= WARMUP_RUNS {
                samples.push(ms);
            }
        }
        print_stats(
            "[1] UltraSort (10M i64, 4T)",
            &mut samples,
            &format!("min={}, max={}", data[0], data[N - 1]),
        );
    }

    // ---------------------------------------------------------------------------
    // 2a. std::collections::HashMap (hashbrown) + SplitMix64Hasher (3M ops)
    // ---------------------------------------------------------------------------
    {
        const M: usize = 1_000_000;
        let mut keys = Vec::with_capacity(M);
        let mut rng = XorShift64::new(SEED);
        for _ in 0..M {
            keys.push(rng.next_i64());
        }

        let mut mp: HashMap<i64, i64, BuildHasherDefault<SplitMix64Hasher>> =
            HashMap::with_capacity_and_hasher(M, BuildHasherDefault::default());
        let cap_usable = mp.capacity();
        // В hashbrown usable capacity = 7/8 от числа бакетов (2^21 * 7/8 = 1_835_008 -> 2_097_152 слота)
        let raw_slots = (cap_usable * 8) / 7;
        let mut check_sum = 0i64;
        let mut samples = Vec::with_capacity(BENCH_RUNS);

        for run in 0..(WARMUP_RUNS + BENCH_RUNS) {
            mp.clear();
            let t0 = Instant::now();
            for (i, &k) in keys.iter().enumerate() {
                mp.insert(k, i as i64);
            }
            let mut cs = 0i64;
            for &k in &keys {
                cs += *mp.get(&k).unwrap_or(&-1);
                cs += *mp.get(&(k ^ 0x5555_5555_5555_5555)).unwrap_or(&0);
            }
            let ms = t0.elapsed().as_secs_f64() * 1000.0;
            check_sum = cs;
            if run >= WARMUP_RUNS {
                samples.push(ms);
            }
        }
        print_stats(
            "[2a] std::HashMap + SplitMix64 (3M ops)",
            &mut samples,
            &format!("slots={} (cap={}), sum={}", raw_slots, cap_usable, check_sum),
        );
    }

    // ---------------------------------------------------------------------------
    // 2b. Симметричный RustFastMap (ctrl + keys + vals) + SplitMix64 (3M ops)
    // ---------------------------------------------------------------------------
    {
        const M: usize = 1_000_000;
        let mut keys = Vec::with_capacity(M);
        let mut rng = XorShift64::new(SEED);
        for _ in 0..M {
            keys.push(rng.next_i64());
        }

        let mut mp = RustFastMap::with_capacity(M);
        let slots = mp.ctrl.len();
        let mut check_sum = 0i64;
        let mut samples = Vec::with_capacity(BENCH_RUNS);

        for run in 0..(WARMUP_RUNS + BENCH_RUNS) {
            mp.clear();
            let t0 = Instant::now();
            for (i, &k) in keys.iter().enumerate() {
                mp.put(k, i as i64);
            }
            let mut cs = 0i64;
            for &k in &keys {
                cs += mp.get_or_default(k, -1);
                cs += mp.get_or_default(k ^ 0x5555_5555_5555_5555, 0);
            }
            let ms = t0.elapsed().as_secs_f64() * 1000.0;
            check_sum = cs;
            if run >= WARMUP_RUNS {
                samples.push(ms);
            }
        }
        print_stats(
            "[2b] RustFastMap SplitMix64 (3M ops)",
            &mut samples,
            &format!("slots={}, sum={}", slots, check_sum),
        );
    }

    // ---------------------------------------------------------------------------
    // 3. Блочная POD-сериализация 2 000 000 VoxelPacket (sizeof=32, 64 МБ)
    // ---------------------------------------------------------------------------
    {
        const P: usize = 2_000_000;
        assert_eq!(std::mem::size_of::<VoxelPacket>(), 32);
        let mut packets = Vec::with_capacity(P);
        for i in 0..P {
            packets.push(VoxelPacket {
                entity_id: (i + 1) as i64,
                chunk_x: (i & 1023) as i32,
                chunk_y: ((i >> 10) & 255) as i32,
                chunk_z: -(i as i32),
                health: 100.0f32,
                flags: i as u32,
                pad: 0u32,
            });
        }

        let mut samples = Vec::with_capacity(BENCH_RUNS);
        let mut byte_len = 0usize;
        let mut byte_hash = 0u64;
        let mut verify_id = 0i64;

        for run in 0..(WARMUP_RUNS + BENCH_RUNS) {
            let t0 = Instant::now();
            let raw_bytes = pack_bin_pod(&packets);
            let unpacked = unpack_bin_pod(&raw_bytes);
            let ms = t0.elapsed().as_secs_f64() * 1000.0;
            byte_len = raw_bytes.len();
            verify_id = unpacked[P - 1].entity_id + (unpacked[P - 1].chunk_z as i64);
            byte_hash ^= hash_bytes_sample(&raw_bytes);
            if run >= WARMUP_RUNS {
                samples.push(ms);
            }
        }
        print_stats(
            "[3] ZeroPack POD (2M x 32B = 64MB)",
            &mut samples,
            &format!("bytes={}, hash={:#x}, chk={}", byte_len, byte_hash, verify_id),
        );
    }

    // ---------------------------------------------------------------------------
    // 4. Векторная аналитика 25 000 000 i64 (8-Way DotProduct + Branchless Filter)
    // ---------------------------------------------------------------------------
    {
        const K: usize = 25_000_000;
        let mut vec_a = Vec::with_capacity(K);
        let mut vec_b = Vec::with_capacity(K);
        let mut rng = XorShift64::new(SEED);
        for i in 0..K {
            vec_a.push(rng.next_i64() & 0xFFFF);
            vec_b.push((i & 7) as i64);
        }

        let mut samples = Vec::with_capacity(BENCH_RUNS);
        let mut dot_res = 0i64;
        let mut cnt_res = 0usize;

        for run in 0..(WARMUP_RUNS + BENCH_RUNS) {
            let t0 = Instant::now();
            let d = std::hint::black_box(fast_dot_product_rust(
                std::hint::black_box(&vec_a),
                std::hint::black_box(&vec_b),
            ));
            let c = std::hint::black_box(fast_count_greater_rust(
                std::hint::black_box(&vec_a),
                std::hint::black_box(32768),
            ));
            let ms = t0.elapsed().as_secs_f64() * 1000.0;
            dot_res = d;
            cnt_res = c;
            if run >= WARMUP_RUNS {
                samples.push(ms);
            }
        }
        print_stats(
            "[4] SimdScan 8-Way (25M i64)",
            &mut samples,
            &format!("dot={}, count={}", dot_res, cnt_res),
        );
    }
}
