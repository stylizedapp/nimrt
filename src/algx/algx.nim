## algx — Единый пакет высокопроизводительных алгоритмов и структур данных Nim
##
## Включает:
## - `ultrasort`: 3-Level Cache-Aware Hybrid MSD Radix + L1 Insertion Sort
## - `swissmap`: Плоская хэш-таблица `FastMap[K, V]` с 1-байтовыми тегами в кэше L1
## - `zeropack`: Zero-Copy бинарная и JSON сериализация на этапе компиляции
## - `simdscan`: 8-канальная суперскалярная и SIMD-аналитика массивов
## - `heap`: Cache-friendly BinaryHeap[T] и in-place heapify

import ./ultrasort
import ./swissmap
import ./zeropack
import ./simdscan
import ./heap

export ultrasort, swissmap, zeropack, simdscan, heap
