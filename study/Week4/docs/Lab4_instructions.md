> 원본: `Week4/Lab4/Lab4_instructions.docx` 를 pandoc으로 변환 (명령어 형광펜 → 코드 블록)

이번 실습에서는 CPU의 구조를 프로그램의 실행 시간으로 확인한다.

- 실습 1에서는 working set 크기를 늘려 가며 접근 시간이 급증하는 지점을 찾아 cache 계층의 경계를 확인한다.

- 실습 2에서는 서로 다른 CPU에서 동작하는 두 thread가 같은 cache line을 갱신할 때 생기는 false sharing을 재현한다.

- 실습 3에서는 일정 주기마다(16.7ms) 깨어나는 thread가 같은 CPU의 CPU-bound thread 때문에 실행이 늦어지는 상황을 만들어서 p99 Latency와 deadline miss를 측정하고, perf sched로 경쟁하는 task를 찾는다. 그리고 4개의 조치(nice, cgroup cpu.weight, cpu.max, cpuset)를 수행하면 Latency가 어떻게 달라지는지 비교한다.

WSL2에서는 hardware PMU 사용이 제한되어 cache miss나 IPC 측정이 불가능하고 perf c2c(Cache-to-Cache)도 동작하지 않는다. 그래서 이번 실습의 관측은 모두 실행 시간과 perf sched 기록에 의존하며, 한 번에 한 변수만 바꾸는 통제 실험으로 진행한다. 또한, 각자의 실습 환경이 다르므로 big.LITTLE, cpu_capacity, EAS/uclamp, NUMA 실험도 진행할 수 없다.

## 실습 자료 디렉터리

week4_lab/  
├── Lab4_instructions.docx 안내서와 관측 기록지  
├── README.md  
├── Makefile 빌드  
├── check_env.sh perf, cgroup v2 cpuset, lscpu cache 크기 점검  
├── src/  
│ ├── lab.h  
│ ├── ws_demo.c working set sweep: random pointer chase  
│ ├── fs_demo.c false sharing: 인접 counter vs padding  
│ └── mtwork.c pthread worker: -n 이름, periodic(renderer 역할) / busy(indexer 역할), -c cgroup  
├── tools/  
│ ├── perf_jank.sh perf sched record -a → latency(victim) → timehist(culprit) 자동 추출  
│ ├── fixcg.sh lab/fg, lab/bg cgroup: cpu.weight, cpuset.cpus  
│ ├── perf_profile.sh cpu-clock sampling, thread별 report, flame graph  
│ └── flamegraph.pl, stackcollapse-perf.pl  
├── bin/  
└── logs/ 실행 및 관측 결과

# Week4 실습 자료 가져오기

지난주 GitHub 저장소를 clone한 폴더(\$REPO)를 갱신한 뒤 Week4만 별도의 실습 폴더로 복사한다. course-labs와 week4_lab은 예시 경로 이름이고, 자유롭게 설정할 수 있다.

## 1 터미널 A에서 원본 저장소 확인

``` bash
git pull --ff-only
ls Week4
```

## 2 원본 보관 폴더와 실습 폴더 분리

``` bash
mkdir -p ~/course-labs
if [ ! -e ~/course-labs/week4_lab ]; then
cp -a "$REPO/Week4" ~/course-labs/week4_lab;
fi
cd ~/course-labs/week4_lab
```

*복사본에서만 실행·수정을 권장*

## 3 환경 확인과 빌드

``` bash
bash check_env.sh
make
```

아래는 check_env.sh에서 확인하는 항목이다. 항목의 조건이 만족하지 않을 경우에는 아래와 같이 조치한다.

| **항목** | **필요한 이유** | **조치** |
|----|----|----|
| vCPU 2개 이상 | false sharing과 cpuset 실험에 2개의 CPU를 사용 | %UserProfile%.wslconfig에 \[wsl2\] processors=2를 적고 wsl --shutdown |
| PID 1이 systemd, cgroup v2의 cpu·cpuset controller | 실습 3에서 cgroup으로 간섭 task 제어 | /etc/wsl.conf에 \[boot\] systemd=true를 적고 wsl --shutdown |
| perf sched record 동작 | 실습 3에서 지연된 task와 경쟁 task 식별 | Week 1의 tools/perf.sh와 같은 방법으로 perf 실행 파일 확인 |
| lscpu에 cache 크기 표시 | 실습 1의 예측 기준 | 표시되지 않으면 ws_demo의 접근 시간 변화만으로 진행 |

## 4 터미널 B 준비

``` bash
cd ~/course-labs/week4_lab
```

# 실습 1 Cache와 working set의 크기

강의 32~45쪽

## 목표와 사전 예측

목표: 데이터 크기를 16KB에서 64MB까지 변화시켜 random pointer chase(배열의 각 칸에 다음 칸의 주소를 무작위 순서로 넣어 두고 그 주소를 따라 읽는 방식)의 접근 시간을 측정하고, 접근 시간이 급증하는 데이터 크기를 L1d/L2/L3 cache 크기와 대조해 원인을 분석한다.

``` bash
lscpu | grep -iE 'L1d|L2|L3'
```

예측: 위 명령으로 L1d, L2, L3 크기를 확인한 뒤, working set이 각 경계를 넘을 때 접근당 시간이 대략 몇 배가 될지 적는다. hypervisor 위에서 실행되므로 L3는 다른 vCPU와 공유되어 표시된 크기와 다르게 나타날 수 있다.

내 예측과 이유 \_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_

## 단계별 진행

1\. 16KB부터 64MB까지 크기를 늘려 가며 접근 시간을 측정한다. 크기마다 2천만 번 접근한다.

``` bash
./bin/ws_demo 16 65536 20000000 | tee logs/ws-sweep.txt
```

2\. 출력에서 ns_per_access가 급증하는 세 지점을 찾아 기록지에 적고 lscpu의 cache 크기와 비교한다.

3\. 32KB와 8MB working set을 각각 세 번 반복 측정한다. 실행마다 ns_per_access의 절대값은 조금씩 달라질 수 있으므로, 값 자체보다는 8MB에서 32KB보다 접근 시간이 일관되게 증가하는지를 확인한다. 이를 통해 앞에서 관찰한 cache 계층에 따른 접근 시간 차이가 일시적인 측정 오차가 아니라 반복적으로 나타나는 현상인지 확인한다.

``` bash
for i in 1 2 3; do ./bin/ws_demo 32 32 20000000 | tail -n 1; ./bin/ws_demo 8192 8192 20000000 | tail -n 1; done
```

# 실습 1 핵심 코드와 확인 질문

src/ws_demo.c L40 buffer 전체를 하나의 무작위 순환 경로로 연결하여 다음 접근 주소를 직전에 읽은 값에 의해 결정되게 하였다. 이는 hardware prefetcher나 out-of-order 실행이 이후의 접근을 미리 예측하기 어렵게 하여 실제 cache 접근시간을 측정하기 위함이다.

``` bash
40 *(uint32_t *)(buf + (size_t)i * 64) = next[i]; /* KEY each line stores the index of the next line */
```

src/ws_demo.c L45 실제 pointer chase를 수행하는 부분이다. 각 load가 이전 load의 결과에 의존하므로 여러 memory access를 겹쳐 수행하기 어렵다. 따라서 전체 실행 시간에는 각 memory access의 latency가 직접적으로 반영된다.

``` bash
45 p = *(uint32_t *)(buf + (size_t)p * 64); /* KEY dependent load: latency, not bandwidth */
```

. Q1.1 접근 시간이 급증한 크기와 lscpu의 L1d/L2/L3 크기를 비교하라. 일치하지 않는 경계가 있다면 어떤 요인(hypervisor, 다른 vCPU와의 L3 공유, TLB)을 의심할 수 있는가?

답 \_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_

Q1.2 순차 접근(주소를 64바이트씩 증가)으로 변경하면 위 실습과 동일하게 cache 경계가 뚜렷하게 보이겠는가? 그렇지 않다면 어떤 요인이 memory access latency를 가리는지 설명하라.

답 \_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_

Q1.3 이 실험은 왜 cache miss 횟수가 아니라 실행 시간으로 측정하는가? PMU를 쓸 수 있다면 어떤 event 두 개로 같은 결론을 더 직접 얻을 수 있는가?

답 \_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_

# 실습 2 False sharing

강의 46~47쪽

## 목표와 사전 예측

목표: thread A는 변수 a만, thread B는 변수 b만 증가시키고 두 thread는 서로 다른 CPU에서 실행한다. a와 b가 같은 cache line에 있을 때와 padding으로 다른 cache line에 있을 때의 처리량을 비교한다.

예측: (a) a와 b가 같은 cache line에 있고 CPU 0과 1에서 실행 / (b) padding으로 다른 cache line에 있고 CPU 0과 1에서 실행. 두 조건의 total/s 비율은 어떻게 달라지는가?

내 예측과 이유 \_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_

## 단계별 진행

1\. 두 조건을 3초씩 실행한다. 출력의 distance는 a와 b의 주소 차이(byte)이고 total/s는 두 thread의 증가 횟수 합이다.

``` bash
./bin/fs_demo 3 0 0 1
./bin/fs_demo 3 1 0 1
```

2\. 같은 명령을 한 번씩 더 실행한다. 두 번의 total/s가 서로 비슷하면 측정이 안정적인 것이다. 조건 (a)와 (b)의 total/s를 각각 기록지에 적는다.

관측 기준: a와 b가 같은 cache line에 있는 조건 (a)의 total/s가, padding으로 다른 line에 둔 조건 (b)보다 뚜렷하게 낮게 나와야 한다. 두 조건에서 thread가 실행하는 코드는 완전히 같고, 메모리에서 a와 b가 놓인 위치만 다르다.

3\. 두 thread를 같은 CPU에 두면 차이가 사라지는지 확인한다. 차이의 원인이 코드가 아니라 두 CPU 사이의 cache line 이동임을 보여 주는 통제 실험이다.

``` bash
./bin/fs_demo 3 0 0 0
./bin/fs_demo 3 1 0 0
```

# 실습 2 핵심 코드와 확인 질문

src/fs_demo.c L8 a와 b가 64바이트 cache line 하나에 함께 놓이도록 배치한다.

``` bash
8 volatile uint64_t b; /* KEY same 64-byte line as a */
```

src/fs_demo.c L13 \_Alignas(64)로 b를 다음 cache line으로 밀어내어 a와 b를 다른 cache line에 배치한다.

``` bash
13 _Alignas(64) volatile uint64_t b; /* KEY own cache line */
```

src/fs_demo.c L28 변수값이 1 증가할 때마다 cache line 단위로 write를 수행한다. 다른 CPU가 같은 cache line을 쓰고 있으면 cache line의 소유권이 두 core 사이를 반복해서 이동한다.

``` bash
28 (*a->counter)++; /* KEY every increment writes the line */
```

. Q2.1 (a)와 (b)의 total/s를 예측과 비교하라. 두 thread는 서로 다른 변수를 쓰는데도 서로를 느리게 하는 이유는 무엇인가?

답 \_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_

. Q2.2 cache coherence 관점에서 cache line의 소유권이 두 CPU 사이를 옮겨 가는 과정을 a++, b++ 순서로 설명하라. 같은 CPU에서 차이가 사라지는 이유도 설명하라.

답 \_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_

. Q2.3 실제 코드에서 false sharing이 생기기 쉬운 자료구조를 하나 들고, padding 외의 해결 방법을 하나 명시하라.

답 \_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_

# 실습 3 Scheduling 지연 진단

강의52~64쪽

## 목표와 사전 예측

목표: 16.7ms마다 깨어나 4ms씩 일하는 thread(renderer)와 CPU-bound thread(indexer)를 같은 CPU에서 실행해 p99 latency와 deadline miss를 측정한다. perf sched latency로 renderer의 Max delay를 확인하고, timehist로 해당 지연 시점과 같은 CPU에서 경쟁하는 task를 식별한 뒤, 경쟁 task에 nice, cgroup cpu.weight, cpu.max, cpuset을 적용해서 latency 변화를 비교한다.

예측 1: indexer가 같은 CPU에 있을 때 renderer가 깨어난 뒤 CPU를 받기까지의 Max delay는 몇 ms 정도이겠는가? 두 thread 모두 nice가 0이고, tick이 4ms(HZ=250)이다.

내 예측과 이유 \_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_

예측 2: indexer를 nice를 10으로 낮출 때, cgroup weight 20에 넣을 때, cpu.max를 30%로 제한할 때, CPU 1로 옮길 때 latency와 deadline miss는 각각 어떻게 되겠는가? 네 가지 중 renderer의 delay된 latency를 가장 확실히 없애는 방법과 indexer가 가장 큰 비용을 치르는 방법은 무엇인가?

내 예측과 이유 \_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_

## 단계별 진행

1\. 터미널 B에서 indexer를, A에서 renderer를 CPU 0에서 같이 실행한다. renderer 출력에서 iters(기대값 약 600), late_p99u(깨어난 시각이 기한보다 늦은 정도의 p99), miss(frame이 다음 기한을 넘긴 횟수), wait_ms를 기록한다.

``` bash
./bin/mtwork -d 14 -n indexer busy,cpu=0
```

``` bash
./bin/mtwork -d 10 -n renderer periodic:16667:4000,cpu=0
```

2\. 두 프로그램이 실행되는 동안 세 번째 터미널에서 perf sched로 8초간 기록한다. Script는 perf sched latency에서 renderer의 Max delay를 찾고, timehist에서 같은 scheduling delay가 발생한 시점과 그 직전 같은 CPU에서 실행되고 있던 경쟁 task를 출력한다.

``` bash
bash tools/perf_jank.sh base 8
```

관측 기준: 먼저 perf sched latency에서 renderer의 Max delay를 확인한다. 이어서 timehist에서 같은 값의 sch_delay(ms)가 나타나는 renderer-0 줄을 확인하고, 그 직전 동일 CPU의 기록에서 indexer-0이 ms 단위의 run(ms)으로 실행되고 있었는지 확인한다. renderer가 실제로 사용한 CPU 시간은 iters × 4 ms 정도로 작지만 scheduling latency가 증가한 것은 CPU를 오래 사용했기 때문이 아니라 runnable 상태에서 CPU를 기다렸기 때문이다. miss가 0보다 크다면 그 수만큼의 frame이 다음 화면 갱신 시점을 놓친 것을 의미한다.

3\. 조치 A: nice value 조정. indexer의 TID(TIDS 줄)에 renice를 적용한다. nice는 thread 단위 속성이므로 PID가 아니라 TID를 지정해야 한다. 1~2번을 반복해 renderer의 late_p99u, miss, perf Max delay를 다시 기록한다.

``` bash
./bin/mtwork -d 14 -n indexer busy,cpu=0 # B: TIDS 줄의 번호를 아래에
sudo renice -n 10 -p <indexer TID> # 세 번째 터미널
./bin/mtwork -d 10 -n renderer periodic:16667:4000,cpu=0 # A
bash tools/perf_jank.sh nice 8
```

4\. 조치 B: cgroup cpu.weight 조정. lab/fg(weight 100)와 lab/bg(weight 20)를 만들고 -c 옵션으로 각 프로그램을 자기 group에 넣어 시작한다. weight는 형제 group 사이의 비율이므로 두 process가 형제 group에 있어야 한다.

``` bash
sudo bash tools/fixcg.sh setup 20
sudo ./bin/mtwork -d 14 -n indexer -c lab/bg busy,cpu=0 # B
sudo ./bin/mtwork -d 10 -n renderer -c lab/fg periodic:16667:4000,cpu=0 # A
bash tools/perf_jank.sh weight 8
```

5\. 조치 C: cgroup cpu.max 조정. weight를 100으로 되돌리고 lab/bg에 100ms마다 30ms(CPU 하나의 30%)의 상한을 건다. indexer가 quota를 다 쓰면 period가 끝날 때까지 throttle되고, 그동안 renderer가 CPU를 받는다. 실행 후 B에서 lab/bg의 cpu.stat에서 nr_throttled를 확인한다.

``` bash
sudo bash tools/fixcg.sh setup 100
sudo bash tools/fixcg.sh max 30000 100000
sudo ./bin/mtwork -d 14 -n indexer -c lab/bg busy,cpu=0 # B
sudo ./bin/mtwork -d 10 -n renderer -c lab/fg periodic:16667:4000,cpu=0 # A
bash tools/perf_jank.sh max 8
cat /sys/fs/cgroup/lab/bg/cpu.stat
```

6\. 조치 D: cpuset으로 두 thread가 동작하는 CPU 분리. cpu.max 상한을 해제하고 lab/bg를 CPU 1로 제한한다. indexer는 pin 없이 시작해도 cpuset 때문에 CPU 1에서 실행되고, cpu=0을 주면 cpuset과 충돌해 affinity 설정이 거부된다.

``` bash
sudo bash tools/fixcg.sh max max 100000
sudo bash tools/fixcg.sh cpuset 1
sudo ./bin/mtwork -d 14 -n indexer -c lab/bg busy # B: ps -L -o tid,psr 로 PSR 확인
sudo ./bin/mtwork -d 10 -n renderer -c lab/fg periodic:16667:4000,cpu=0 # A
bash tools/perf_jank.sh cpuset 8
```

7\. 정리. 다섯 조건의 renderer late_p99u, miss, perf Max delay, indexer cpu_ms를 기록지 표에 채운다.

``` bash
sudo bash tools/fixcg.sh teardown
```

# 실습 3 핵심 코드와 확인 질문

src/mtwork.c L269 deadline miss 집계. frame이 다음 기한을 넘겨 끝나면 miss로 측정된다. 화면이라면 그 frame은 다음 갱신에 들어가지 못한다.

``` bash
272 sched_yield(); /* KEY dl: give back the rest of the period */
```

src/mtwork.c L280 renderer의 주기 대기. 다음 기한까지 잠들었다가 깨어나며, 깨어난 시각과 기한의 차이가 late_p99u이다.

``` bash
280 wait_item(&next); /* KEY off-CPU part of the period */
```

tools/perf_jank.sh L31 perf sched record -a. 모든 CPU의 sched_switch와 sched_wakeup event를 기록해 perf.data를 만든다.

``` bash
31 sudo perf sched record -a -o "$data" -- sleep "$secs"
```

tools/perf_jank.sh L67-L85 timehist에서 renderer의 sch delay가 가장 큰 event를 찾고, 해당 시점의 time, CPU, delay를 추출한다.

``` bash
67 worst=$(awk -v v="$victim" '
68 $3 ~ v && $5+0 > max {
69 max = $5 + 0
70 line = $0
71 }
72 END { print line }
75 ' "$timehist")
```

tools/perf_jank.sh L96-L114 timehist의 worst sch delay와 perf sched latency의 Max delay가 같은 row를 찾는다. WSL에서는 task 이름이 비어 있을 수 있어 delay 값으로 보조 비교하며, 값이 일치하지 않으면 row를 찾지 못할 수 있다.

``` bash
96 victim_lat=$(awk -v d="$worst_delay" '
99 if ($i == "max:") {
100 val = $(i+1) + 0
107 if (diff < 0.001) {
108 print
109 exit
110 }
114 ' "$latency")
```

tools/perf_jank.sh L144-L157 worst delay 시점과 같은 CPU의 event만 별도 counter로 저장해 최근 event를 시간 순서대로 출력한다. renderer 직전에 CPU를 사용한 task를 확인해 경쟁 task를 찾는다.

``` bash
144 awk -v t="$worst_time" -v cpu="$worst_cpu" '
145 $2 == cpu {
146 n++
147 history[n % 5] = $0
149 if ($1 == t) {
150 for (i = n - 4; i <= n; i++)
152 if (i > 0) print history[i % 5]
157 ' "$timehist" | format_timehist
```

tools/fixcg.sh L18 경쟁 task가 속한 group의 cpu.weight. 형제 group(fg, 100) 대비 비율로 CPU 시간을 나눈다.

``` bash
18 echo "${2:-20}" > "$lab/bg/cpu.weight" # KEY culprit's share among siblings
```

tools/fixcg.sh L23 cpu.max. period마다 quota만큼만 실행을 허용하고, quota를 다 쓰면 group 전체가 period 끝까지 throttle된다.

``` bash
23 echo "${2:?quota_us} ${3:?period_us}" > "$lab/bg/cpu.max" # KEY hard cap on the culprit: quota per period
```

tools/fixcg.sh L27 cpuset.cpus. 경쟁 task를 다른 CPU로 보낸다. task 자신의 affinity 설정보다 우선한다.

``` bash
27 echo "${2:?cpus}" > "$lab/bg/cpuset.cpus" # KEY move the culprit to other CPUs, overriding its affinity
```

Q3.1 기본 조건의 renderer의 Max delay, late_p99u, miss를 예측 1과 비교하라. renderer의 CPU 사용률은 약 25%에 불과한데도 지연이 발생하는 이유는 무엇인가? 또한 CPU 사용률만으로는 이 문제를 발견하기 어려운 이유를 자신의 측정 결과를 바탕으로 설명하라.

답 \_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_

Q3.2 네 가지 조치를 적용했을 때 renderer의 perf Max delay, late_p99u, miss와 indexer의 cpu_ms가 어떻게 변했는지 비교하라. nice와 cpu.weight가 비슷한 방향의 효과를 보이는 이유와 각각의 적용 단위(thread vs. group)를 설명하라. 또한 cpu.max가 cpu.weight와 어떻게 다른지, 그리고 cpuset이 renderer의 지연을 가장 확실하게 줄일 수 있음에도 일반적으로 마지막 수단으로 사용하는 이유를 설명하라.

답 \_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_

Q3.3 renderer를 SCHED_FIFO로 변경하면 scheduling latency를 크게 줄일 수 있다. 그럼에도 경쟁 task의 scheduling policy나 priority를 먼저 조정하고 SCHED_FIFO는 마지막에 고려해야 하는 이유를 설명하라. 또한 이 실습에서 renderer를 SCHED_FIFO로 실행했을 때 indexer와 같은 CPU에서 실행되는 shell 등의 일반 task에 어떤 영향을 줄 수 있는지 설명하라.

답 \_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_

# 관측 기록지

이름 \_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_ 실행 환경 \_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_ 날짜 \_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_

CPU 모델 \_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_ L1d \_\_\_\_\_\_ L2 \_\_\_\_\_\_ L3 \_\_\_\_\_\_ nproc \_\_\_\_\_\_

## 1 Cache 계층

| **변화 지점** | **크기 (KB)** | **ns/access (이전)** | **ns/access (이후)** | **대응하는 cache** | **일치 여부** |
|----|----|----|----|----|----|
| 1 |  |  |  | L1d |  |
| 2 |  |  |  | L2 |  |
| 3 |  |  |  | L3 |  |

32KB 3회 \_\_\_\_\_\_ / \_\_\_\_\_\_ / \_\_\_\_\_\_ ns 8MB 3회 \_\_\_\_\_\_ / \_\_\_\_\_\_ / \_\_\_\_\_\_ ns

## 2 False sharing (total/s)

| **조건** | **예측 비율** | **total/s 1회** | **total/s 2회** | **distance (byte)** |
|----|----|----|----|----|
| \(a\) 같은 line, CPU 0/1 |  |  |  |  |
| \(b\) padding, CPU 0/1 |  |  |  |  |
| \(c\) 같은 line, CPU 0/0 |  |  |  |  |
| \(d\) padding, CPU 0/0 |  |  |  |  |

## 3 Scheduling 지연 진단

기본 조건: Max delay가 가장 큰 task \_\_\_\_\_\_\_\_\_\_\_\_\_\_ (Max delay \_\_\_\_\_\_ ms) 경쟁 task \_\_\_\_\_\_\_\_\_\_\_\_\_\_ (직전 run \_\_\_\_\_\_ ms, CPU \_\_\_\_\_\_)

| **조건** | **예측 latency** | **renderer late_p99u** | **miss** | **perf Max delay (ms)** | **indexer cpu_ms** |
|----|----|----|----|----|----|
| 기본 (둘 다 nice 0, CPU 0) |  |  |  |  |  |
| A: indexer nice 10 |  |  |  |  |  |
| B: lab/bg cpu.weight 20 |  |  |  |  |  |
| C: lab/bg cpu.max 30% |  |  |  |  |  |
| D: lab/bg cpuset 1 |  |  |  |  |  |

조치 C의 lab/bg cpu.stat: nr_throttled \_\_\_\_\_\_ throttled_usec \_\_\_\_\_\_

실습을 마치면 fixcg.sh teardown이 완료되어 /sys/fs/cgroup/lab이 남아 있지 않아야 한다.
