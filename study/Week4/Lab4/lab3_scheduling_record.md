# Week 4 실습 3 — Scheduling 지연 진단 (jank case study)

> 원본: `Lab4_instructions.md` 실습 3, `Lab4_answers.md` Q3.1~Q3.3, 강의 52~64쪽
> 환경: `lab_record.md` 환경 섹션 참고 (bare metal, i7-11370H 4C/8T, kernel 7.0)
>
> **현업 적용 목표**: webOS 미디어 프레임워크 플레이어에서 Netflix 인증 등 성능 이슈(frame drop, A/V sync 깨짐, 재생 끊김)가 날 때, "CPU 사용률은 낮은데 왜 늦나?"를 perf sched로 진단하고 조치하는 절차를 익힌다.

## 시나리오

| 역할 | 실습 thread | 동작 | 현업 대응 예 |
| --- | --- | --- | --- |
| victim | `renderer` | 16.667ms(60fps)마다 깨어나 4ms 일하고 다시 잠듦 | video render / audio feed thread |
| culprit | `indexer` | CPU를 쉬지 않고 사용 (busy loop) | 백그라운드 indexing, 업데이트, 로그 압축 등 |

두 thread를 같은 CPU 0에 고정해 경쟁시키고, renderer의 지연을 측정한다.

## mtwork 출력 컬럼

| 컬럼 | 의미 | 출처 |
| --- | --- | --- |
| `cpu_ms` | 실제 CPU 사용 시간 (user+sys) | `getrusage` |
| `exec_ms` | CPU에서 실행된 시간 | `/proc/self/task/<tid>/schedstat` 1번째 |
| `wait_ms` | **runnable 상태로 runqueue에서 기다린 시간** (실행 가능하지만 CPU를 못 받음) | schedstat 2번째 |
| `pcount` | CPU를 받은 횟수 | schedstat 3번째 |
| `vol` | 자발적 context switch (sleep 등으로 스스로 양보) | `getrusage` nvcsw |
| `invol` | **비자발적 context switch (다른 task에게 선점당함)** | `getrusage` nivcsw |
| `iters` | 주기(frame) 수. 10초 / 16.667ms ≈ 600 | |
| `late_p99u` | 깨어나야 할 시각 대비 실제로 실행을 시작한 시각의 지연, p99 (µs) | |
| `miss` | frame 작업이 다음 주기 시작 전에 끝나지 못한 횟수 | |
| `rounds` | 작업 loop 반복 횟수 (처리량 지표) | |

## 사전 예측

**예측 1** (기본 조건 Max delay): 둘 다 nice 0이면 CFS/EEVDF가 **둘 다 runnable인 구간에서** CPU 시간을 반반 나눈다 (아래 Q&A "CPU를 반반 나눈다는 기준" 참고). 강의 환경(HZ=250, tick 4ms) 기준으로는 renderer가 깨어나도 indexer의 slice가 끝날 때까지 수 ms 기다릴 수 있다.
→ 이 PC는 **HZ=1000 (tick 1ms)**, kernel 7.0 **EEVDF** scheduler, `PREEMPT_LAZY`라서 강의보다 지연이 작을 것으로 예상.

**예측 2** (조치별):
- A nice 10 / B cpu.weight 20: indexer의 weight가 줄어 renderer 지연 감소
- C cpu.max 30%: indexer가 throttle된 구간에서는 지연이 없지만, quota가 남은 구간에서는 여전히 경쟁 → 개선이 들쭉날쭉할 수 있음
- D cpuset 1: CPU를 아예 분리하므로 renderer 지연이 가장 확실히 사라질 것

## 실행 및 관측

### 0) 참고: renderer 단독 실행 (경쟁 없음) — `logs/lab3-alone.txt`

```bash
./bin/mtwork -d 10 -n renderer periodic:16667:4000,cpu=0
```

| cpu_ms | exec_ms | wait_ms | pcount | vol | invol | rounds | iters | late_p99u | miss |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 2421.7 | 2421.7 | 10.7 | 676 | 600 | 76 | 195,046 | 600 | 264.1 | 0 |

### 1) 기본 조건: indexer + renderer, 둘 다 CPU 0 — `logs/lab3-base-*.txt`

```bash
./bin/mtwork -d 14 -n indexer busy,cpu=0            # 터미널 B
./bin/mtwork -d 10 -n renderer periodic:16667:4000,cpu=0   # 터미널 A
```

| thread | cpu_ms | wait_ms | pcount | vol | invol | rounds | iters | late_p99u | miss |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| renderer | 1936.4 | **1937.9** | 1223 | 600 | **623** | 523,959 | 600 | **70.9** | **0** |
| indexer | 12037.5 | 1962.9 | 1848 | 0 | 1848 | 3,301,107 | - | - | - |

### 단독 vs 경쟁 비교에서 보이는 것

| 지표 | 단독 | 경쟁 | 해석 |
| --- | ---: | ---: | --- |
| wait_ms | 10.7 | **1937.9** | frame마다 평균 3.2ms를 runqueue에서 대기. **진짜 지연은 여기서 드러남** |
| invol | 76 | **623** | frame마다 약 1번 indexer에게 선점당함 |
| cpu_ms | 2421.7 | 1936.4 | `work_item`이 "4ms 동안 일하기"(벽시계 기준)라서, 선점당한 시간만큼 실제 CPU 시간이 줄어듦 |
| late_p99u | 264.1 µs | **70.9 µs** | 경쟁할 때가 오히려 빠르게 깨어남 (아래 분석) |
| miss | 0 | 0 | 강의 예상과 달리 miss 없음 (아래 분석) |

### 강의 예상과 다른 점 분석

1. **late_p99u가 작고, 단독일 때가 오히려 크다 (264µs vs 71µs)**
   - 깨어날 때의 지연(wakeup latency)은 EEVDF 덕분에 작다. sleep하던 task는 깨어날 때 "덜 받은 몫(lag)"이 있어서 바로 CPU를 받는다.
   - 단독일 때 더 느린 이유는 **CPU 절전**이다. 경쟁 task가 없으면 CPU 0이 frame 사이 12ms 동안 idle이 된다. 그러면 깊은 C-state(절전 상태)로 들어가고 주파수도 내려간다 (governor = `powersave`, 확인 당시 CPU 0이 781MHz). 다시 깨어날 때 C-state 탈출 시간이 걸린다.
   - `rounds`도 이를 뒷받침한다. 단독(195K)보다 경쟁(524K)일 때 같은 4ms에 2.7배 더 많이 일했다 → CPU가 계속 바빠서 높은 주파수가 유지됐다.
2. **miss가 0**
   - 주기 16.7ms 중 renderer가 할 일은 4ms(벽시계 기준)이다. 중간에 선점당해도 4ms 뒤에는 무조건 끝나므로, 깨어나는 게 12.7ms 이상 늦지 않는 한 miss가 날 수 없다.
   - 실제 플레이어의 작업은 "frame 1장 decode/render"처럼 **양이 정해진 일**이라, CPU를 빼앗기면 그만큼 작업 시간이 늘어난다. 이 실습에서 그 손실은 `wait_ms`와 `invol`, `cpu_ms` 감소로 나타난다.

## 확인 질문 (Q3.1 ~ Q3.3)

## 질문 & 추가 테스트

**Q. "16.667ms(60fps)마다 깨어나 4ms 일하고 다시 잠듦"을 어떻게 시뮬레이션했나?**

`periodic:16667:4000` = 주기 16,667µs, 작업 4,000µs. `src/mtwork.c` `thread_main` L259~L281 (단순화):

```c
t0 = now_ns();                            // 시작 시각
for (i = 0; now_ns() < end; i++) {
    expected = t0 + i * period;           // i번째 frame이 시작돼야 할 시각 (절대 시각)
    start    = now_ns();
    late[n++] = start - expected;         // ① 얼마나 늦게 시작했나 → late_p99u

    work_item(4ms);                       // ② 4ms 동안 CPU 계산 (busy loop)

    if (now_ns() > expected + period)     // ③ 다음 frame 시작 시각을 넘겼으면
        misses++;                         //    → miss

    next += period;                       // ④ 다음 frame 시작 시각까지
    clock_nanosleep(..., TIMER_ABSTIME, &next);  //    잠듦 (CPU 반납)
}
```

1. **잠들고 깨어나기 (④)**: `clock_nanosleep`에 **절대 시각**(`TIMER_ABSTIME`)을 준다. 상대 시간("16.667ms 자기")을 쓰면 작업 시간과 wakeup 지연이 매 frame 누적돼 주기가 밀린다. 절대 시각이면 frame i의 기준이 항상 `t0 + i × 16.667ms`로 고정된다. vsync 기반 렌더 루프와 같은 방식이다.
2. **일하기 (②)**: `work_item`은 곱셈·덧셈 계산 loop를 **벽시계 기준 4ms가 될 때까지** 돌린다. 그 사이 실제 반복 횟수가 `rounds`다. 선점당해도 4ms가 지나면 끝나고, 대신 `rounds`(처리량)와 `cpu_ms`가 줄어든다. → 기본 조건에서 miss가 0이었던 이유.
3. **지연 측정 (①)**: 깨어나 실제로 실행된 시각 − 원래 시작해야 할 시각을 frame마다 기록하고, 정렬해서 99번째 백분위를 `late_p99u`로 출력한다. timer가 울린 뒤 scheduler가 CPU를 주기까지의 대기와 C-state 탈출 시간이 포함된다.
4. **miss 판정 (③)**: 작업이 끝난 시각이 다음 frame 시작 시각을 넘으면 miss. 이때 다음 `clock_nanosleep`은 이미 지난 시각이라 바로 반환된다 → 늦은 frame을 바로 따라잡는 구조.

**실제 플레이어와 다른 점**
- 실제 render thread는 timer 대신 vsync, 디코더 출력 같은 이벤트를 기다리는 경우가 많다.
- 실제 작업은 "frame 1장 처리"처럼 **양이 정해진 일**이다. CPU를 빼앗기면 처리 시간 자체가 늘어나 miss로 바로 이어진다.
- 추가 테스트 후보: `work_item`을 "N rounds 할 때까지"로 바꾼 고정 작업량 버전으로 조치별 miss 차이 비교.

**Q. `next`의 초기값은?**

측정 시작 시각 `t0`를 `timespec`(초 + ns)으로 바꾼 값 (L253, L263).

```c
uint64_t t0 = now_ns(), end = t0 + run_ns;      // L253: 측정 시작 시각 (ns)
struct timespec next = { .tv_sec  = t0 / 1000000000,     // L263
                         .tv_nsec = t0 % 1000000000 };
```

`now_ns()`와 `clock_nanosleep` 모두 `CLOCK_MONOTONIC`을 쓰므로 기준이 같다.

| frame i | 시작 기준 `expected` | 작업 후 `next` (잠들었다 깰 시각) |
| --- | --- | --- |
| 0 | t0 | t0 + 16.667ms |
| 1 | t0 + 16.667ms | t0 + 33.333ms |
| i | t0 + i × P | t0 + (i+1) × P |

- frame 0은 잠들지 않고 바로 시작한다 (첫 `late` ≈ 0).
- `next`는 항상 **다음 frame의 `expected`와 같다** → `late = start - expected` = "깨워 달라고 한 시각보다 얼마나 늦게 실행됐나".
- `next`는 실제로 깨어난 시각이 아니라 이전 `next`에 주기를 더해 갱신한다. 그래서 한 번 늦게 깨어나도 지연이 다음 frame으로 쌓이지 않는다.

**Q. "CPU를 반반 나눈다"는 사이클 수 기준인가, 실행 시간 기준인가?**

**실행 시간(ns) 기준이다.** 그리고 "반반"은 **두 task가 동시에 runnable인 구간에서만** 성립한다.

1. **기준은 실행 시간**: scheduler는 task가 CPU를 잡고 있던 시간을 ns 단위로 잰다. 사이클·명령어 수는 보지 않는다.
   - 같은 1ms라도 4.8GHz와 800MHz는 처리량이 6배 다르지만 scheduler에게는 같은 1ms다. cache miss로 멈춘 시간도 실행 시간에 포함된다.
   - 기본 조건에서 경쟁 시 `rounds`가 단독보다 2.7배 많았던 것이 그 예다 (시간은 같아도 주파수 차이로 일한 양이 다름).
2. **nice → weight 비율로 나눈다**: nice 0 = 1024, nice 10 ≈ 110 (한 단계에 약 1.25배).
   - runnable task끼리 weight 비율대로 시간을 나눈다. nice 0 둘 = 50:50, 조치 A(indexer nice 10) = 1024:110 ≈ 90:10.
   - 자고 있는 task는 몫을 나누는 대상에서 빠진다. renderer가 주기의 75%를 자는 동안은 indexer가 CPU를 혼자 쓴다 → 둘이 같이 돈 10초 동안 renderer 약 19%, indexer 약 80% (아래 Q 참고).
   - **측정값으로 확인**: renderer가 frame 하나를 처리하는 동안 `exec_ms` 1936 / `wait_ms` 1938 → frame당 실행 3.2ms, 대기 3.2ms로 정확히 50:50. 4ms 작업이 6.4ms로 늘어난 이유는, 선점당한 사이에 끝나야 할 시각이 지나고 CPU를 다시 받은 뒤에야 끝난 것을 알아차리기 때문이다.
3. **CFS → EEVDF**
   - vruntime(가상 실행 시간) = 실제 실행 시간 × 1024 / weight의 누적값. weight가 작으면 같은 시간을 써도 빨리 늘어난다.
   - CFS (~6.5): vruntime이 가장 작은 task를 실행한다.
   - EEVDF (6.6~, 이 PC의 7.0도 해당):
     - lag = 받아야 할 몫 − 실제로 받은 몫. lag ≥ 0인 task만 실행 후보.
     - 후보 중 가상 deadline(받은 몫 + slice ÷ weight)이 가장 이른 task를 고른다.
     - 자다 깬 renderer는 몫을 덜 받아 lag이 양수 → 깨어나자마자 후보가 되고 indexer를 선점할 수 있다.
     - slice 기본값 = 0.75ms × (1 + log₂ CPU 수) → CPU 8개면 약 3ms (기본 scaling 설정 기준).
4. **tick(HZ)이 지연을 좌우하는 이유**: task를 바꿀지 확인하는 시점은 ① wakeup 순간(우선이면 즉시 선점) ② tick마다(현재 task가 slice를 다 썼는지). ①에서 선점되지 않으면 다음 tick까지 기다린다.

   | | 강의 환경 | 이 PC |
   | --- | --- | --- |
   | HZ | 250 → tick 4ms | **1000 → tick 1ms** |
   | 예상 최대 wakeup 지연 | 수 ms (tick + 남은 slice) | 1ms 안팎 |

   - 강의 문장 "indexer의 slice가 끝날 때까지 수 ms 기다릴 수 있다" = ①에서 선점하지 못하고 4ms tick에서 slice 소진이 확인될 때까지 기다리는 경우.
   - 이 PC에서 `late_p99u`가 71µs인 것은 1ms tick과 EEVDF의 즉시 선점 때문으로 해석된다. 대신 일하는 도중에 slice 단위로 indexer와 번갈아 실행돼 지연이 `wait_ms`(frame당 3.2ms)로 나타났다. → 단계 2 perf sched timehist로 실제 선점 시점을 확인할 것.

**Q. nice별 weight는 kernel scheduler에 정의된 값인가?**

그렇다. `kernel/sched/core.c`의 `sched_prio_to_weight[40]`에 고정값으로 정의돼 있다.

```c
const int sched_prio_to_weight[40] = {
 /* -20 */ 88761, 71755, 56483, 46273, 36291,
 /* -15 */ 29154, 23254, 18705, 14949, 11916,
 /* -10 */  9548,  7620,  6100,  4904,  3906,
 /*  -5 */  3121,  2501,  1991,  1586,  1277,
 /*   0 */  1024,   820,   655,   526,   423,
 /*   5 */   335,   272,   215,   172,   137,
 /*  10 */   110,    87,    70,    56,    45,
 /*  15 */    36,    29,    23,    18,    15,
};
```

- 이웃 값끼리 약 1.25배 → 경쟁하는 둘 중 한쪽 nice를 1 올리면 그쪽 CPU 시간이 **약 11% 감소**(상대값). 몫으로는 50% → 44.5%, 5.5%p 감소 (아래 Q 계산 참고).
- `sched_prio_to_wmult[]` = 2³² / weight. 나눗셈 대신 곱셈으로 계산하려고 미리 구해 둔 역수.
- cgroup `cpu.weight`(1~10000, 기본 100)도 내부에서 이 체계로 변환된다 (100 ↔ 1024).

**Q. "renderer 약 20%, indexer 약 86%"는 왜 합이 100이 아닌가?**

두 값의 기준 시간이 달랐다 (처음 설명의 오류).

| | cpu_ms | 기준 시간 | 비율 |
| --- | ---: | --- | ---: |
| renderer | 1936 | 실행 시간 10초 | 19.4% |
| indexer | 12037 | 실행 시간 **14초** | 86% |

- indexer는 renderer보다 1초 먼저 시작, 3초 늦게 종료 → 약 4초는 혼자 CPU 사용.
- 같이 돈 10초 구간 계산:

```
시간(s)   0      1                              11          14
indexer   |======|==============================|===========|   14초
renderer         |==============================|              10초 (1초 뒤 시작)
          혼자   |←      둘이 같이 돈 10초      →|   혼자
          약1초                                    약3초
```

  1. indexer 혼자 = 약 1 + 3 = 4초 → CPU 0 단독 사용이므로 약 4000ms로 가정
  2. 같이 돈 10초 동안 indexer = 12037 − 4000 = 8037ms
  3. 같은 10초 동안 renderer = 1936ms
  4. 합계 9973ms = 10000ms의 99.7% → CPU 0을 둘이 빈틈없이 나눠 썼다

  | 같이 돈 10초 | 계산 | 비율 |
  | --- | --- | ---: |
  | renderer | 1936 / 10000 | **19.4%** |
  | indexer | 8037 / 10000 | **80.4%** |
  | 그 외 (다른 system task, 오차) | 27 / 10000 | 0.3% |

  "혼자 돈 4초 = 4000ms" 가정의 오차는 단계 2 perf timehist로 확인 가능.

**Q. "renderer 약 19%, indexer 약 81%"를 이론 계산과 실제 동작 시간으로 비교하면?**

앞의 계산은 "indexer가 혼자 돈 4초 = 4000ms" 가정이 있었다. 가정을 없애려고 **두 thread를 한 process에서 정확히 동시에 시작해 10초간** 다시 측정했다 (3회, `logs/lab3-pair-overlap.txt`).

```bash
./bin/mtwork -d 10 -n pair busy,cpu=0 periodic:16667:4000,cpu=0   # thread 0 = indexer, 1 = renderer
```

**실제 동작 시간**

| run | indexer cpu_ms | renderer cpu_ms | 합계 | renderer wait_ms | indexer wait_ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1 | 8079.2 | 1910.5 | 9989.6 | 1899.3 | 1921.7 |
| 2 | 8076.0 | 1912.8 | 9988.8 | 1911.3 | 1924.0 |
| 3 | 8093.4 | 1897.2 | 9990.5 | 1886.3 | 1906.7 |
| **평균** | **8082.9 (80.8%)** | **1906.8 (19.1%)** | 9989.6 (99.9%) | 1899.0 | 1917.5 |

- 합계 99.9% → CPU 0을 둘이 빈틈없이 나눠 씀. 나머지 0.1%는 kernel thread와 interrupt.
- indexer의 wait(1917ms) ≈ renderer의 실행(1907ms) → renderer가 도는 동안 indexer는 정확히 기다렸다. 서로 맞물린다.
- frame당: renderer 실행 1906.8 / 600 = **3.18ms**, 대기 1899.0 / 600 = **3.17ms** → runnable 구간 **6.35ms** (16.667ms의 38.1%).

**이론 모델과 비교**

| 모델 | 가정 | renderer | indexer | 실측과 차이 (renderer) |
| --- | --- | ---: | ---: | ---: |
| A. 필요량 그대로 | renderer는 4ms/16.667ms만 쓴다 | 24.0% | 76.0% | +4.9%p |
| B. 항상 50:50 | 자는 시간 무시 | 50.0% | 50.0% | +30.9%p |
| **C. slice 모델 (원리만으로)** | slice 3ms, 벽시계 4ms 작업 | **18.0%** | **82.0%** | **−1.1%p** |
| (이전) 4초 가정 역산 | indexer 혼자 4초 = 4000ms | 19.4% | 80.4% | +0.3%p |
| **실측** | 정확히 10초 동시 실행 | **19.1%** | **80.8%** | - |

C. slice 모델 계산 (frame 하나, 측정값 없이 원리만 사용):

```
t=0~3   renderer 실행 (slice 3ms)
t=3~6   indexer 실행 (slice 3ms), renderer 대기   ← t=4 지나감
t=6     renderer 복귀 → 이미 4ms 지남 → 바로 종료 (≈0)
renderer 실행 = 3ms / 16.667ms = 18.0%
indexer       = 100% − 18.0%   = 82.0%
runnable 구간  = 6ms (36.0%)
```

**C와 실측의 차이 (frame당 약 0.18ms)**

| | C 모델 | 실측 | 차이 |
| --- | ---: | ---: | ---: |
| renderer 실행 | 3.00ms | 3.18ms | +0.18 |
| renderer 대기 (= indexer 1회 실행) | 3.00ms | 3.17ms | +0.17 |
| runnable 구간 | 6.00ms | 6.35ms | +0.35 |

- 실행과 대기가 **모두** 약 0.17~0.18ms 길다 → slice가 정확히 3ms에서 끊기지 않고 조금 넘어서 교체되는 것으로 보인다 (slice 소진 확인 시점의 지연 추정).
- renderer는 복귀 후 종료 처리(마지막 계산 묶음, `now_ns()` 확인, sleep 진입)에 시간이 조금 더 든다.
- 확인 방법: `base_slice_ns` 실제 값, 단계 2 perf sched timehist의 연속 실행 시간.

**참고: 이번 측정의 late_p99u는 578~902µs** (이전 별도 process 실행 때 71µs). 같은 조건인데 깨어남 지연이 커졌다. 원인은 미확인 → perf sched timehist로 확인할 항목에 추가.

**Q. 4ms 작업이 6.4ms로 늘어난 것은 어떻게 결정됐나? slice 3ms의 영향인가?**

6.4ms는 평균을 역산한 값이다: 실행 1936ms ÷ 600 = 3.2ms, 대기 1938ms ÷ 600 = 3.2ms → frame당 약 6.4ms. slice 약 3ms로 설명하면 (**추정**):

```
t=0     renderer 깨어남 → lag 양수라 즉시 실행 (late ≈ 0)
t≈3ms   renderer가 slice 소진 → indexer 차례                 [renderer 실행 ≈ 3ms]
t=4ms   renderer의 "4ms 끝" 시각이 지나지만 CPU가 없어 모름
t≈6ms   indexer가 slice 소진 → renderer가 CPU를 다시 받음     [renderer 대기 ≈ 3ms]
        now_ns() 확인 → 이미 지났으므로 종료 → 잠듦          [추가 실행 ≈ 0.2ms]
```

- 실행 ≈ slice 3ms + 마지막 확인 0.2ms = 3.2ms, 대기 ≈ indexer의 slice 3ms.
- 늘어난 2.4ms = indexer의 slice 한 번에서 이미 지나간 시간을 빼고 남은 만큼. **slice 길이가 frame 지연의 크기를 정한다.** slice가 1ms였다면 늘어나는 시간도 1ms 안팎.
- 검증 방법:
  - 실제 slice 값: `sudo cat /sys/kernel/debug/sched/base_slice_ns /sys/kernel/debug/sched/preempt`
  - 단계 2 perf sched timehist에서 renderer와 indexer가 번갈아 실행된 시간 확인

**Q. weight가 1.25배 차이인데 왜 "약 10%"인가? (계산)**

```
weight:  nice 0 = 1024,  nice 1 = 820     (1024 / 820 = 1.249 ≈ 1.25배)
nice 0 몫 = 1024 / 1844 = 55.5%
nice 1 몫 =  820 / 1844 = 44.5%
```

| 비교 방법 | 값 |
| --- | --- |
| nice를 올린 task의 몫 변화 | 50% → 44.5% = **5.5%p 감소** |
| 그 task 자신의 CPU 시간 기준 | 44.5 / 50 = 0.89 → **약 11% 감소** |
| 두 task 사이의 차이 | 55.5 − 44.5 = **11%p** |

- kernel 주석의 "nice 1단계 = 약 10%"는 **자기 CPU 시간이 약 10% 줄어든다**(상대적 감소)는 뜻이다. "10%p 감소"는 틀린 표현이었다.
- 1.25를 고른 이유: 비율이 r이면 내 몫 = 1/(1+r). r = 1.25 → 0.444, 즉 한 단계에 약 10%씩 줄어들게 설계.
- 조치 A(nice 10): indexer = 110 / 1134 = 9.7%, renderer = 1024 / 1134 = 90.3%.

**Q. 쉬고 나온 renderer의 lag은? 깨어난 직후 CPU를 몰아서 쓰나?**

**EEVDF에서는 쉬는 동안 lag이 쌓이지 않는다. 깨어날 때 lag ≈ 0.** 몰아서 쓰지 않으며, 이것이 6.4ms를 뒷받침한다.

lag 규칙 (6.6 이상, 이 PC는 7.0):
- **잠들 때의 lag을 저장했다가 깨어날 때 돌려준다.** 자는 동안 "못 받은 몫"이 늘어나지 않는다.
- 저장되는 lag에는 상한이 있다: 대략 ± max(2 × slice, tick) ≈ 6ms (가상 시간).
- 잠들 때 lag이 음수(몫보다 더 씀)면, 6.12부터의 **delayed dequeue** 때문에 바로 runqueue에서 빠지지 않고 lag이 0으로 회복된 뒤 빠진다 → 음수 lag을 들고 깨어나지 않는다.

renderer가 잠들 때의 lag (slice 3ms, weight가 같은 두 task 기준):

```
                        renderer 실행   가상 시간 V    renderer lag
frame 시작 (깨어남)           0             0             0
renderer 3ms 실행           +3          +1.5          -1.5   (몫보다 더 씀)
indexer  3ms 실행            -          +1.5           0.0   (다시 0으로)
renderer 0.2ms 실행 후 잠듦  +0.2        +0.1          -0.1   → delayed dequeue로 0
```

(V = runqueue 전체의 가중 평균 진행도. 둘이 실행 중이면 한 task가 3ms 쓸 때 V는 1.5 진행.)

→ renderer는 lag ≈ 0으로 잠들고 lag ≈ 0으로 깨어난다. 12ms를 쉬어도 특별히 몫이 생기지 않는다.

- **6.4ms와 일치**: 깨어난 renderer는 보너스 없이 slice 하나(3ms)를 받고 indexer와 번갈아 실행 → 3.2 실행 + 3.2 대기 = 6.4ms.
- 몰아서 쓰는 보너스가 있었다면 renderer는 4ms를 끊김 없이 쓰고 frame도 4ms에 끝났을 것이다.
- 예전 CFS에는 **sleeper credit**(깨어난 task의 vruntime을 최소값보다 앞당겨 우선권 부여)이 있었다. EEVDF는 이를 없애고 lag 기반으로 바꿨다.
- **미해결**: lag 0이면 깨어난 renderer와 indexer의 deadline이 비슷해서 이론상 즉시 선점하지 못할 수도 있다. 그런데 `late_p99u` 71µs → 대부분 즉시 CPU를 받았다. kernel 7.0 scheduler 기능(즉시 선점 관련 옵션, 선점 방식) 때문일 가능성 → `sudo cat /sys/kernel/debug/sched/{base_slice_ns,preempt,features}`와 timehist로 확인할 것.

**Q. 가상 시간 계산식은?**

`kernel/sched/fair.c` 기준 (w = weight, nice 0 = 1024, Δexec = 실제 실행 시간):

| 값 | 계산식 | 의미 | kernel |
| --- | --- | --- | --- |
| task의 가상 실행 시간 v_i | v_i += Δexec × 1024 / w_i | weight가 작을수록 빨리 늘어남 | `calc_delta_fair()` |
| runqueue 가상 시간 V | V = Σ(w_i × v_i) / Σw_i | runnable task들의 v를 weight로 가중평균 | `avg_vruntime()` |
| lag | lag_i = w_i × (V − v_i) | 0보다 크면 몫을 덜 받은 상태 | `se->vlag` (= V − v_i) |
| 가상 deadline | vd_i = v_i + slice × 1024 / w_i | 후보 중 가장 이른 task 실행 | `update_deadline()` |

- 실행 후보 조건: lag ≥ 0 ⇔ v_i ≤ V
- V의 진행 속도: 실행 중인 task의 v가 Δ만큼 늘면 ΔV = w_cur × Δv_cur / Σw. weight가 같은 task n개면 ΔV = Δ/n.
  - 앞의 lag 표에서 renderer 3ms 실행 → V +1.5인 이유 (n = 2).
  - task가 하나뿐이면 V = 그 task의 v → lag은 항상 0.

**Q. renderer는 75%는 쉬고, 25%를 놓고 50:50으로 경쟁한 것인가?**

개념은 맞다: **runnable 구간에서만 경쟁하고, 그 안에서는 50:50.** 다만 구간 길이가 25%가 아니다. 경쟁 때문에 일하는 구간이 4ms에서 6.4ms로 늘어났다.

| frame 하나 (16.67ms) | 의도 (경쟁 없음) | 실제 (경쟁) |
| --- | --- | --- |
| runnable 구간 | 4ms (24%) | **6.4ms (38%)** |
| └ renderer 실행 | 4ms | 3.2ms (50%) |
| └ indexer 실행 | 0 | 3.2ms (50%) |
| 잠든 구간 (indexer 혼자) | 12.67ms (76%) | **10.27ms (62%)** |

모델 검증:

```
renderer = 38% × 50%         = 19.2%   (실측 19.4%)
indexer  = 38% × 50% + 62%   = 81.2%   (실측 80.4%)
```

- 정리: renderer는 frame마다 6.4ms 동안 runnable(= 실행 3.2ms + runqueue 대기 3.2ms)이었고, 그 구간을 indexer와 50:50으로 나눴다. 나머지 62%는 잠들어 있었고 그동안 indexer가 CPU를 혼자 썼다.
- 작업이 "CPU 시간 4ms만큼의 일"(실제 decode/render에 가까움)이었다면, 50:50으로 4ms를 채우는 데 8ms가 걸려 runnable 구간이 48%가 되고, frame 작업 시간도 두 배가 됐을 것이다.

**Q. "6.4ms 동안 runnable"이 아니라, 3.2 실행 + 3.2 대기 후 4ms를 채우기 위해 남은 시간을 더 실행해야 하지 않나?**

아니다. 6.4ms 안에 실행과 대기가 이미 모두 들어 있고, 남은 시간을 채우지 않는다.

1. **runnable = 실행 중 + 대기 중**: Linux의 runnable(`TASK_RUNNING`)은 CPU에서 실행 중(exec)과 runqueue에서 CPU를 기다리는 중(wait)을 함께 가리킨다. sleeping과 구분하는 말이다. → 6.4ms = exec 3.2 + wait 3.2.
2. **`work_item`은 벽시계 기준 4ms**: "CPU를 4ms 쓸 때까지"가 아니라 "시작 시각부터 4ms가 지날 때까지".

   ```c
   end = now_ns() + 4ms;                        // 끝나는 시각을 벽시계로 먼저 정함
   do { ...계산... } while (now_ns() < end);    // 지금 시각만 비교
   ```

   ```
   t=0      시작, end = 4ms로 정해짐
   t=0~3    renderer 실행 (≈3ms)
   t=3~6.2  indexer 실행, renderer 대기 (≈3.2ms)  ← 이 사이에 t=4가 지나감
   t=6.2    renderer가 CPU를 다시 받음 → now_ns() ≥ end → loop 즉시 종료
   t=6.4    잠듦 (마지막 계산 묶음 + 종료 처리 ≈0.2ms)
   ```

   frame당 exec 3.2ms = 앞의 3ms + 마지막 0.2ms. 남은 0.8ms는 채우지 않는다.
3. **측정값으로 확인**

   | | frame당 CPU 시간 | 600 frame 합계 |
   | --- | ---: | ---: |
   | CPU 4ms를 채우는 구조였다면 | 4.0 ms | 2400 ms |
   | **실측 `cpu_ms`** | **3.2 ms** | **1936 ms** |

   frame마다 약 0.8ms씩 덜 실행 → 벽시계 기준으로 끊긴다는 증거. (단독 실행은 선점이 없어 2422ms ≈ frame당 4ms.)
4. **질문한 구조는 실제 플레이어의 경우**: "CPU 4ms만큼의 일을 다 해야 끝나는" decode/render라면 `0~3 실행 → 3~6 대기 → 6~7 남은 1ms 실행 → 끝` (frame 작업 7ms 이상). → 고정 작업량 버전 renderer를 추가해 비교하면 확인 가능.

**Q. cgroup의 그룹은 미리 정의돼 weight도 정해져 있나? 런타임에 특정 thread를 특정 그룹에 할당하나?**

둘 다 런타임이다. **그룹 생성, weight 설정, thread 배치 모두 실행 중에 파일을 쓰는 것으로 처리되고, 언제든 바꿀 수 있다.** 미리 정의된 것처럼 보이는 그룹은 부팅 시 systemd 같은 관리자가 만든 것이다.

1. **cgroup = 파일시스템**: `/sys/fs/cgroup` 아래 디렉터리 하나가 그룹 하나, 그 안의 파일이 설정값.

   | 하는 일 | 방법 | 이번 실습 (`tools/fixcg.sh`) |
   | --- | --- | --- |
   | 그룹 만들기 | `mkdir` | `mkdir -p /sys/fs/cgroup/lab/fg /sys/fs/cgroup/lab/bg` |
   | controller 켜기 | 부모의 `cgroup.subtree_control`에 쓰기 | `echo "+cpu +cpuset" > lab/cgroup.subtree_control` |
   | weight | `cpu.weight` | `echo 20 > lab/bg/cpu.weight` |
   | 상한 | `cpu.max` | `echo "30000 100000" > lab/bg/cpu.max` |
   | 쓸 CPU 제한 | `cpuset.cpus` | `echo 1 > lab/bg/cpuset.cpus` |
   | 삭제 | `rmdir` (process가 없어야 함) | `teardown` |

   설정값은 task가 도는 중에도 바꿀 수 있고 바로 적용된다 (단계 5의 `setup 100` → `max`).

2. **thread를 그룹에 넣기**

   | 단위 | 방법 | 이번 실습 (`src/mtwork.c`) |
   | --- | --- | --- |
   | process 전체 | `cgroup.procs`에 **PID** → 모든 thread 이동 | `-c lab/bg`: 시작할 때 자기 PID를 씀 (L334) |
   | thread 하나 | `cgroup.threads`에 **TID** | `cg=NAME`: thread가 자기 TID를 씀 (L235) |

   - fork하면 자식은 부모의 cgroup을 물려받는다 → 서비스 process 하나만 넣으면 그 thread와 자식도 같은 그룹.
   - cgroup v2는 기본이 **process 단위**다. thread별로 다른 그룹에 넣으려면 하위 트리를 `cgroup.type = threaded`로 바꿔야 하고, 이 모드에서는 cpu, cpuset 등 일부 controller만 쓸 수 있다. v1은 controller별 `tasks` 파일에 TID를 써서 thread 단위가 자유로웠다.

3. **실제 시스템에서 누가 정하나**
   - 이 PC: `cat /proc/self/cgroup` → `0::/user.slice/user-1000.slice/user@1000.service/app.slice/ptyxis-spawn-....scope`
   - **systemd**: 부팅 시 `system.slice`, `user.slice` 등을 만들고 서비스마다 그룹을 만든다. weight는 unit 파일의 `CPUWeight=`, `CPUQuota=`, `AllowedCPUs=` (이 PC는 미설정 → 기본 100). 런타임 변경: `systemctl set-property <unit> CPUWeight=20`.
   - **플랫폼 관리자**: 앱 상태에 따라 런타임에 옮긴다. 예: Android는 foreground/background 전환 시 thread를 다른 cgroup(cpuset 등)으로 이동.

4. **webOS 플레이어 적용**
   - 먼저 player가 어느 그룹에 있고 어떤 제한이 걸려 있는지 확인: `cat /proc/<player_pid>/cgroup` → 그 경로의 `cpu.weight`, `cpu.max`.
   - 이슈 원인이 player 코드가 아니라 그룹 설정일 수도 있다 (예: background로 분류돼 `cpu.max`에 걸림).
   - webOS의 cgroup 구성 방식(systemd unit인지, 별도 관리자인지)은 버전·플랫폼마다 다르므로 실제 보드에서 확인할 것. (→ 보드 특성 체크리스트 3번 "player의 cgroup과 제한")

**Q. Android는 HAL 아래에서 도는 vsync 기반 BSP thread의 우선순위를 특별 관리하나? 아니면 SoC 의존이라 플랫폼은 관여하지 않고 SoC 벤더가 nice/cgroup 값을 가이드하나?**

> Android 구조에 대한 일반 지식 기반 설명. 세부 값·파일명은 Android 버전과 SoC마다 다르므로 실제 적용 시 해당 소스·문서로 확인할 것.

플랫폼이 관여하지 않는 것은 아니다. **BSP thread 하나하나의 nice 값을 플랫폼이 정하지는 않고, 정하는 틀과 결과 기준을 제공한다.**

1. **역할 분담**

   | 계층 | 정하는 것 |
   | --- | --- |
   | 플랫폼 (Google, AOSP) | 틀(cgroup 분류, task profile, Power HAL 인터페이스), framework thread 우선순위, 성능 요구사항(CTS/CDD) |
   | SoC 벤더 (Qualcomm, MediaTek 등) | HAL process·thread 우선순위, 자체 성능 관리 HAL/daemon, kernel scheduler 확장 |
   | 제조사 (OEM) | SoC 벤더 설정을 제품에 맞게 조정 |

2. **플랫폼이 직접 챙기는 것**
   - framework thread 우선순위를 코드로 고정: SurfaceFlinger main thread는 시작 시 스스로 `SCHED_FIFO`. 앱 UI thread와 RenderThread는 nice 음수(display 우선순위). 오디오 FastMixer 등 저지연 thread는 `SCHED_FIFO` (framework의 스케줄링 정책 서비스가 대신 설정).
   - cgroup 분류(top-app, foreground, background 등)를 정의하고, 앱이 앞뒤로 전환될 때 ActivityManager가 process를 옮긴다. 그룹마다 cpuset과 uclamp가 걸려 있다.
   - **task profile** (Android 10+): `cgroups.json`, `task_profiles.json`에 "HighPerformance", "ProcessCapacityHigh" 같은 프로필("어느 cgroup에 어떤 값") 정의 → init rc에서 `task_profiles <이름>`으로 적용. 벤더는 `/vendor/etc/task_profiles.json`으로 덮어쓸 수 있다.
   - **결과 기준**: CDD, CTS, Media Performance Class는 "nice 몇"이 아니라 "frame drop 몇 개 이하", "오디오 지연 몇 ms 이하" 같은 결과를 요구한다.

3. **벤더 BSP thread는 벤더가 이 틀 안에서 관리**
   - HAL process는 벤더 init rc로 시작되고, 여기서 우선순위를 정한다.

     ```
     service vendor.media.c2 /vendor/bin/hw/...-service
         class hal
         user mediacodec
         task_profiles ProcessCapacityHigh     # cgroup/성능 프로필
         capabilities SYS_NICE                 # 스스로 우선순위를 올릴 권한
         rlimit rtprio 10 10                   # SCHED_FIFO 우선순위 상한
     ```

     개별 thread는 HAL 코드가 직접 `setpriority`/`sched_setscheduler`로 올린다 (예: composer HAL의 vsync thread는 보통 `SCHED_FIFO`).
   - SoC 벤더 성능 관리 HAL(Qualcomm perf HAL, MediaTek power/perf 서비스 등): "영상 재생 중" 같은 hint를 받으면 CPU 주파수, uclamp, core 배치를 동적으로 조정.
   - **ADPF** (Android 12+, Android Dynamic Performance Framework): thread 묶음의 frame당 목표 시간과 실제 시간을 Power HAL에 보고 → 성능 보장을 동적으로 조정. renderer 같은 thread를 위한 메커니즘.
   - kernel scheduler 확장: Qualcomm WALT 등.
   - SoC 벤더의 BSP thread nice/cgroup 가이드는 BSP 릴리스·tuning 문서로 제조사에 전달되며 보통 비공개다.

4. **webOS 플레이어에서 확인할 질문** (webOS 내부 구조는 미확인)
   1. 플랫폼: media pipeline thread(demux, decode, render, audio)의 우선순위와 cgroup을 플랫폼 코드가 정하나, 기본값(nice 0)인가?
   2. SoC 벤더: 디코더·디스플레이 BSP thread가 이미 `SCHED_FIFO`인가? 그렇다면 플랫폼 thread는 nice 조정만으로 그 thread를 이길 수 없다 (RT가 일반 thread보다 항상 먼저 실행).
   3. 동적 조정: 재생 시작 시 CPU 주파수나 core 배치를 올려 주는 장치(Power HAL류)가 있나?
   - 첫 확인: 재생 중 `ps -eLo tid,cls,rtprio,ni,psr,comm` (정책 TS/FF/RR, RT 우선순위, nice, 실행 CPU)

**Q. Android에서 framework로부터 buffer를 받는 SoC 벤더 렌더러 thread의 우선순위는 누가 정하나? 벤더가 스스로 정하나?**

> Android 구조에 대한 일반 지식 기반 설명. 버전마다 세부가 다를 수 있음.

기본적으로 **벤더가 스스로 정한다.** 단, 플랫폼이 정한 권한 범위 안에서만 가능하고, IPC를 통해 플랫폼 thread의 우선순위가 넘어오는 경로도 있다.

1. **영상 frame 경로와 담당**

   ```
   앱 (MediaCodec 호출)
    → Codec2 HAL            [벤더] 디코더, HW 디코더 제어 thread
    → BufferQueue (Surface)  [플랫폼] buffer 전달 통로
    → SurfaceFlinger         [플랫폼] 화면 합성, main thread SCHED_FIFO
    → Composer HAL (HWC)     [벤더] 디스플레이 HW에 레이어를 올리는 "렌더러"
    → display driver         [벤더] kernel DRM/KMS
   ```

2. **우선순위가 정해지는 세 경로**
   - **① 벤더 코드가 직접 설정**: Composer HAL은 시작 시 자기 thread를 `SCHED_FIFO`로 올린다. AOSP 참고 구현에도 이 코드가 있고, 벤더는 보통 이를 기반으로 만든다. 내부 vsync thread 등도 벤더 코드가 정한다.
   - **② 플랫폼이 허용 범위를 제한**: init rc의 `rlimit rtprio`(RT 우선순위 상한), `capabilities SYS_NICE`(스스로 올릴 권한), SELinux의 `sys_nice` 권한, task profile(cgroup).
   - **③ binder 우선순위 상속**: SurfaceFlinger가 Composer HAL을 binder로 호출하면, 요청을 처리하는 HAL thread가 호출자의 우선순위를 물려받는다. RT 우선순위 상속도 지원한다(서비스가 해당 객체에 RT 상속을 설정). → victim의 우선순위가 IPC를 따라 다음 단계로 전달되어, 파이프라인 중간에서 우선순위가 끊기지 않게 한다.

3. **TV에서 중요한 경우: tunneled playback**
   - Android TV는 영상 재생에 tunneled mode를 자주 쓴다 (Netflix 등도 TV에서 사용하는 것으로 알려짐).
   - 디코더 출력이 SurfaceFlinger를 거치지 않고 SoC 비디오 HW 경로로 바로 디스플레이에 간다. A/V sync와 frame 출력 타이밍도 벤더 비디오 파이프라인(HW + BSP)이 처리한다.

   | 재생 방식 | frame 타이밍을 좌우하는 것 | 우선순위 결정 |
   | --- | --- | --- |
   | 일반 재생 (SF 합성) | SurfaceFlinger + Composer HAL | 플랫폼(SF) + 벤더(HAL), binder 상속으로 연결 |
   | tunneled 재생 | SoC 비디오 파이프라인 | 거의 전적으로 벤더 |

4. **webOS 플레이어 적용**
   - TV SoC는 대부분 디코더 → 비디오 plane HW 경로가 있어 frame 타이밍의 상당 부분이 BSP에 있을 가능성이 크다 → webOS 파이프라인 구조 확인.
   - **IPC 경계에서 우선순위가 이어지는지** 확인: 플레이어 thread가 높아도 IPC 요청을 처리하는 서비스 thread가 nice 0이면 그 지점에서 지연이 생긴다.
   - perf sched timehist로 플레이어가 응답을 기다리는 동안 처리 쪽 thread가 runqueue에서 대기했는지 확인 가능.

**Q. Android 기준으로 tunneled 재생에 대해 벤더에 어떤 가이드가 전달되고, 실제로 어떻게 최종 적용되나?**

> 조사 출처: AOSP 문서, CTS 소스, Netflix 파트너 문서(이 계정으로 열람 가능한 Linux NRDP 영역만. Android TV 영역은 열람 불가). 2026-10-07 확인.

**결론: 벤더가 받는 가이드는 "구현할 인터페이스"와 "내야 할 결과"다. thread 우선순위 같은 스케줄링 방법은 공개 문서에 없고 벤더 구현 영역으로 남아 있다.**

1. **Google → 벤더: 인터페이스 규격** ([AOSP Multimedia tunneling](https://source.android.com/docs/devices/tv/multimedia-tunneling))
   - 정의: 압축 영상이 앱 코드나 framework를 거치지 않고 HW 디코더를 지나 디스플레이로 바로 간다. frame 출력 타이밍은 Android 아래 벤더 코드가 관리한다.

   | 영역 | 구현 내용 |
   | --- | --- |
   | 디코더 선언 | `media_codecs.xml`에 `<Feature name="tunneled-playback" .../>` |
   | tunnel 모드 설정 | Codec2 `C2PortTunneledModeTuning` / OMX `configureVideoTunnelMode` |
   | 디스플레이 연결 | 디코더가 **sideband handle** 생성·반환(`C2PortTunnelHandleTuning`). HWC가 이 handle로 디코더 출력을 받아 **오디오 출력이나 tuner 시계에 맞춰** 화면에 올림 |
   | A/V sync | `HW_AV_SYNC` ID 지원, 오디오 sync header의 timestamp 해석 |
   | 첫 frame 제어 | peek(재생 전 첫 frame 표시 여부), `TUNNEL_HOLD_RENDER` / `TUNNEL_START_RENDER` |
   | buffer | tunneled 디코더 출력 buffer 수 0 (출력이 앱으로 오지 않음) |

   - **thread 우선순위·CPU 스케줄링 언급 없음.**

2. **Google의 확인: CTS** ([DecoderTest.java](https://android.googlesource.com/platform/cts/+/99d04a0f920/tests/tests/media/decoder/src/android/media/decoder/cts/DecoderTest.java))
   - `testTunneledVideoPeekOff*`, `testTunneledAccurateVideoFlush*` 등 tunneled 전용 테스트.
   - 타이밍 결과를 검사: 일시정지 시 오디오는 250ms 안에 멈춰야 하고, 비디오는 파이프라인이 깊어 오디오 정지 후 500ms까지 진행 허용.

3. **앱 파트너의 확인: Netflix 인증** (Linux NRDP 문서)
   - [Playback Platform Metrics](https://docs.netflixpartners.com/nrdp/documentation/capabilities/playback-platform-metrics): NRDP 2025.1부터 **REQUIRED**. frame drop, freeze, 오디오 끊김, 디코드 오류를 MultiPlayer DPI로 보고. 자동 인증 테스트 있음.
   - [CPU Requirements](https://docs.netflixpartners.com/nrdp/documentation/device-requirements/cpu): quad-core 12,500 DMIPS 이상 (6.1.2+ 13,500 권장).
   - [ThreadConfiguration DPI](https://docs.netflixpartners.com/nrdp/documentation/dpis/system/threadconfiguration): NRDP 6.1.2 추가(`InterfaceEGLDriver.h`). 문서 본문은 비어 있음 → SDK 헤더나 Partner Engineer로 확인 필요.
   - webOS의 Netflix는 Linux NRDP 계열이라 Android 문서보다 이쪽이 실무와 더 직접적일 가능성이 크다.

4. **최종 적용 흐름** (문서 기반 정리 + 추론)

   ```
   ① Google: 인터페이스 규격(AOSP 문서) + 결과 검사(CTS)
   ② SoC 벤더: BSP 구현 (tunneled 디코더, HWC sideband, 오디오 HAL HW A/V sync)
      - 내부 thread 구성·우선순위(SCHED_FIFO 여부 등)는 벤더 결정   ← 문서에 없음 (추론)
   ③ OEM: 통합·tuning, CTS 통과
   ④ 앱 파트너(Netflix 등): 자체 인증으로 결과 검증 (frame drop, A/V sync, 재생 시작 시간)
      → 기준 미달이면 OEM·SoC 벤더가 BSP 수정
   ```

   - ①④는 결과만 규정하고, 달성 방법(thread 우선순위, HW 큐 깊이, 인터럽트 처리)은 ②의 구현 영역 → 공개 문서에는 나오지 않는다 (추론).

5. **webOS 플레이어 관점**
   - tunneled 구조에서 frame 타이밍의 대부분은 BSP와 HW가 좌우한다. 플랫폼 플레이어가 볼 thread는 주로 앞단: demux, DRM 복호화, 디코더 입력(feeding), 오디오 출력.
   - 이번 실습의 renderer/indexer 구도가 앞단 thread에서 그대로 재현된다: feeding thread가 백그라운드 작업에 밀리면 디코더 입력이 바닥나고(underflow) frame drop으로 이어진다.
   - Netflix 인증에서 Playback Platform Metrics로 frame drop이 보고되면 → schedstat 대기 시간 → perf sched → 조치 비교 순으로 원인을 좁힌다.

**Q. slice는 왜 그 값인가? (base slice 유도 공식) — 그리고 이 PC의 slice 정정**

`kernel/sched/fair.c`의 `update_sysctl()`:

```
base_slice = normalized_base x factor
factor (tunable_scaling): 0 NONE = 1
                          1 LOG  = 1 + log2(min(online CPU 수, 8))   <- 기본값
                          2 LINEAR = min(online CPU 수, 8)
normalized_base: 0.75ms (6.6 도입 시), 이 PC의 kernel 7.0에서는 0.70ms
```

- CPU가 많을수록 slice를 길게 → CPU당 경쟁이 줄어드는 만큼 task 교체 비용을 줄이려는 설계. CPU hotplug 때 다시 계산되고, debugfs에 직접 쓰면 공식과 달라진다.
- 예: CPU 4개, LOG → factor 3 → 0.75 × 3 = **2.25ms**

**정정 (이 PC)**: 앞의 Q&A들은 slice를 0.75 × 4 = 3ms로 가정했다. 그런데 `/proc/self/sched`의 `se.slice`를 읽어 보니 **2.8ms** = 0.70 × 4 였다. kernel 7.0에서 기준값이 0.70ms로 바뀐 것으로 보인다.
- 실측 연속 실행 3.17ms와 비교하면: slice 2.8ms가 끝나도 tick(1ms) 경계에서 교체되므로 실제 연속 실행 = 2.8ms를 1ms 단위로 올린 **약 3ms** + 교체 처리 → 3.17ms. "3ms slice" 가정보다 이 설명이 더 정확하다.
- 앞의 "6.4ms" 분석의 결론(slice 1회분만큼 밀린다)은 그대로 유효하고, 숫자의 근거만 "slice 3ms" → "slice 2.8ms가 tick 단위로 올림된 약 3ms"로 바뀐다.

**실제 연속 실행 시간 = slice를 tick 단위로 올림** (HRTICK이 꺼져 있을 때): slice 끝을 정확한 타이머로 끊지 않고 tick마다 확인하기 때문이다.

| | base slice | tick | 예상 연속 실행 |
| --- | ---: | ---: | ---: |
| 이 PC (HZ 1000) | 2.8ms | 1ms | 약 3ms (실측 3.17ms) |
| HZ 250 환경 예 | 2.25ms | 4ms | 약 4ms |

→ `study/sched_profile/sched_profile.sh` 섹션 2에서 이 유도를 자동으로 계산한다 (root 없이도 `se.slice`로 가능).

## 현업 적용 포인트 (webOS 미디어 플레이어)

- **CPU 사용률이 아니라 schedstat의 `wait_ms`(runqueue 대기)와 비자발적 context switch를 본다.** renderer는 CPU의 20%만 쓰는데도 frame마다 3ms씩 대기했다. `top`으로는 보이지 않는다.
  - 운영 장비에서 바로 확인: `cat /proc/<pid>/task/<tid>/schedstat` (실행 ns, 대기 ns, 횟수), `grep ctxt /proc/<pid>/task/<tid>/status`
- **CPU 절전도 지연 원인이 된다.** 주기적으로 깨어나는 player thread가 idle CPU에서 돌면 C-state 탈출과 저주파수 때문에 수백 µs 늦어질 수 있다. 측정할 때 governor, 주파수, C-state 설정을 함께 기록한다.

### 실제 디바이스에서 먼저 파악할 보드 특성 체크리스트

> nice별 weight 표(`sched_prio_to_weight`)는 kernel 2.6.23(CFS 도입)부터 동일하다. 보드·kernel마다 달라지는 것은 scheduler 알고리즘, slice 관련 값, tick, CPU 구성이다.

**1. kernel과 scheduler**

| 항목 | 확인 방법 | 왜 중요한가 |
| --- | --- | --- |
| kernel 버전 | `uname -r` | 6.6 미만 CFS, 이상 EEVDF. 깨어날 때 우선권, slice 개념이 다름 |
| HZ | `CONFIG_HZ` (`/boot/config-*`, `/proc/config.gz`) | tick 간격 = 선점 확인의 최소 단위 (100/250/1000) |
| preempt 방식 | `CONFIG_PREEMPT*`, `uname -v` | kernel 코드 실행 중 선점 가능 여부 |
| slice 관련 값 | CFS: `sched_latency_ns`, `sched_min_granularity_ns`, `sched_wakeup_granularity_ns` / EEVDF: `base_slice_ns` | 경쟁 시 frame 지연 크기 결정 (실습의 6.4ms) |

- 5.13부터 slice 관련 값 위치가 `/proc/sys/kernel/sched_*` → `/sys/kernel/debug/sched/`로 바뀌었다.
- CFS는 깨어난 task에 **sleeper credit**을 주고, `wakeup_granularity`보다 vruntime 차이가 클 때만 즉시 선점한다 → 같은 player 코드라도 kernel 버전에 따라 지연 양상이 다르다.

**2. CPU 구성과 전력 관리** (TV SoC는 대부분 ARM)

| 항목 | 확인 방법 | 왜 중요한가 |
| --- | --- | --- |
| core 구성 | `lscpu`, `/proc/cpuinfo`, `/sys/devices/system/cpu/cpu*/cpu_capacity` | big.LITTLE이면 core에 따라 같은 작업도 2~3배 차이 |
| cache | `/sys/devices/system/cpu/cpu0/cache/index*/size` | working set이 cache를 넘는 경계 (실습 1) |
| cpufreq governor | `/sys/devices/system/cpu/cpu*/cpufreq/{scaling_governor,scaling_cur_freq}` | 단독 실행 때 깨어남이 더 늦었던 원인 |
| cpuidle 상태 | `/sys/devices/system/cpu/cpu0/cpuidle/state*/{name,latency}` | 깊은 절전 상태일수록 깨어나는 데 오래 걸림 |
| EAS / uclamp | `CONFIG_ENERGY_MODEL`, `CONFIG_UCLAMP_TASK`, cgroup `cpu.uclamp.min` | 전력 효율 우선이면 player thread가 LITTLE core에 배치될 수 있음 |

**3. 자원 제어 설정**

| 항목 | 확인 방법 | 왜 중요한가 |
| --- | --- | --- |
| cgroup 버전 | `mount \| grep cgroup` | v1 `cpu.shares`(기본 1024) vs v2 `cpu.weight`(기본 100). 조치 B~D 명령이 달라짐 |
| player의 cgroup과 제한 | `cat /proc/<pid>/cgroup` → 해당 cgroup의 cpu.* | 시스템 서비스가 player를 어떤 group에 넣고 제한하는지 |
| RT throttling | `/proc/sys/kernel/sched_rt_runtime_us` (기본 950000) | SCHED_FIFO도 1초 중 0.95초만 실행 (Q3.3) |
| thread별 우선순위·affinity | `ps -eLo tid,cls,rtprio,ni,psr,comm`, `chrt -p`, `taskset -p` | 이미 RT priority, nice, CPU 고정이 걸린 thread 확인 |

**적용 순서**
1. 보드 기본 정보 수집 → 이슈가 생겼을 때 "이 보드의 기준"
2. 이슈 재현 중 `/proc/<pid>/task/*/schedstat`으로 runqueue 대기가 큰 thread 찾기 (perf 없이도 가능)
3. perf가 있으면 perf sched로 경쟁 task 식별 (단계 2 절차)
4. nice → cgroup weight → cpuset → RT 순서로 조치 비교 (단계 3~6)

## 진행 현황 (안내서 단계 1~7)

| 단계 | 내용 | tag | sudo | 상태 |
| --- | --- | --- | --- | --- |
| 1 | indexer + renderer 같은 CPU 0에서 실행 | base | - | 완료 (위 결과) |
| 2 | 1을 반복하며 perf sched 8초 기록 → Max delay, 경쟁 task 식별 | base | perf | |
| 3 | 조치 A: indexer TID에 nice 10 | nice | perf | |
| 4 | 조치 B: lab/bg cpu.weight 20 | weight | O | |
| 5 | 조치 C: lab/bg cpu.max 30ms/100ms | max | O | |
| 6 | 조치 D: lab/bg cpuset.cpus=1 | cpuset | O | |
| 7 | 정리: fixcg.sh teardown, 결과 표 작성 | - | O | |

**실행 방법**: 단계 2~7은 indexer, renderer, perf를 동시에 띄워야 해서 `tools/lab3_run.sh`(study 추가)로 묶었다. 안내서 명령을 그대로 background 실행하고, 결과를 `logs/lab3-<tag>-*.txt`에 저장한다.

```bash
cd study/Week4/Lab4
bash tools/lab3_run.sh all     # 2~7 전체 (약 2분, sudo 비밀번호 1회)
bash tools/lab3_run.sh 4       # 특정 단계만
```
