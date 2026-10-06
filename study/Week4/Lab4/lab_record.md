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

### Q. L1d에만 왜 d가 붙나? "4 instances"는 무슨 뜻인가?

- **L1은 명령어용과 데이터용으로 나뉘어 있다** (split L1, Harvard 구조).
  - `L1d` = L1 **data** cache: load/store로 읽고 쓰는 데이터
  - `L1i` = L1 **instruction** cache: CPU가 실행할 기계어 명령
  - 매 cycle 명령 fetch와 데이터 load가 동시에 일어나므로 포트를 분리해 충돌을 없앤다.
  - L2/L3는 명령과 데이터를 함께 담는 **unified cache**라서 접미사가 없다.
- **lscpu의 크기는 전체 합계이고, instances는 사본 개수**다. 크기 ÷ instances = 한 개당 크기.

| cache | lscpu 표시 | 한 개 크기 | 공유 범위 | associativity | line |
| --- | --- | --- | --- | --- | --- |
| L1d | 192 KiB (4) | **48 KiB** | 코어 1개 (SMT 2 thread가 공유) | 12-way | 64 B |
| L1i | 128 KiB (4) | 32 KiB | 코어 1개 | - | 64 B |
| L2 | 5 MiB (4) | **1.25 MiB** | 코어 1개 | 20-way | 64 B |
| L3 | 12 MiB (1) | **12 MiB** | 전체 4코어 | 12-way | 64 B |

(`getconf -a | grep CACHE`로 확인)

- **실험상 의미**: thread 하나는 자기 코어의 L1d 48KB, L2 1.25MB만 쓸 수 있다. 192KB를 다 쓰는 것이 아니다. 그래서 `ws_demo`의 경계 예측은 48KB / 1.25MB / 12MB 기준이다.
- L3는 4코어가 나눠 쓰므로, 다른 프로그램이 돌고 있으면 실제로 쓸 수 있는 크기가 12MB보다 작아진다.

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

---

## 용어 정리 (약어 full name)

| 약어 | Full name | 의미 |
| --- | --- | --- |
| L1d / L1i | Level 1 data / instruction cache | 코어 전용 첫 단계 cache. 데이터용과 명령어용으로 분리 |
| LLC | Last Level Cache | 가장 마지막 단계 cache. 이 PC에서는 L3 |
| cache line | - | cache가 데이터를 옮기는 최소 단위. x86은 64 byte |
| N-way (associativity) | N-way set associative | 한 주소가 들어갈 수 있는 cache 내 자리 수 |
| DRAM | Dynamic Random Access Memory | 주 메모리 |
| TLB | Translation Lookaside Buffer | 가상→물리 주소 변환 결과를 담는 cache. working set이 크면 TLB miss도 지연을 늘린다 |
| PMU | Performance Monitoring Unit | CPU 내장 하드웨어 카운터 (cycles, instructions, cache miss 등). `perf stat`이 읽는다 |
| IPC | Instructions Per Cycle | cycle당 실행한 명령 수. 낮으면 memory 대기 등으로 CPU가 놀고 있다는 신호 |
| SMT | Simultaneous Multithreading | 물리 코어 하나를 논리 CPU 2개로 보이게 하는 기술. Intel 상표명은 Hyper-Threading |
| vCPU | virtual CPU | VM에 할당된 가상 CPU |
| MESI | Modified / Exclusive / Shared / Invalid | cache coherence protocol의 cache line 상태 4가지 (실습 2) |
| perf c2c | perf cache-to-cache | 코어 간 cache line 이동(false sharing)을 찾는 perf 도구 |
| NUMA | Non-Uniform Memory Access | CPU socket마다 가까운 메모리가 다른 구조. 이 PC는 1 socket이라 해당 없음 |
| big.LITTLE | - | 고성능 코어와 저전력 코어를 섞은 구조 (ARM 용어, Intel은 P-core/E-core) |
| EAS | Energy Aware Scheduling | 전력 효율을 고려해 코어를 고르는 scheduler 기능 |
| uclamp | utilization clamping | task의 utilization 값을 최소/최대로 고정해 scheduler 판단에 영향 |
| HZ | - | 초당 timer tick 수. HZ=250이면 tick 간격 4ms |
| p99 | 99th percentile | 하위 99% 값. 상위 1%의 최악 지연을 보는 지표 |
| cgroup | control group | process 묶음에 CPU·메모리 등 자원 제한을 거는 kernel 기능 (실습 3) |
| SCHED_FIFO | - | 실시간(RT) scheduling policy. 더 높은 우선순위 task가 나타날 때까지 계속 실행 |
