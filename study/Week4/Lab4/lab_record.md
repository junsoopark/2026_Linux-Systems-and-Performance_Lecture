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

**목표**: working set을 16KB → 64MB로 키우며 random pointer chase의 접근당 시간(ns)을 재고, 시간이 급증하는 지점에서 cache 계층 경계를 찾는다.

**원리** (`src/ws_demo.c`)
- L40: buffer를 64B(cache line) 칸으로 나누고, 각 칸에 "다음에 읽을 칸 번호"를 무작위 순환 순서로 기록 (Sattolo 알고리즘 → 모든 칸을 한 번씩 도는 하나의 cycle)
- L45: `p = buf[p]` — 다음 주소가 직전 load 결과로 정해지는 **dependent load**. prefetcher가 다음 주소를 예측할 수 없고, out-of-order 실행으로 여러 load를 겹칠 수도 없다 → 측정값 = 순수 memory **latency**

### 사전 예측

lscpu 기준 경계는 L1d 48KB / L2 1.25MB / L3 12MB (코어당 크기, 위 Q&A 참고).

| 구간 | 예상 위치 | 예상 ns/access |
| --- | --- | --- |
| ≤ 32KB | L1d | ~1 (약 4~5 cycle) |
| 64KB ~ 1MB | L2 | ~3 (약 14 cycle) |
| 2MB ~ 8MB | L3 | ~10~15 |
| ≥ 16MB | DRAM | 60~100 |

bare metal이라 L3를 VM과 나눠 쓰지 않으므로 WSL2보다 경계가 뚜렷할 것으로 예상.

### 실행 및 관측

**1) 크기별 sweep** — `./bin/ws_demo 16 65536 20000000 | tee logs/ws-sweep.txt`

| size_kb | ns/access | 위치 |
| ---: | ---: | --- |
| 16 | 1.48 | L1d |
| 32 | 1.29 | L1d |
| **64** | **3.22** | L2 ← 경계 1 |
| 128 | 3.29 | L2 |
| 256 | 3.26 | L2 |
| 512 | 3.99 | L2 (TLB 영향 시작) |
| 1024 | 4.88 | L2 (거의 가득) |
| **2048** | **10.65** | L3 ← 경계 2 |
| 4096 | 12.00 | L3 |
| 8192 | 17.09 | L3 (거의 가득) |
| **16384** | **60.40** | DRAM ← 경계 3 |
| 32768 | 85.31 | DRAM |
| 65536 | 92.69 | DRAM |

**2) 반복 측정** — `logs/ws-repeat.txt`

| | 1회 | 2회 | 3회 |
| --- | ---: | ---: | ---: |
| 32KB | 1.37 | 1.33 | 1.32 |
| 8MB | 19.09 | 16.35 | 17.37 |

→ 8MB가 32KB보다 일관되게 약 13배 느림. 측정 안정적.

**관측 기록지 — 1 Cache 계층**

| 변화 지점 | 크기 (KB) | ns/access (이전) | ns/access (이후) | 대응하는 cache | 일치 여부 |
| --- | --- | ---: | ---: | --- | --- |
| 1 | 32 → 64 | 1.29 | 3.22 (×2.5) | L1d (48KB) | 일치 |
| 2 | 1024 → 2048 | 4.88 | 10.65 (×2.2) | L2 (1.25MB) | 일치 |
| 3 | 8192 → 16384 | 17.09 | 60.40 (×3.5) | L3 (12MB) | 일치 |

### 확인 질문 (Q1.1 ~ Q1.3)

**Q1.1** 급증 지점과 lscpu 크기 비교, 불일치 요인은?
- 세 경계 모두 lscpu 크기(48KB / 1.25MB / 12MB)가 들어 있는 2배 구간에서 정확히 나타났다. 2배 단위로 재므로 정확한 경계는 그 사이 어딘가.
- 경계 **직전에도 시간이 서서히 오른다** (512KB 3.99 → 1MB 4.88, 4MB 12.0 → 8MB 17.1). 원인 후보:
  - **TLB miss**: L1 dTLB는 4KB page 기준 64 entry ≈ 256KB만 커버한다. 그 이상은 STLB 조회나 page walk 비용이 더해진다.
  - cache가 꽉 차기 전부터 set 충돌(associativity 한계)이나 다른 process가 같은 L3를 써서 일부 line이 밀려난다.
- 강의 환경(WSL2)에서 의심하던 hypervisor나 다른 vCPU의 L3 공유는 여기 없다. 그래서 L3 경계가 lscpu 값과 잘 맞는다.

**Q1.2** 순차 접근이면 경계가 보이는가? → **직접 테스트함** (아래 추가 테스트 1). DRAM 경계가 거의 사라진다. hardware prefetcher가 다음 line을 미리 가져와 latency를 가린다.

**Q1.3** 왜 miss 횟수가 아니라 시간으로 재는가? PMU라면 어떤 event?
- 강의 환경(WSL2)은 Hyper-V가 PMU를 노출하지 않아 hardware event를 쓸 수 없다. 그래서 miss가 만든 **시간 증가**로 간접 측정했다. 시간에는 interrupt나 다른 process의 간섭도 섞인다.
- PMU event 예: `L1-dcache-load-misses`(L1 miss), `LLC-load-misses`(L3 miss → DRAM). 또는 `cycles`와 `instructions`로 IPC 급락을 확인.
- 이 PC는 bare metal이라 PMU 사용 가능 → **추가 테스트 2로 직접 확인 예정** (perf 권한 설정 필요).

### 질문 & 추가 테스트

**Q. working set 크기와 상관없이 크기마다 2천만 번 접근하고 평균을 낸 것인가?**

맞다. 크기마다 똑같이 `accesses`(세 번째 인자, 20,000,000)번 접근하고, 걸린 시간 ÷ 접근 횟수 = 평균 ns/access (`src/ws_demo.c` L43~L48).

```c
t0 = now_ns();
for (i = 0; i < accesses; i++)      // accesses = 20,000,000
    p = buf[p];                      // 다음 칸 따라가기
t1 = now_ns();
printf(..., (t1 - t0) / accesses);  // 평균 ns/access
```

1. **접근 횟수는 같지만 칸마다 방문하는 횟수는 크기에 따라 다르다** (칸 = 64B line, 무작위 순환 경로를 반복).

   | 크기 | 칸(line) 수 | 2천만 번 동안 한 칸 방문 횟수 |
   | --- | ---: | ---: |
   | 16KB | 256 | 약 78,000 |
   | 1MB | 16,384 | 약 1,200 |
   | 64MB | 1,048,576 | 약 19 |

   작은 크기는 같은 칸을 수만 번 반복해서 전부 cache에 남는다. 큰 크기는 같은 칸에 다시 돌아올 때쯤 이미 cache에서 밀려나 있다. 이 차이가 곧 측정 대상이다.
2. **시간 측정 범위는 접근 반복문뿐이다.** buffer 할당과 경로 생성은 t0 전에 끝나고, 이때 buffer에 값을 미리 써 두므로 page fault(첫 메모리 할당) 비용도 빠진다. 첫 바퀴의 cold miss는 포함되지만, 작은 크기에서는 전체의 극히 일부이고 큰 크기에서는 어차피 매번 miss라 영향이 미미하다.
3. **평균값이라 분포는 보이지 않는다.** 예: 8MB의 17ns는 모든 접근이 17ns라는 뜻이 아니라, 대부분 L3 hit(~10ns)이고 일부가 DRAM miss(~90ns)인 것이 섞인 결과로 해석한다. 경계 직전에 시간이 서서히 오르는 이유도 같다.

**추가 테스트 1: 순차 접근 (Q1.2 검증)**
- 원본은 유지하고 `src/ws_seq.c`를 추가했다. ws_demo와 같은 dependent load인데, 다음 칸만 항상 `i+1`이다.
- 빌드: `cc -O2 -g -Wall -Wextra -std=gnu11 -fno-omit-frame-pointer -pthread -o bin/ws_seq src/ws_seq.c`
- 실행: `./bin/ws_seq 16 65536 20000000 | tee logs/ws-seq-sweep.txt`

| size_kb | random (ns) | sequential (ns) | 배율 |
| ---: | ---: | ---: | ---: |
| 32 | 1.29 | 1.35 | 1.0× |
| 64 | 3.22 | 2.75 | 1.2× |
| 1024 | 4.88 | 2.73 | 1.8× |
| 2048 | 10.65 | 2.89 | 3.7× |
| 8192 | 17.09 | 3.75 | 4.6× |
| 16384 | 60.40 | 6.30 | 9.6× |
| 65536 | 92.69 | 5.28 | **17.6×** |

- 해석
  - 순차 접근에서도 L1 경계(32→64KB, 1.35→2.75)는 남는다. prefetcher가 주로 L2로 데이터를 끌어오기 때문에 L1 hit만큼 빠르지는 않다.
  - L2/L3/DRAM 경계는 거의 사라진다. DRAM(64MB)에서도 5ns로, 무작위 접근의 1/18이다.
  - 이 코드도 dependent load라서 out-of-order로 load를 겹칠 수 없다. 따라서 **이 차이는 거의 전부 hardware prefetcher 효과**다 (답안은 OoO도 함께 언급하지만, 이 테스트에서는 prefetcher만으로 설명된다).

**추가 테스트 2: PMU로 cache miss 직접 측정** — TODO (`sudo sysctl kernel.perf_event_paranoid=1` 후 진행)

### 현업 적용 포인트

- **같은 연산량이라도 데이터 크기와 접근 패턴에 따라 최대 70배까지 느려진다** (L1 1.3ns vs DRAM 92ns). 성능 문제를 볼 때 연산량만 보지 말고 working set 크기와 접근 패턴을 함께 본다.
- **hot data를 코어당 L2(1.25MB) 안에 맞추면 큰 이득**이다. 예: lookup table 크기 줄이기, 자주 쓰는 field만 따로 모으기(hot/cold 분리), AoS → SoA 변환.
- **pointer chasing 자료구조(linked list, tree, hash chaining)는 prefetcher가 무력화된다.** 큰 데이터셋에서는 배열 기반 구조가 같은 O(n)이라도 10배 이상 빠를 수 있다 (추가 테스트 1).
- 벤치마크할 때는 **입력 크기를 실제 운영 규모로** 맞춘다. 작은 테스트 데이터는 cache에 다 들어가서 운영 환경보다 훨씬 빠르게 나온다.

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
