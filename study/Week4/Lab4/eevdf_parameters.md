# EEVDF scheduling 파라미터: 고정값, 근거, 연쇄 계산

> 실습 3(`lab3_scheduling_record.md`)과 `study/sched_profile` 측정값을 kernel 소스로 검증한 정리.
> 소스 확인일: 2026-10-07 (0.75 유래·3절은 2026-10-08, 3.1·3.2 용어 정의와 2.3 debugfs는 2026-10-10). 근거는 `kernel/sched/fair.c`, `features.h`, `syscalls.c`의 v6.5(CFS) / v6.6 / v6.12 / master(7.3 개발 중).

## 1. 실측 예

| | 보드 A (익명) | 학습 PC |
| --- | --- | --- |
| kernel | 6.12 | 7.0 |
| CPU | ARM Cortex-A73 × 4 (big.LITTLE 아님) | x86 4C/8T → online 8 |
| HZ | 250 (jiffies 실측 252) | 1000 (`CONFIG_HZ=1000`) |
| `tunable_scaling` | 1 (LOG) | 1 (LOG, 기본값 가정) |
| `base_slice_ns` | **2,250,000** (debugfs) | **2,800,000** (`/proc/self/sched` `se.slice`) |
| HRTICK | off | off (기본값) |
| 측정 도구 | `study/sched_profile/sched_profile.sh` 섹션 1·2 | 동일 + 실습 3 `mtwork` |

두 값 모두 아래 공식으로 정확히 재현된다.

## 2. kernel 버전에 따른 고정값과 근거

### 2.1 base slice 기준값 (`normalized_sysctl_sched_base_slice`)

| kernel | 기준값 | 근거 |
| --- | --- | --- |
| 6.6 ~ 6.14 | **0.75 ms** | `fair.c`: `unsigned int sysctl_sched_base_slice = 750000ULL;` (v6.6 L78, v6.12 L76) |
| 6.15 ~ (7.x 포함) | **0.70 ms** | `fair.c`: `= 700000ULL;` (master L85). 커밋 [`2ae891b`](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=2ae891b826958b60919ea21c727f77bcd6ffcc2c) "sched: Reduce the default slice to avoid tasks getting an extra tick" |

6.6은 EEVDF가 도입된 버전으로, 이전 CFS의 `sched_min_granularity`가 `sched_base_slice`로 이름이 바뀌었다.

**0.75의 유래: CFS의 "6 ms ÷ 8"** (v6.5 `fair.c`로 확인)

CFS에는 기본값 세 개가 묶여 있었다. 소스 주석: `sched_nr_latency` = "kept at `sysctl_sched_latency / sysctl_sched_min_granularity`".

| 변수 (CFS) | 기본값 | 의미 |
| --- | --- | --- |
| `sysctl_sched_latency` | 6 ms | 실행 가능한 task가 모두 한 번씩 도는 주기 (목표 지연) |
| `sched_nr_latency` | 8 | 이 주기 안에 담을 task 수 |
| `sysctl_sched_min_granularity` | **0.75 ms** = 6 / 8 | task 하나의 최소 연속 실행 시간. task가 8개를 넘으면 주기를 0.75 ms × N으로 늘림 |

| 시기 | 커밋 | latency | min_gran | nr_latency | 이유 |
| --- | --- | --- | --- | --- | --- |
| 2010-03 | [`21406928`](https://lkml.iu.edu/1003.1/01763.html) (Mike Galbraith) | 5 → **6 ms** | 1 → 2 ms | 5 → 3 | LAST_BUDDY를 빨리 동작시켜 cache 효율 향상 (tbench 약 2%) |
| 2010-09 (2.6.36) | [`0bf377bb`](https://zircon-guest.googlesource.com/third_party/linux/+/0bf377bbb0bea6130f35613491887cc622e42a8b) (Ingo Molnar) | 6 ms | 2 → **0.75 ms** | 3 → **8** | `make -j10` 부하에서 지연이 큼 (Mathieu Desnoyers, Linus 보고). granularity가 너무 굵어 6 ms 목표를 못 지킴. 최대 지연 38,279 → 22,702 µs, 평균 7,730 → 6,685 µs |
| 2023 (6.6) | EEVDF 도입 | 없어짐 | 이름만 `base_slice`, **값 0.75 유지** | 없어짐 | |
| 2025 (6.15) | `2ae891b` | | 0.75 → **0.70 ms** | | tick 경계 문제 (아래) |

→ 0.75는 EEVDF에 맞춰 새로 정한 값이 아니라 CFS의 "목표 지연 6 ms를 8개로 나눈 최소 단위"를 그대로 물려받은 값이다. EEVDF에는 목표 지연(latency)과 nr_latency 개념이 없으므로 의미가 "요청 하나로 받을 CPU 실행 시간"으로 바뀌었다(3절). 처음 다시 검토된 것이 6.15의 0.70 변경이고, 이유도 공정성이 아니라 tick 정밀도였다.

커밋 `2ae891b`의 설명 (요지):
- tick은 예상보다 조금 일찍 도착하는 경우가 많아서(clockevent 정밀도, IRQ 시간 회계), slice = 정확히 N tick이면 deadline 직전 tick에서 판정이 안 되고 **한 tick을 더 실행**한다. (예: HZ 1000, 8 CPU, slice 3ms → 실제 4ms)
- 0.75 → 0.70으로 줄여 slice가 tick 경계 바로 안쪽에 오도록 했다.
- **"HZ=250과 HZ=100에서는 tick 정밀도 때문에 task의 실제 실행 시간이 slice보다 훨씬 길다"**고 명시한다. → 보드 A(HZ 250)의 "slice 2.25ms인데 실제 약 4ms" 분석과 같은 내용이다.

### 2.2 factor (CPU 수에 따른 배율)

`fair.c` `get_update_sysctl_factor()` (v6.12 동일, master 동일):

```c
unsigned int cpus = min_t(unsigned int, num_online_cpus(), 8);
switch (sysctl_sched_tunable_scaling) {
case SCHED_TUNABLESCALING_NONE:   factor = 1;               break;
case SCHED_TUNABLESCALING_LINEAR: factor = cpus;            break;
case SCHED_TUNABLESCALING_LOG:
default:                          factor = 1 + ilog2(cpus); break;
}
```

| 고정값 | 값 | 근거 |
| --- | --- | --- |
| `tunable_scaling` 기본값 | **LOG (1)** | `unsigned int sysctl_sched_tunable_scaling = SCHED_TUNABLESCALING_LOG;` |
| CPU 수 상한 | **8** | `min_t(..., num_online_cpus(), 8)` → CPU가 8개를 넘어도 factor는 최대 4 |
| `ilog2` | 내림 log2 | 5~7 CPU는 log2 = 2 |

CPU 수별 기본 base slice (커밋 `2ae891b` 메시지와 동일):

| online CPU | factor (LOG) | 6.6 ~ 6.14 (0.75) | 6.15 ~ (0.70) |
| --- | ---: | ---: | ---: |
| 1 | 1 | 0.75 ms | 0.70 ms |
| 2 ~ 3 | 2 | 1.50 ms | 1.40 ms |
| 4 ~ 7 | 3 | **2.25 ms** ← 보드 A | 2.10 ms |
| 8 이상 | 4 | 3.00 ms | **2.80 ms** ← 학습 PC |

### 2.3 다시 계산되는 시점

```c
void __init sched_init_granularity(void) { update_sysctl(); }   // 부팅 시
static void rq_online_fair(struct rq *rq)  { update_sysctl(); ... }  // CPU online
static void rq_offline_fair(struct rq *rq) { update_sysctl(); ... }  // CPU offline
// update_sysctl(): sysctl_sched_base_slice = factor * normalized_sysctl_sched_base_slice
```

→ CPU hotplug(전원 관리로 core를 끄고 켜는 경우 포함) 때마다 base slice가 바뀐다. 측정할 때 online CPU 수를 함께 기록해야 하는 이유.

**하드코딩된 것은 기준값(`normalized_sysctl_sched_base_slice`) 하나뿐이다.** 2.2의 CPU 수별 표는 `update_sysctl()`이 위 시점에 계산한 결과다.

**실행 중 변경 (`/sys/kernel/debug/sched/base_slice_ns`)의 함정** (v6.12, master 동일):
- `debug.c`: `debugfs_create_u32("base_slice_ns", 0644, debugfs_sched, &sysctl_sched_base_slice);` → 값을 쓰면 `sysctl_sched_base_slice`만 직접 바뀐다.
- 기준값을 다시 계산하는 `sched_update_scaling()`(`normalized = sysctl / factor`)은 **`tunable_scaling`에 쓸 때만** 불린다(`sched_scaling_write`).
- 따라서 `base_slice_ns`만 바꾸면 다음 CPU hotplug 때 `update_sysctl()`이 옛 기준값 × factor로 **덮어써서 변경이 사라진다.** 유지하려면 `base_slice_ns`를 쓴 뒤 `tunable_scaling`에 현재 값을 다시 써서 기준값을 갱신해야 한다.

### 2.4 그 외 고정값

| 항목 | 값 | 근거 (v6.12) |
| --- | --- | --- |
| nice 0 weight (`NICE_0_LOAD`) | 1024 | `sched_prio_to_weight[]` (2.6.23부터 동일), 한 단계 약 1.25배 |
| 개별 slice 허용 범위 | **0.1 ms ~ 100 ms** | `syscalls.c` `__setscheduler_params()`: `clamp_t(u64, attr->sched_runtime, NSEC_PER_MSEC/10, NSEC_PER_MSEC*100)` → `se.custom_slice = 1` |
| lag 저장 상한 | ± max(2 × slice, 1 tick) (가상 시간) | `entity_lag()`: `limit = calc_delta_fair(max_t(u64, 2*se->slice, TICK_NSEC), se)` |
| tick 길이 | 1 / `CONFIG_HZ` | 빌드 설정. scheduler 상수가 아니라 보드마다 다름 |

### 2.5 feature 기본값의 버전별 차이 (`features.h`)

| feature | v6.6 | v6.12 | master | 의미 (소스 주석) |
| --- | --- | --- | --- | --- |
| `PLACE_LAG` | true | true | true | sleep/wake 사이 lag 보존 |
| `RUN_TO_PARITY` | true | true | true | 현재 task가 0-lag 지점이나 slice 소진에 도달할 때까지 wakeup 선점 금지 |
| `PREEMPT_SHORT` | 없음 | true | true | 더 짧은 slice의 task가 깨어나면 현재 task의 slice 보호를 취소 |
| `DELAY_DEQUEUE` | 없음 | true | true | 자격 없는(음수 lag) task의 dequeue를 미뤄 음수 lag을 소진 |
| `DELAY_ZERO` | 없음 | true | true | 위 경우 dequeue/wakeup 시 lag을 0으로 자름 |
| `HRTICK` | false | false | **조건부 true** | slice 끝을 hrtimer로 정밀하게. master는 `CONFIG_HRTIMER_REARM_DEFERRED`면 true |
| `NEXT_BUDDY` | false | false | false | 방금 깨운 task 우대 |

→ 6.12부터 개별 slice(`PREEMPT_SHORT` + `custom_slice`)와 delayed dequeue가 들어왔다. 6.6 보드에서는 개별 slice 방법을 쓸 수 없다.

## 3. base slice의 의미: "요청 하나로 받을 CPU 실행 시간"

### 3.1 용어 정의 (v6.12 `fair.c` 기준)

EEVDF(Stoica 1995)에서 task i는 CPU 시간을 **요청(request) 단위**로 받는다. 요청 하나의 크기가 r_i이고 kernel에서는 `se->slice`이다. 소스 주석(`update_deadline`): "the virtual time slope is determined by w_i (iow. nice) while the request time r_i is determined by sysctl_sched_base_slice".

**시간 축은 두 개다.**
- **실제 시간(real time)**: 단위 ns. task가 CPU에서 실제로 돈 시간. slice, `sum_exec_runtime`, `delta_exec`가 이 축이다.
- **가상 시간(virtual time)**: 실제 시간을 weight로 환산한 값. `calc_delta_fair(Δ, se) = Δ × NICE_0_LOAD / w_i` (`NICE_0_LOAD` = nice 0의 weight 1024). nice 0이면 실제 시간과 같고, weight가 클수록 천천히 흐른다. vruntime, V, deadline, vlag가 이 축이다.

| 기호 | kernel 변수 | 축 | 정의 |
| --- | --- | --- | --- |
| Δ | `delta_exec` (`update_curr_se`) | 실제 | 직전 갱신 이후 CPU에서 돈 시간 = `rq_clock_task(rq) − se->exec_start` (3.2 참고) |
| r_i | `se->slice` | 실제 | 요청 하나로 받을 **CPU 실행 시간**. 기본 = `sysctl_sched_base_slice`, `custom_slice`면 `sched_setattr`의 `sched_runtime` |
| w_i | `se->load.weight` | — | nice/cgroup weight. 가상 시간이 흐르는 속도를 정함 |
| v_i | `se->vruntime` | 가상 | 누적 실행 시간을 가상 시간으로 환산한 값. `update_curr()`에서 `vruntime += calc_delta_fair(Δ, se)` |
| V | `avg_vruntime(cfs_rq)` | 가상 | runqueue에 있는 entity(현재 실행 중 포함)의 weight 가중 평균 vruntime = Σ w_j·v_j / Σ w_j. 정의상 Σ w_j·(V − v_j) = 0, 즉 **모든 task의 lag 합이 0이 되는 기준점** |
| lag_i | (계산식) | 실제 | w_i·(V − v_i). 이상적인 몫(유체 모델)에 비해 **덜 받은 CPU 시간**. 양수면 덜 받음, 음수면 더 받음 |
| vlag_i | `se->vlag` | 가상 | V − v_i (lag을 w_i로 나눈 값). dequeue 때 `update_entity_lag()`가 ± max(2·r_i, 1 tick)(가상 환산)으로 잘라 저장하고, 다음 `place_entity()`에서 사용. **실행 중에는** `RUN_TO_PARITY` 표시용으로 deadline 사본이 들어간다 (5절) |
| eligible | `entity_eligible()` | — | lag_i ≥ 0 ⇔ V ≥ v_i. 받아야 할 만큼 아직 못 받았다 = 실행 자격 있음 |
| ve_i | (요청 시작 시점의 `se->vruntime`) | 가상 | 요청의 virtual eligible time. kernel은 따로 저장하지 않고 요청을 시작할 때의 vruntime을 쓴다 |
| vd_i | `se->deadline` | 가상 | 요청의 virtual deadline = ve_i + r_i × NICE_0_LOAD / w_i. 요청이 시작될 때(`place_entity`, `update_deadline`) 한 번 계산되고, vruntime이 여기에 도달하면 요청 소진 |

### 3.2 slice가 재는 시간의 성질

slice는 작업량(instruction 수)이 아니라 **CPU 실행 시간**이다. 정확히는 다음 성질을 가진다.

1. **실제로 CPU에서 돈 시간이다.** wall-clock이 아니므로 runqueue에서 기다리거나 잠든 시간은 들어가지 않는다. 요청 도중 RT task나 `PREEMPT_SHORT`로 밀려나도 deadline은 그대로 남고, 다시 실행되면 같은 요청의 나머지를 이어서 쓴다. 따라서 slice는 "연속 실행 시간"이 아니라 **요청 하나 동안 누적되는 실행 시간**이다 (보통 `RUN_TO_PARITY` 때문에 연속으로 쓰게 될 뿐이다).
2. **`rq_clock_task` 기준이다.** `core.c` `update_rq_clock_task()`가 `CONFIG_IRQ_TIME_ACCOUNTING`이면 IRQ 처리 시간을, `CONFIG_PARAVIRT_TIME_ACCOUNTING`이면 VM steal time을 빼고 `clock_task`를 올린다. 둘 다 꺼져 있으면 task 실행 중 처리된 IRQ 시간도 그 task의 slice에서 차감된다. (학습 PC 7.0.0-15-generic: 둘 다 `not set`)
3. **일한 양과는 무관하다.** `calc_delta_fair()`는 weight만 반영하고 CPU 주파수나 core capacity 보정이 없다. DVFS로 클럭이 낮거나 little core에서 돌면 같은 slice 동안 처리하는 일이 줄어든다. 주파수·capacity 보정은 PELT(load/util 추적) 쪽에만 있다.

scheduler의 선택 규칙은 하나다. **eligible한 task 중 deadline이 가장 이른 task**(Earliest Eligible Virtual Deadline First)를 고른다.

### 3.3 slice가 쓰이는 곳 (v6.12 `fair.c`)

| 시점 | 함수 | slice의 역할 |
| --- | --- | --- |
| 깨어날 때·새로 생길 때 | `place_entity()` | `vslice = calc_delta_fair(slice)`. 저장된 vlag을 가중치 보정한 뒤 `vruntime = V − vlag`로 배치하고 `deadline = vruntime + vslice`. 새 task(`ENQUEUE_INITIAL`)는 `PLACE_DEADLINE_INITIAL`로 vslice를 절반만 줌 ("기존 task들은 평균적으로 slice의 절반쯤 와 있다") |
| 실행 중 (tick) | `update_curr()` → `update_deadline()` | `vruntime >= deadline`이면 **요청 소진**. `se->slice`를 base slice로 다시 읽고 새 deadline을 잡은 뒤 resched ("The task has consumed its request, reschedule") |
| 다음 task 고르기 | `pick_eevdf()` | eligible한 것 중 deadline 최소. 같은 weight라면 **slice가 짧을수록 deadline이 가까워** 먼저 뽑힘 |
| 고른 뒤 보호 | `set_next_entity()` + `RUN_TO_PARITY` | 고른 순간의 deadline까지 (= 요청 하나를 다 쓸 때까지) wakeup 선점을 막음 (5절) |
| wakeup 선점 | `do_preempt_short()` (`PREEMPT_SHORT`, 6.12+) | 깨어난 task의 slice가 현재 task보다 **짧을 때만** 위 보호를 해제 |
| lag 저장 상한 | `entity_lag()` | vlag을 ± calc_delta_fair(max(2 × slice, 1 tick))로 자름 → 오래 자고 일어나도 slice 2개(실제 시간) 이상의 보상은 못 받음 |

`update_deadline()`과 `place_entity()`가 매번 `se->slice = sysctl_sched_base_slice`로 다시 읽으므로, debugfs `base_slice_ns` 쓰기나 CPU hotplug로 `sysctl_sched_base_slice`가 바뀌면 **각 task의 다음 요청부터** 적용된다. `custom_slice`(sched_setattr)인 task만 자기 값을 유지한다.

### 3.4 slice가 바꾸는 것과 바꾸지 않는 것

| | 정하는 값 | 결과 |
| --- | --- | --- |
| **CPU 몫** (장기 비율) | weight (nice, cgroup `cpu.weight`) | V를 기준으로 lag이 0 근처에 머물도록 수렴하므로 비율은 weight로만 정해진다 |
| **한 번에 도는 길이 / 차례가 오는 시점** | slice | 짧은 요청 = deadline이 가까워 빨리 뽑히지만 자주 끊김 (지연↓, 문맥 교환↑). 긴 요청 = 늦게 뽑히지만 한 번에 오래 돎 (지연↑, cache 효율↑) |

CFS의 `min_granularity`는 "이보다 짧게는 끊지 않는다"는 **하한**이었다. EEVDF의 slice는 "이만큼을 한 번의 요청으로 달라"는 **요청 크기**이고, 그 크기가 곧 deadline을 정해 선택 순서에 들어간다. 그래서 task마다 다르게 줄 수 있고(6.12+ `custom_slice`), 짧게 주는 것이 "지연에 민감하다"는 신호가 된다.

### 3.5 예: 주기 thread가 깨어날 때 (실습 3 상황)

같은 CPU에서 indexer(busy, nice 0)가 돌고 있고, renderer(nice 0)가 잠에서 깬다. 둘 다 weight 1024이므로 vslice = slice. lag 0으로 깬다고 가정한다.

| | renderer slice = base (2.25 ms) | renderer slice = 1 ms (`sched_setattr`, 6.12+) |
| --- | --- | --- |
| renderer deadline (가상) | V + 2.25 ms | V + 1 ms |
| indexer deadline (가상) | 요청 시작 때 v ≤ V였으므로 ≤ V + 2.25 ms | 같음 |
| `pick_eevdf` | `RUN_TO_PARITY` 표시가 남아 있으면 indexer 유지. 표시가 없어도 indexer deadline이 같거나 더 이름 | renderer deadline이 더 이를 가능성이 큼 |
| `PREEMPT_SHORT` | slice가 같으므로 보호 해제 안 됨 | 1 < 2.25 → 보호 해제 |
| 결과 | indexer가 요청을 다 쓸 때까지 대기 (tick 단위로 최대 약 4 ms, HZ 250) | 즉시 선점 가능 |

→ "요청 크기"가 짧다는 것은 "덜 받겠다"가 아니라 **"조금씩 자주, 대신 빨리 달라"**는 뜻이다. CPU 몫을 늘리려면 weight를, 깨어난 직후의 대기를 줄이려면 slice를 조정한다.

## 4. 연쇄 계산: 값이 결정되는 순서

보드 A 숫자로 따라가면 (nice 0 task 둘이 같은 CPU에서 경쟁):

```
[빌드]   CONFIG_HZ = 250                      → tick = 4 ms
[부팅]   online CPU = 4
         factor = 1 + ilog2(min(4, 8)) = 3    (tunable_scaling = LOG)
         base_slice = 0.75 ms x 3 = 2.25 ms   (kernel 6.12의 기준값 0.75 ms, 6.6~6.14 공통)
[task]   se.slice = base_slice = 2.25 ms      (custom_slice가 아니면, place_entity/update_deadline에서 매번 갱신)
         vslice = slice x 1024 / weight       (calc_delta_fair)
                = 2.25 ms                      (nice 0, weight 1024)
         deadline = vruntime + vslice          (update_deadline)
         lag 상한 = max(2 x 2.25, 4) = 4.5 ms (entity_lag)
[실행]   tick마다 update_curr → update_deadline:
           vruntime >= deadline 이면 새 deadline + resched
         HRTICK off → slice 소진은 tick에서만 판정
         실제 연속 실행 = 2.25 ms를 tick(4 ms) 단위로 올림 = 약 4 ms
[결과]   경쟁하는 두 task는 약 4 ms씩 번갈아 실행
         → 같은 CPU의 주기 thread는 경쟁 1회당 최대 약 4 ms 대기
```

학습 PC (kernel 7.0, 8 CPU, HZ 1000):

```
factor = 1 + ilog2(8) = 4 → base_slice = 0.70 x 4 = 2.8 ms
tick 1 ms 단위로 올림 → 약 3 ms → 실습 3 실측 연속 실행 3.17 ms와 일치
```

### weight(nice)가 끼어드는 지점

`vslice = slice × 1024 / weight`이므로 nice가 높을수록(weight가 작을수록) **같은 실제 slice가 더 긴 가상 시간**이 된다.

| nice | weight | 가상 slice (base 2.25 ms) | 의미 |
| --- | ---: | ---: | --- |
| 0 | 1024 | 2.25 ms | 기준 |
| 10 | 110 | 2.25 × 1024 / 110 ≈ **20.9 ms** | deadline이 훨씬 뒤로 → 덜 자주 선택됨 |
| -10 | 9548 | 2.25 × 1024 / 9548 ≈ **0.24 ms** | deadline이 가까움 → 자주 선택됨 |

실제 slice 길이(한 번에 도는 시간)는 nice와 무관하게 2.25 ms이고, **얼마나 자주 차례가 오는지**가 weight로 바뀐다.

## 5. 선점이 결정되는 두 경로 (v6.12 소스)

**(1) tick 경로** — `update_curr()`

```c
resched = update_deadline(cfs_rq, curr);       // vruntime >= deadline이면 true
...
if (cfs_rq->nr_running == 1) return;
if (resched || did_preempt_short(cfs_rq, curr))
        resched_curr(rq);
```

**(2) wakeup 경로** — `check_preempt_wakeup_fair()`

```c
if (unlikely(!normal_policy(p->policy)))        // BATCH/IDLE은 깨어나도 선점 안 함
        return;
update_curr(cfs_rq);
if (do_preempt_short(cfs_rq, pse, se) && se->vlag == se->deadline)
        se->vlag = se->deadline + 1;            // 짧은 slice task면 현재 task의 slice 보호 해제
if (pick_eevdf(cfs_rq) == pse)                  // 깨어난 task가 최선이면
        goto preempt;                            // 즉시 선점
```

**slice 보호 (`RUN_TO_PARITY`)의 구현**
- `set_next_entity()`: CPU를 받을 때 `se->vlag = se->deadline`으로 표시 ("HACK, stash a copy of deadline at the point of pick").
- `pick_eevdf()`: `if (sched_feat(RUN_TO_PARITY) && curr && curr->vlag == curr->deadline) return curr;` → 표시가 남아 있는 동안 현재 task를 계속 고른다.
- 표시는 deadline이 갱신될 때(= slice 소진, tick에서 판정) 사라진다. 또는 `PREEMPT_SHORT`로 더 짧은 slice의 task가 깨어나면 `deadline + 1`로 바꿔 해제된다.

`do_preempt_short()`의 조건: 깨어난 task의 slice가 **현재 task보다 짧고**(`pse->slice < se->slice`), 깨어난 task가 실행 자격(eligible)이 있을 것.

→ **같은 slice끼리는 깨어난 task가 현재 task의 slice 보호를 깰 수 없다.** 보드 A에서는 최악의 경우 현재 task의 남은 slice(tick 단위로 최대 약 4 ms)만큼 기다린다.

## 6. 현업 적용

| 상황 | 판단 | 근거 |
| --- | --- | --- |
| kernel < 6.15 & HZ 250/100 | 실제 교체 단위는 slice가 아니라 tick | 커밋 `2ae891b` 메시지 |
| CPU hotplug가 있는 보드 | online CPU 수에 따라 slice가 달라짐 | `rq_online_fair`/`rq_offline_fair` → `update_sysctl` |
| 주기 thread(player, render)를 빨리 깨우고 싶다 (6.12+) | `sched_setattr()`로 개별 slice를 base보다 짧게 (예: 1 ms) | `PREEMPT_SHORT` + `custom_slice` (0.1~100 ms) |
| 경쟁 task의 CPU 몫을 줄이고 싶다 | nice/cgroup weight를 낮춤 → 가상 slice가 길어져 차례가 덜 옴 | `vslice = slice × 1024 / weight` |
| 측정 시 반드시 기록할 값 | kernel 버전, online CPU 수, `tunable_scaling`, `base_slice_ns`, HZ, HRTICK on/off | 위 연쇄 계산의 입력값 전부 |

미해결: 학습 PC의 실습 3에서 renderer의 `late_p99u`가 71 µs로 작았다. 위 로직대로면 같은 slice끼리는 slice 보호 때문에 더 기다려야 한다. kernel 7.0의 변경(예: `RUN_TO_PARITY` 동작 변경) 가능성 → perf sched timehist와 7.0 소스로 확인할 것.

## 참고 소스

- [fair.c v6.12](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/kernel/sched/fair.c?h=v6.12) — `sysctl_sched_base_slice`, `get_update_sysctl_factor`, `update_sysctl`, `entity_lag`, `place_entity`, `update_deadline`, `update_curr`, `pick_eevdf`, `check_preempt_wakeup_fair`, `do_preempt_short`, `rq_online_fair`
- [features.h v6.12](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/kernel/sched/features.h?h=v6.12), [features.h master](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/kernel/sched/features.h)
- [syscalls.c v6.12](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/kernel/sched/syscalls.c?h=v6.12) — `__setscheduler_params()`의 custom slice
- [커밋 2ae891b](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=2ae891b826958b60919ea21c727f77bcd6ffcc2c) — 0.75 → 0.70 ms (v6.15)
- [fair.c v6.5](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/kernel/sched/fair.c?h=v6.5) — CFS 마지막 버전의 `sysctl_sched_latency`(6 ms), `sched_nr_latency`(8), `sysctl_sched_min_granularity`(0.75 ms)
- [커밋 0bf377bb](https://zircon-guest.googlesource.com/third_party/linux/+/0bf377bbb0bea6130f35613491887cc622e42a8b) — min_granularity 2 → 0.75 ms, nr_latency 3 → 8 (2.6.36), [LKML 패치](https://lkml.iu.edu/hypermail/linux/kernel/1009.1/02269.html)
- [커밋 21406928](https://lkml.iu.edu/1003.1/01763.html) — latency 5 → 6 ms (2010-03)
- [debug.c v6.12](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/kernel/sched/debug.c?h=v6.12) — `base_slice_ns`(debugfs u32), `sched_scaling_write()` → `sched_update_scaling()`
- [core.c v6.12](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/kernel/sched/core.c?h=v6.12) — `update_rq_clock_task()`: IRQ/steal time 차감
