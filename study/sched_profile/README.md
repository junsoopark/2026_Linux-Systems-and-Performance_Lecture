# sched_profile — 타겟 디바이스 scheduling 속성 수집

Week4 실습 3(scheduling 지연 진단)에서 정리한 "보드 특성 체크리스트"를 한 번에 수집하는 스크립트.
webOS 등 타겟 보드에서 성능 이슈를 분석하기 전에 **이 보드의 기준값**을 확보하는 용도다.

- POSIX sh 스크립트: busybox ash, dash, bash에서 동작 (busybox ash, dash로 검증)
- `/proc`, `/sys`만 **읽는다**. 시스템 설정을 바꾸지 않는다.
- root로 실행해야 볼 수 있는 항목: debugfs(`/sys/kernel/debug/sched`)의 `base_slice_ns`, `preempt`, `features`. 일반 사용자는 "(no permission)"으로 표시된다.
- **출력은 ASCII(영어)만 사용**한다. 임베디드 보드는 셸 locale이 UTF-8이 아닌 경우가 많아서(`LANG=C`), 한글을 출력하면 깨진다. 설명은 이 README에만 둔다.
- 외부 명령은 busybox 기본 명령(`awk`, `sed`, `grep`, `tr`, `cut`, `sort`, `wc`)만 쓴다. `fold`, `paste`처럼 빠져 있는 경우가 있는 명령은 쓰지 않는다.
- kernel config가 없는 보드에서도 HZ를 알 수 있도록, root면 `/proc/timer_list`의 jiffies를 1초 간격으로 두 번 읽어 **HZ를 실측**한다.

## 다운로드 없이 바로 실행

이 저장소는 private(GitLab)이라 인증 없이 받을 수 있는 URL이 없다. 디바이스에 파일을 저장하거나 토큰을 넣지 않고 실행하는 방법은 다음과 같다.

**1) PC의 스크립트를 ssh로 넘기기 (기본)**

PC에 있는 파일을 ssh 표준입력으로 디바이스 셸에 넘긴다. 디바이스는 인터넷 연결이 필요 없고 ssh 접속만 되면 된다.

```bash
S=study/sched_profile/sched_profile.sh          # repo 루트 기준

ssh root@<device_ip> 'sh -s' < $S                               # 시스템 전체
ssh root@<device_ip> 'sh -s -- <pid|process_name>' < $S         # + 특정 process의 thread별 상세
ssh root@<device_ip> 'sh -s' < $S > sched_profile_<board>.txt   # 결과를 PC에 저장
```

특정 커밋 버전으로 실행하려면 작업 트리 대신 git에서 바로 꺼내 넘긴다.

```bash
git show <commit>:study/sched_profile/sched_profile.sh | ssh root@<device_ip> 'sh -s'
```

**2) 디바이스 셸에 직접 붙여넣기 (ssh 파이프가 안 될 때)**

시리얼 콘솔 등에서는 디바이스에 `cat > /tmp/sp.sh` 입력 후 스크립트 내용을 붙여넣고 Ctrl-D, `sh /tmp/sp.sh`. 출력이 ASCII라 콘솔 locale과 무관하다.

**3) GitHub 공개 URL — 스크립트 개발 중 기본 방법** (공개 fork의 `study` 브랜치가 남아 있는 동안만)

```bash
URL=https://raw.githubusercontent.com/junsoopark/2026_Linux-Systems-and-Performance_Lecture/672f3078bb35da25d116665c84b5fc3597e706b2/study/sched_profile/sched_profile.sh
curl -fsSL "$URL" | sh                          # 디바이스에 curl이 있을 때
curl -fsSL "$URL" | sh -s -- <pid|process_name> # + 특정 process의 thread별 상세
wget -qO- "$URL" | sh                           # wget만 있을 때 (HTTPS 미지원 빌드 주의)
```

스크립트가 완성될 때까지는 GitHub 공개 fork에도 push하고 이 URL을 새 커밋으로 갱신한다. 완성 후에는 1) ssh 방식이나 공개 snippet으로 옮긴다.

GitHub fork의 `study` 브랜치를 지우면 이 URL은 동작하지 않을 수 있다.

**root 권한**: debugfs와 `/proc/timer_list` 항목까지 보려면 root로 실행한다 (`ssh root@...` 또는 디바이스 root 셸).

## 출력 섹션

| 섹션 | 내용 | 무엇을 판단하나 |
| --- | --- | --- |
| 1. kernel | kernel 버전, CFS/EEVDF 구분, `CONFIG_HZ`(config 없으면 jiffies로 HZ 실측), preempt 방식, sched 관련 config, kernel cmdline의 scheduling 관련 부팅 옵션(`isolcpus`, `nohz_full`, `irqaffinity` 등) | tick 간격, 선점 방식, scheduler 알고리즘, CPU 격리 여부 |
| 2. scheduler tunables | `/proc/sys/kernel/sched_*`, RT throttling, debugfs의 slice 관련 값과 features, sched_ext, nice→weight 표 | slice 길이(경쟁 시 frame 지연 크기), RT task 실행 상한 |
| 2. (유도) base slice derivation | `base_slice = 기준값 × factor`를 CPU 수와 `tunable_scaling`으로 계산해 실제값과 비교. 기준값이 기본(0.75/0.70ms)인지 판정. debugfs를 못 읽으면 `/proc/self/sched`의 `se.slice`로 대신 구함(root 불필요) | slice가 왜 그 값인지, 누가 바꿨는지 |
| 2. (유도) effective switch granularity | HRTICK이 꺼져 있으면 slice 끝을 tick에서만 확인 → 실제 연속 실행 = slice를 tick 단위로 올림 | 경쟁 시 한 번에 밀리는 시간 (예: slice 2.25ms + tick 4ms → 약 4ms) |
| 2. features / autogroup / sched domains | 주요 feature on/off와 의미, autogroup(켜져 있으면 nice가 같은 세션 안에서만 비교됨), load balancing 범위 | 깨어날 때 선점 조건, nice가 기대대로 듣는지 |
| 3. CPU | core 구성, core별 `cpu_capacity`(big.LITTLE), cpufreq governor·주파수, cache, cpuidle 상태별 깨어남 지연, IRQ 상위 10개의 CPU별 분포 | core 간 성능 차이, 절전으로 인한 wakeup 지연, interrupt가 몰린 CPU |
| 4. cgroup | v1/v2 구분, 그룹별 `cpu.weight`/`cpu.max`/`cpuset.cpus`/`uclamp.min` (v1은 `cpu.shares` 등). 기본값과 다른 그룹에 `*` 표시 | player가 속한 그룹에 제한이 걸려 있는지 |
| 5. RT·특수 정책 thread | policy가 OTHER가 아닌 모든 thread (FIFO/RR/DEADLINE/BATCH/IDLE), RT 우선순위 높은 순 | BSP에 이미 FIFO로 도는 thread가 있는지 (nice 조정으로는 못 이김) |
| 6. 대상 process (인자 줄 때) | thread별 policy, rtprio, nice, 실행 CPU, `schedstat`의 실행/대기 시간, 자발적/비자발적 context switch, thread별 slice(`se.slice`, 개별 slice 설정 시 다름), timer slack(root), 허용 CPU | runqueue 대기(`wait_ms`)가 큰 thread, 선점을 많이 당하는 thread |

## 활용 예: 재생 중 frame drop 분석

```bash
# 1. 보드 기준값 저장 (한 번)
ssh root@<device_ip> 'sh -s' < $S > board_baseline.txt

# 2. 재생 중 player process 상태를 두 번 찍어 thread별 wait_ms 증가량 비교
ssh root@<device_ip> 'sh -s -- <player_process_name>' < $S > t0.txt
#    (이슈 재현)
ssh root@<device_ip> 'sh -s -- <player_process_name>' < $S > t1.txt
```

`wait_ms`가 크게 늘어난 thread가 CPU를 기다린 thread다. 이후 perf sched로 경쟁 task를 찾는 과정은 `../Week4/Lab4/lab3_scheduling_record.md`를 참고한다.

## 참고

- 각 항목의 의미: `../Week4/Lab4/lab3_scheduling_record.md`의 "실제 디바이스에서 먼저 파악할 보드 특성 체크리스트"
- `/proc/<tid>/schedstat`의 wait 값은 kernel에 `CONFIG_SCHED_INFO`가 있어야 채워진다. 0만 나오면 섹션 1의 config를 확인한다.
