// benchmarks/rust_ultra_showcase.rs — Эталонный 3-Level Hybrid MSD Radix Sort на Rust
// Для честного сравнения скорости, объёма кода, читаемости и размера бинарника с Nim.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Barrier;
use std::thread;
use std::time::Instant;

const NUM_THREADS: usize = 4;
const R1: usize = 256;
const SHIFT1: u32 = 56;
const R3: usize = 128;
const SHIFT3: u32 = 41;

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

fn generate_data(size: usize, seed: u64) -> Vec<i64> {
    let mut rng = XorShift64::new(seed);
    let mut v: Vec<i64> = Vec::with_capacity(size);
    unsafe {
        let ptr: *mut i64 = v.as_mut_ptr();
        for i in 0..size {
            *ptr.add(i) = rng.next_i64();
        }
        v.set_len(size);
    }
    v
}

fn is_sorted(arr: &[i64]) -> bool {
    for i in 1..arr.len() {
        if arr[i - 1] > arr[i] {
            return false;
        }
    }
    true
}

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

    // В Rust сырые указатели запрещено передавать между потоками напрямую,
    // поэтому приходится приводить каждый указатель к `usize` и обратно в `unsafe`.
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

fn main() {
    let n = 10_000_000;
    let seed = 0xDEAD_BEEF_CAFE_1234;

    let mut data = generate_data(n, seed);
    let mut aux = vec![1i64; n];

    let ms = ultra_sort_rust(&mut data, &mut aux);
    assert!(is_sorted(&data), "Ultra Rust sort failed!");
    println!("Rust UltraSort (10M int64, 4T): {:.2} ms", ms);
}
