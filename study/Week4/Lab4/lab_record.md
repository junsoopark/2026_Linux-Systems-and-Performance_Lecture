# Week 4 Lab 기록 — CPU 구조와 cache, scheduling

> 원본 자료: `../../../Week4/Lab4/` (안내서: `Lab4_instructions.md`, 답안: `Lab4_answers.md`)
>
> 실습 순서대로 **실행 → 관측 → 질문/추가 테스트 → 현업 적용 포인트**를 기록한다.

## 환경

| 항목 | 값 |
| --- | --- |
| 날짜 | 2026-10-06 |
| 실행 환경 | bare metal Linux (가상화 없음, `systemd-detect-virt` = none) |
| Kernel | 7.0.0-15-generic (강의 기준 6.6.x WSL2와 다름) |
| CPU | 11th Gen Intel Core i7-11370H @ 3.30GHz (Tiger Lake) |
| 코어 | 4 core / 8 thread (SMT 2), 1 socket |
| L1d | 48 KiB / core (총 192 KiB, 4 instances) |
| L2 | 1.25 MiB / core (총 5 MiB, 4 instances) |
| L3 | 12 MiB, 전 코어 공유 (1 instance) |
| PMU | 사용 가능 (bare metal) — 강의의 WSL2 제약과 달리 `perf stat` hardware event 측정 가능 |

### 강의 환경(WSL2)과의 차이

- hypervisor가 없으므로 L3를 다른 VM/Windows process와 나눠 쓰지 않음 → cache 경계가 더 뚜렷할 것으로 예상
- PMU event(`cache-misses`, `L1-dcache-load-misses`, `LLC-load-misses`, `cycles`, `instructions`)로 실행 시간 결과를 교차 검증 가능
- SMT가 있으므로 "다른 CPU"가 같은 물리 코어의 hyperthread인지 다른 코어인지에 따라 결과가 달라질 수 있음 (`lscpu -e`로 확인)
  - `lscpu -e` 결과: CPU n과 n+4가 같은 물리 코어 (0/4, 1/5, 2/6, 3/7). 즉 안내서의 CPU 0/1은 **서로 다른 물리 코어**(L1·L2 별도, L3 공유)

### 준비 과정 메모

- `check_env.sh`: perf stat 실패 → 원인은 `kernel.perf_event_paranoid=4` (Ubuntu 기본값, 일반 사용자 PMU 접근 차단)

---

## 실습 1. Cache와 working set의 크기

### 사전 예측

### 실행 및 관측

### 확인 질문 (Q1.1 ~ Q1.3)

### 질문 & 추가 테스트

### 현업 적용 포인트

---

## 실습 2. False sharing

### 사전 예측

### 실행 및 관측

### 확인 질문 (Q2.1 ~ Q2.3)

### 질문 & 추가 테스트

### 현업 적용 포인트

---

## 실습 3. Scheduling 지연 진단

### 사전 예측

### 실행 및 관측

| 조건 | renderer late_p99u | miss | perf Max delay (ms) | indexer cpu_ms |
| --- | --- | --- | --- | --- |
| 기본 (둘 다 nice 0, CPU 0) | | | | |
| A: indexer nice 10 | | | | |
| B: lab/bg cpu.weight 20 | | | | |
| C: lab/bg cpu.max 30% | | | | |
| D: lab/bg cpuset 1 | | | | |

### 확인 질문 (Q3.1 ~ Q3.3)

### 질문 & 추가 테스트

### 현업 적용 포인트

---

## 정리 / 배운 점
