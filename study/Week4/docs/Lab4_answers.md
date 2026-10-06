> 원본: `Week4/Lab4/Lab4_answers.docx` 를 pandoc으로 변환 (명령어 형광펜 → 코드 블록)

Lab4_instructions.docx의 Q1.1부터 Q3.3까지의 모범 답안이다. 파란색이 정답이다. 수치는 CPU와 hypervisor에 따라 다르므로 관계와 근거로 채점한다.

# 실습 1 Cache와 working set의 크기

**Q1.1 접근 시간이 급증한 크기와 lscpu의 L1d/L2/L3 크기를 비교하라. 일치하지 않는 경계가 있다면 어떤 요인(hypervisor, 다른 vCPU와의 L3 공유, TLB)을 의심할 수 있는가?**

정답 L1 경계(보통 32~48KB)와 L2 경계(수백 KB~2MB)는 lscpu 값 근처에서 접근 시간이 급증한다. L3 경계는 lscpu가 물리 L3 전체 크기를 보이지만 실제로는 다른 vCPU와 Windows의 다른 process가 L3를 공유하므로 표시된 크기보다 작은 지점에서 접근 시간이 오르기 시작한다. 또한, 데이터의 크기가 수 MB를 넘으면 4KB page마다 TLB entry가 필요해 TLB miss가 섞이고, page walk 비용이 L3 hit에 가려져서 경계가 완만해진다. 2MB huge page를 쓰면 이 부분이 사라진다.

**Q1.2 순차 접근(주소를 64바이트씩 증가)으로 변경하면 위 실습과 동일하게 cache 경계가 뚜렷하게 보이겠는가? 그렇지 않다면 어떤 요인이 memory access latency를 가리는지 설명하라.**

정답 거의 안 보이지 않는다. 순차 접근은 hardware prefetcher가 다음 line을 미리 가져오고, 주소가 이전 load 결과에 의존하지 않으므로 out-of-order 실행이 여러 load를 겹쳐 진행한다. 그래서 DRAM 크기에서도 접근당 시간이 latency가 아니라 대역폭으로 결정된다. pointer chase는 다음 주소가 이전 load의 값이라 load를 겹칠 수 없고 prefetcher도 무작위 순서를 예측하지 못하므로 latency가 그대로 드러난다. 이것이 실제 프로그램에서 linked list나 tree 순회가 배열 순회보다 느린 이유이다.

**Q1.** **이 실험은 왜 cache miss 횟수가 아니라 실행 시간으로 측정하는가? PMU를 쓸 수 있다면 어떤 event 두 개로 같은 결론을 더 직접 얻을 수 있는가?**

정답 WSL2는 Hyper-V가 PMU를 vCPU에 노출하지 않아 perf의 hardware event가 지원되지 않는다. 그래서 miss를 직접 측정하지 못하고 miss로 인해 증가된 시간을 측정하였다. 시간은 miss 외에 interrupt, hypervisor, 다른 process의 간섭을 함께 담으므로 통제 실험과 반복 측정이 필요하다. PMU가 있다면 cache-misses(또는 L1-dcache-load-misses, LLC-load-misses)와 cycles(또는 instruction으로 IPC)를 보면 크기별로 miss rate가 증가하는 지점과 IPC가 떨어지는 지점이 cache 경계와 일치하는 것을 직접 확인할 수 있다.

# 실습 2 False sharing

**Q2.1 (a)와 (b)의 total/s를 예측과 비교하라. 두 thread는 서로 다른 변수를 쓰는데도 서로를 느리게 하는 이유는 무엇인가?**

정답 (b) padding이 (a) 같은 cache line보다 높다. 두 thread의 코드와 작업량은 같고 a와 b의 distance만 다르다. coherence의 단위는 변수가 아니라 64바이트 cache line이다. (a)에서는 a와 b가 한 cache line에 있어서 CPU 0이 a를 쓰려면 cache line을 독점해야 하고, 그 순간 CPU 1의 복사본이 무효화되며, CPU 1이 b를 쓰려면 다시 cache line의 소유권을 가져와야 한다. 두 변수는 논리적으로 무관하지만 물리적으로 같은 cache line이므로 하드웨어가 하나로 취급한다.

**Q2.2 cache coherence 관점에서 cache line의 소유권이 두 CPU 사이를 옮겨 가는 과정을 a++, b++ 순서로 설명하라. 같은 CPU에서 차이가 사라지는 이유도 설명하라.**

정답 CPU 0이 a++를 하려면 cache line을 Modified 상태로 독점해야 하므로 CPU 1에 invalidate를 보낸다(CPU 1의 복사본은 Invalid). 이어서 CPU 1이 b++를 하려면 cache line이 자기에게 없으므로 CPU 0에서 최신 cache line을 받아와(CPU 0은 Invalid) Modified로 변경한다. 다음 a++에서 다시 반대 방향 전송이 일어난다. 매 증가마다 코어 간 interconnect를 거치는 전송이 생기고 각 전송은 L1 hit보다 수십 배 느리다. 같은 CPU에 두 thread를 두면 둘이 번갈아 실행되므로 cache line이 한 코어의 cache에만 있고 소유권 이동이 발생하지 않는다. 이 결과를 통해 차이의 원인이 두 코어 사이의 cache line 이동임을 알 수 있다.

**Q2.3 실제 코드에서 false sharing이 생기기 쉬운 자료구조를 하나 들고, padding 말고 다른 해결 방법을 하나 들어라.**

정답 thread별 통계 counter를 배열 하나에 나란히 둔 경우(stats\[thread_id\]++), spinlock과 그 lock이 보호하는 자주 쓰는 데이터를 같은 struct에 붙여 둔 경우, producer와 consumer의 index를 같은 ring buffer 헤더에 둔 경우 등이 있다. padding 외의 해결은 thread별 local 변수에 누적했다가 끝에 한 번 합치는 것, 자주 쓰는 필드와 읽기 전용 필드를 다른 struct로 나누는 것, per-CPU 자료구조를 쓰는 것 등이 있다. kernel의 per-CPU counter가 같은 원리다.

# 실습 3 Scheduling 지연 진단

**Q3.1 기본 조건의 renderer의 Max delay, late_p99u, miss를 예측 1과 비교하라. renderer의 CPU 사용률은 약 25%에 불과한데도 지연이 발생하는 이유는 무엇인가? 또한 CPU 사용률만으로는 이 문제를 발견하기 어려운 이유를 자신의 측정 결과를 바탕으로 설명하라.**

정답 renderer는 16.7ms마다 약 4ms 실행하므로 평균 CPU 사용률은 약 24%이다. 하지만 같은 CPU에서 indexer가 실행 중이면 renderer가 깨어나도 바로 CPU를 받지 못하고 runqueue에서 기다릴 수 있다. 이때 Max delay와 late_p99u가 증가하고, 지연과 4ms 작업 시간이 합쳐져 16.7ms를 넘으면 miss가 발생한다. CPU 사용률은 평균값이라 이런 순간적인 sch delay를 보여주지 못한다.

**Q3.2 네 가지 조치를 적용했을 때 renderer의 perf Max delay, late_p99u, miss와 indexer의 cpu_ms가 어떻게 변했는지 비교하라. nice와 cpu.weight가 비슷한 방향의 효과를 보이는 이유와 각각의 적용 단위(thread or group)를 설명하라. 또한 cpu.max가 cpu.weight와 어떻게 다른지, 그리고 cpuset이 renderer의 지연을 가장 확실하게 줄일 수 있음에도 일반적으로 마지막 수단으로 사용하는 이유를 설명하라.**

정답 nice와 cpu.weight는 모두 상대적인 scheduler weight를 낮춰 indexer의 CPU 몫을 줄이므로 renderer의 지연과 miss가 감소한다. nice는 thread 단위, cpu.weight는 cgroup 단위이다. cpu.max는 상대 비율이 아니라 절대 상한이라 CPU가 남아 있어도 quota를 다 쓰면 indexer를 throttle한다. cpuset은 indexer를 다른 CPU로 보내 지연을 가장 확실히 줄이지만 load balancing을 제한하므로 마지막 수단으로 사용한다.

**Q3.3 renderer를 SCHED_FIFO로 변경하면 scheduling latency를 크게 줄일 수 있다. 그럼에도 경쟁 task의 scheduling policy나 priority를 먼저 조정하고 SCHED_FIFO는 마지막에 고려해야 하는 이유를 설명하라. 또한 이 실습에서 renderer를 SCHED_FIFO로 실행했을 때 indexer와 같은 CPU에서 실행되는 shell 등의 일반 task에 어떤 영향을 줄 수 있는지 설명하라.**

정답 renderer를 SCHED_FIFO로 올리면 RT class가 fair class보다 우선하므로 indexer를 즉시 선점해 지연을 크게 줄일 수 있다. 하지만 이는 원인을 없애는 것이 아니라 victim의 우선순위를 높이는 방법이며, RT task가 오래 실행되면 indexer나 shell 같은 일반 task를 굶길 수 있다. 따라서 먼저 경쟁 task의 nice나 cgroup policy를 조정하고, 그래도 필요한 경우에만 RT scheduling을 사용하는 것이 적절하다.
