# EEVDF scheduling 파라미터: 고정값, 근거, 연쇄 계산

> 실습 3(`lab3_scheduling_record.md`)과 `study/sched_profile` 측정값을 kernel 소스로 검증한 정리.
> 소스 확인일: 2026-10-07. 근거는 `kernel/sched/fair.c`, `features.h`, `syscalls.c`의 v6.6 / v6.12 / master(7.3 개발 중).

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

## 3. 연쇄 계산: 값이 결정되는 순서

보드 A 숫자로 따라가면 (nice 0 task 둘이 같은 CPU에서 경쟁):

```
[빌드]   CONFIG_HZ = 250                      → tick = 4 ms
[부팅]   online CPU = 4
         factor = 1 + ilog2(min(4, 8)) = 3    (tunable_scaling = LOG)
         base_slice = 0.75 ms x 3 = 2.25 ms   (6.12 기준값 0.75)
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

## 4. 선점이 결정되는 두 경로 (v6.12 소스)

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

## 5. 현업 적용

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
