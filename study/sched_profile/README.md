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

GitHub의 raw URL을 받아 셸에 바로 넘긴다. 파일이 디바이스에 저장되지 않는다.

- 아래 명령은 이 스크립트를 추가한 커밋으로 **고정**된 URL이다. 나중에 스크립트가 바뀌어도 같은 내용이 실행된다.
- 최신 버전을 쓰려면 URL의 커밋 해시를 브랜치 이름 `study`로 바꾼다.

```bash
URL=https://raw.githubusercontent.com/junsoopark/2026_Linux-Systems-and-Performance_Lecture/067ceadf7d0576d2cc56274cfc784eddc2555db7/study/sched_profile/sched_profile.sh
```

**1) 디바이스에 curl이 있을 때**

```bash
curl -fsSL "$URL" | sh                          # 시스템 전체
curl -fsSL "$URL" | sh -s -- <pid|process_name> # + 특정 process의 thread별 상세
curl -fsSL "$URL" | sh > /tmp/sched_profile.txt # 결과 파일로 저장
```

**2) curl이 없고 wget만 있을 때** (busybox wget은 HTTPS를 지원하지 않는 빌드도 있음)

```bash
wget -qO- "$URL" | sh
wget -qO- "$URL" | sh -s -- <pid|process_name>
```

**3) 디바이스가 인터넷에 못 나갈 때: PC에서 받아 ssh로 넘기기**

PC가 스크립트를 받아 ssh의 표준입력으로 디바이스에 넘긴다. 디바이스에는 ssh 접속만 되면 된다.

```bash
curl -fsSL "$URL" | ssh root@<device_ip> 'sh -s'
curl -fsSL "$URL" | ssh root@<device_ip> 'sh -s -- <pid|process_name>'
curl -fsSL "$URL" | ssh root@<device_ip> 'sh -s' > sched_profile_<board>.txt   # 결과를 PC에 저장
```

**root 권한** (debugfs 항목까지 보려면)

```bash
curl -fsSL "$URL" | sudo sh                     # sudo가 있는 환경
# 디바이스 root 셸이면 그대로 실행하면 된다
```

## 출력 섹션

| 섹션 | 내용 | 무엇을 판단하나 |
| --- | --- | --- |
| 1. kernel | kernel 버전, CFS/EEVDF 구분, `CONFIG_HZ`(config 없으면 jiffies로 HZ 실측), preempt 방식, sched 관련 config | tick 간격, 선점 방식, scheduler 알고리즘 |
| 2. scheduler tunables | `/proc/sys/kernel/sched_*`, RT throttling, debugfs의 slice 관련 값과 features, sched_ext, nice→weight 표 | slice 길이(경쟁 시 frame 지연 크기), RT task 실행 상한 |
| 3. CPU | core 구성, core별 `cpu_capacity`(big.LITTLE), cpufreq governor·주파수, cache, cpuidle 상태별 깨어남 지연 | core 간 성능 차이, 절전으로 인한 wakeup 지연 |
| 4. cgroup | v1/v2 구분, 그룹별 `cpu.weight`/`cpu.max`/`cpuset.cpus`/`uclamp.min` (v1은 `cpu.shares` 등). 기본값과 다른 그룹에 `*` 표시 | player가 속한 그룹에 제한이 걸려 있는지 |
| 5. RT·특수 정책 thread | policy가 OTHER가 아닌 모든 thread (FIFO/RR/DEADLINE/BATCH/IDLE), RT 우선순위 높은 순 | BSP에 이미 FIFO로 도는 thread가 있는지 (nice 조정으로는 못 이김) |
| 6. 대상 process (인자 줄 때) | thread별 policy, rtprio, nice, 실행 CPU, `schedstat`의 실행/대기 시간, 자발적/비자발적 context switch, 허용 CPU | runqueue 대기(`wait_ms`)가 큰 thread, 선점을 많이 당하는 thread |

## 활용 예: 재생 중 frame drop 분석

```bash
# 1. 보드 기준값 저장 (한 번)
curl -fsSL "$URL" | ssh root@<device_ip> 'sh -s' > board_baseline.txt

# 2. 재생 중 player process 상태를 두 번 찍어 thread별 wait_ms 증가량 비교
curl -fsSL "$URL" | ssh root@<device_ip> 'sh -s -- <player_process_name>' > t0.txt
#    (이슈 재현)
curl -fsSL "$URL" | ssh root@<device_ip> 'sh -s -- <player_process_name>' > t1.txt
```

`wait_ms`가 크게 늘어난 thread가 CPU를 기다린 thread다. 이후 perf sched로 경쟁 task를 찾는 과정은 `../Week4/Lab4/lab3_scheduling_record.md`를 참고한다.

## 참고

- 각 항목의 의미: `../Week4/Lab4/lab3_scheduling_record.md`의 "실제 디바이스에서 먼저 파악할 보드 특성 체크리스트"
- `/proc/<tid>/schedstat`의 wait 값은 kernel에 `CONFIG_SCHED_INFO`가 있어야 채워진다. 0만 나오면 섹션 1의 config를 확인한다.
