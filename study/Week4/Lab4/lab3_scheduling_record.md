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

## 현업 적용 포인트 (webOS 미디어 플레이어)

- **CPU 사용률이 아니라 schedstat의 `wait_ms`(runqueue 대기)와 비자발적 context switch를 본다.** renderer는 CPU의 20%만 쓰는데도 frame마다 3ms씩 대기했다. `top`으로는 보이지 않는다.
  - 운영 장비에서 바로 확인: `cat /proc/<pid>/task/<tid>/schedstat` (실행 ns, 대기 ns, 횟수), `grep ctxt /proc/<pid>/task/<tid>/status`
- **CPU 절전도 지연 원인이 된다.** 주기적으로 깨어나는 player thread가 idle CPU에서 돌면 C-state 탈출과 저주파수 때문에 수백 µs 늦어질 수 있다. 측정할 때 governor, 주파수, C-state 설정을 함께 기록한다.

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
