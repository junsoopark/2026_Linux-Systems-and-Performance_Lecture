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

**예측 1** (기본 조건 Max delay): 둘 다 nice 0이면 CFS/EEVDF가 CPU를 반반 나눈다. 강의 환경(HZ=250, tick 4ms) 기준으로는 renderer가 깨어나도 indexer의 slice가 끝날 때까지 수 ms 기다릴 수 있다.
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
