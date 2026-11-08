// Atomic loads, stores and a seqlock for Ahenk's real-time audio path.
//
// Swift's Synchronization.Atomic needs macOS 15 and Ahenk runs on 14.2, so
// the few atomics the audio path needs are the compiler's builtins, wrapped
// in static inline functions Swift can call directly. Every function is
// lock-free and allocation-free, so it is safe on Core Audio's I/O thread.

#ifndef AHENK_ATOMICS_H
#define AHENK_ATOMICS_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

static inline int64_t ahenk_load_acquire(const int64_t *value) {
    return __atomic_load_n(value, __ATOMIC_ACQUIRE);
}

static inline int64_t ahenk_load_relaxed(const int64_t *value) {
    return __atomic_load_n(value, __ATOMIC_RELAXED);
}

static inline void ahenk_store_release(int64_t *value, int64_t newValue) {
    __atomic_store_n(value, newValue, __ATOMIC_RELEASE);
}

static inline void ahenk_store_relaxed(int64_t *value, int64_t newValue) {
    __atomic_store_n(value, newValue, __ATOMIC_RELAXED);
}

static inline int64_t ahenk_fetch_add_relaxed(int64_t *value, int64_t delta) {
    return __atomic_fetch_add(value, delta, __ATOMIC_RELAXED);
}

// Seqlock over `count` 64-bit words: one writer, any number of readers, no
// one ever waits. The writer makes the sequence odd, writes the words and
// makes it even again; a reader copies the words and keeps the copy only if
// the sequence was even and unchanged around it. Data words are relaxed
// atomics, so a racing read is detected instead of being undefined
// (H.-J. Boehm, "Can Seqlocks Get Along With Programming Language Memory
// Models?", MSPC 2012).

static inline void ahenk_seqlock_write(int64_t *sequence, uint64_t *words, const uint64_t *source, size_t count) {
    int64_t start = __atomic_load_n(sequence, __ATOMIC_RELAXED);
    __atomic_store_n(sequence, start + 1, __ATOMIC_RELAXED);
    __atomic_thread_fence(__ATOMIC_RELEASE);
    for (size_t index = 0; index < count; index++) {
        __atomic_store_n(&words[index], source[index], __ATOMIC_RELAXED);
    }
    __atomic_store_n(sequence, start + 2, __ATOMIC_RELEASE);
}

/// True when `destination` holds a consistent copy.
static inline bool ahenk_seqlock_read(const int64_t *sequence, const uint64_t *words, uint64_t *destination, size_t count) {
    int64_t before = __atomic_load_n(sequence, __ATOMIC_ACQUIRE);
    if (before & 1) {
        return false;
    }
    for (size_t index = 0; index < count; index++) {
        destination[index] = __atomic_load_n(&words[index], __ATOMIC_RELAXED);
    }
    __atomic_thread_fence(__ATOMIC_ACQUIRE);
    int64_t after = __atomic_load_n(sequence, __ATOMIC_RELAXED);
    return before == after;
}

#endif
