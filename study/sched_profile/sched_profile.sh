#!/bin/sh
# sched_profile.sh — 타겟 디바이스의 scheduling 관련 속성과 값을 한 번에 수집한다.
#
# - POSIX sh (busybox ash, dash, bash) 에서 동작. /proc, /sys 만 읽고 아무것도 변경하지 않는다.
# - root가 아니면 debugfs(/sys/kernel/debug/sched) 항목은 "(no permission)"으로 표시된다.
#
# usage:
#   sh sched_profile.sh                 시스템 전체 정보
#   sh sched_profile.sh <pid|name>      + 해당 process의 thread별 정책/우선순위/대기 시간
#
# 섹션: 1 kernel  2 scheduler tunables  3 CPU topology/freq/idle  4 cgroup
#       5 RT·특수 정책 thread 목록  6 대상 process thread 상세 (인자 있을 때)

TARGET=$1

hr()   { printf '\n==== %s ====\n' "$1"; }
sub()  { printf -- '-- %s\n' "$1"; }
kv()   { printf '%-34s %s\n' "$1" "$2"; }

# 파일 하나 읽기: 없으면 -, 권한 없으면 (no permission)
rd() {
    if [ ! -e "$1" ]; then printf '%s' '-'
    elif [ ! -r "$1" ]; then printf '%s' '(no permission)'
    else tr '\n' ' ' < "$1" 2>/dev/null | sed 's/ *$//' || printf '%s' '(no permission)'
    fi
}
show() { kv "$1" "$(rd "$2")"; }   # show <label> <file>
have() { command -v "$1" >/dev/null 2>&1; }

policy_name() {
    case $1 in
        0) echo OTHER ;; 1) echo FIFO ;; 2) echo RR ;; 3) echo BATCH ;;
        5) echo IDLE ;; 6) echo DEADLINE ;; 7) echo EXT ;; *) echo "?$1" ;;
    esac
}

# /proc/<pid>/task/<tid>/stat 에서 필드 추출. comm에 공백이 있을 수 있으므로 ") " 이후로 자른다.
# 자른 뒤 $1 = 원래 3번 필드(state). 원래 n번 필드 = 자른 뒤 (n-2)번.
#   prio(18)->16 nice(19)->17 processor(39)->37 rt_priority(40)->38 policy(41)->39
stat_fields() { sed 's/^.*) //' "$1" 2>/dev/null; }

# ------------------------------------------------------------------ 1
hr "1. kernel"
kv "date" "$(date 2>/dev/null)"
kv "hostname" "$(rd /proc/sys/kernel/hostname)"
kv "uname -a" "$(uname -a 2>/dev/null)"
krel=$(uname -r 2>/dev/null)
kmaj=$(echo "$krel" | cut -d. -f1); kmin=$(echo "$krel" | cut -d. -f2 | tr -dc '0-9')
if [ -n "$kmaj" ] && [ -n "$kmin" ]; then
    if [ "$kmaj" -gt 6 ] || { [ "$kmaj" -eq 6 ] && [ "$kmin" -ge 6 ]; }; then
        kv "fair scheduler (by version)" "EEVDF (>= 6.6)"
    else
        kv "fair scheduler (by version)" "CFS (< 6.6)"
    fi
fi

sub "kernel config (HZ, preempt, sched features)"
cfg=""
if [ -r /proc/config.gz ] && have zcat; then cfg="zcat /proc/config.gz"
elif [ -r "/boot/config-$krel" ]; then cfg="cat /boot/config-$krel"
fi
if [ -n "$cfg" ]; then
    kv "config source" "${cfg#* }"
    $cfg 2>/dev/null | grep -E '^(CONFIG_HZ=|CONFIG_HZ_[0-9]+=|CONFIG_NO_HZ[A-Z_]*=|CONFIG_PREEMPT[A-Z_]*=|CONFIG_SCHED_[A-Z_]*=|CONFIG_FAIR_GROUP_SCHED=|CONFIG_RT_GROUP_SCHED=|CONFIG_CGROUP_SCHED=|CONFIG_CFS_BANDWIDTH=|CONFIG_UCLAMP_TASK[A-Z_]*=|CONFIG_ENERGY_MODEL=|CONFIG_CPU_FREQ_DEFAULT_GOV_[A-Z_]*=|CONFIG_CPU_IDLE=|CONFIG_SCHEDSTATS=|CONFIG_SCHED_DEBUG=)' \
        | sed 's/^/  /'
else
    echo "  (kernel config not available: /proc/config.gz, /boot/config-$krel 없음)"
fi
kv "preempt (uname -v)" "$(uname -v 2>/dev/null | grep -oE 'PREEMPT[A-Z_]*( RT)?|PREEMPT_DYNAMIC' | tr '\n' ' ')"

# ------------------------------------------------------------------ 2
hr "2. scheduler tunables"
sub "/proc/sys/kernel/sched_* (CFS 시절 tunable은 5.13부터 debugfs로 이동)"
found=0
for f in /proc/sys/kernel/sched_*; do
    [ -e "$f" ] || continue
    found=1; show "${f##*/}" "$f"
done
[ $found -eq 0 ] && echo "  (none)"

sub "RT throttling"
show "sched_rt_period_us" /proc/sys/kernel/sched_rt_period_us
show "sched_rt_runtime_us" /proc/sys/kernel/sched_rt_runtime_us

sub "/sys/kernel/debug/sched (root + debugfs 필요)"
D=/sys/kernel/debug/sched
if [ -d "$D" ] || [ -d /sys/kernel/debug ]; then
    for n in base_slice_ns latency_ns min_granularity_ns wakeup_granularity_ns \
             tunable_scaling migration_cost_ns nr_migrate preempt verbose; do
        [ -e "$D/$n" ] && show "$n" "$D/$n"
    done
    [ -e "$D/features" ] && { kv "features" ""; rd "$D/features" | tr ' ' '\n' | grep -v '^$' | paste -sd' ' - 2>/dev/null | fold -w 100 | sed 's/^/  /'; }
    [ -r "$D" ] || echo "  (no permission: sudo로 다시 실행하면 base_slice_ns, preempt, features 확인 가능)"
else
    echo "  (debugfs not mounted: mount -t debugfs none /sys/kernel/debug)"
fi

sub "sched_ext"
show "sched_ext state" /sys/kernel/sched_ext/state

sub "nice -> weight (kernel/sched/core.c sched_prio_to_weight, 2.6.23부터 고정값)"
echo "  nice -20:88761 -10:9548 -5:3121 0:1024 1:820 5:335 10:110 15:36 19:15  (한 단계 ≈ 1.25배, CPU 시간 ≈ 10%)"

# ------------------------------------------------------------------ 3
hr "3. CPU topology / frequency / idle"
kv "online" "$(rd /sys/devices/system/cpu/online)"
kv "possible" "$(rd /sys/devices/system/cpu/possible)"
if have lscpu; then
    lscpu 2>/dev/null | grep -E '^(Architecture|Model name|CPU\(s\)|Thread|Core|Socket|Cluster|L1d|L1i|L2|L3|NUMA node\(s\))' | sed 's/^/  /'
else
    grep -m1 -E '^(model name|Hardware|Processor)' /proc/cpuinfo 2>/dev/null | sed 's/^/  /'
fi

sub "per-CPU (capacity: big.LITTLE면 core마다 다름)"
printf '  %-5s %-6s %-5s %-7s %-8s %-14s %-10s %-10s %-10s\n' cpu online core cluster capacity governor cur_kHz min_kHz max_kHz
for c in /sys/devices/system/cpu/cpu[0-9]*; do
    n=${c##*/cpu}
    on=$(rd "$c/online"); [ "$on" = "-" ] && on=1
    printf '  %-5s %-6s %-5s %-7s %-8s %-14s %-10s %-10s %-10s\n' "$n" "$on" \
        "$(rd "$c/topology/core_id")" "$(rd "$c/topology/cluster_id")" "$(rd "$c/cpu_capacity")" \
        "$(rd "$c/cpufreq/scaling_governor")" "$(rd "$c/cpufreq/scaling_cur_freq")" \
        "$(rd "$c/cpufreq/scaling_min_freq")" "$(rd "$c/cpufreq/scaling_max_freq")"
done
kv "SMT siblings (cpu0)" "$(rd /sys/devices/system/cpu/cpu0/topology/thread_siblings_list)"
kv "available governors" "$(rd /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors)"
kv "cpufreq driver" "$(rd /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver)"
kv "energy_performance_preference" "$(rd /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference)"

sub "cache (cpu0)"
for i in /sys/devices/system/cpu/cpu0/cache/index*; do
    [ -d "$i" ] || continue
    kv "  L$(rd "$i/level") $(rd "$i/type")" "size=$(rd "$i/size") ways=$(rd "$i/ways_of_associativity") line=$(rd "$i/coherency_line_size") shared=$(rd "$i/shared_cpu_list")"
done

sub "cpuidle (cpu0) — latency(us)가 클수록 깨어날 때 늦음"
gov=/sys/devices/system/cpu/cpuidle/current_governor; [ -e "$gov" ] || gov=${gov}_ro
kv "cpuidle driver/governor" "$(rd /sys/devices/system/cpu/cpuidle/current_driver) / $(rd "$gov")"
for s in /sys/devices/system/cpu/cpu0/cpuidle/state*; do
    [ -d "$s" ] || continue
    kv "  ${s##*/} $(rd "$s/name")" "latency=$(rd "$s/latency")us residency=$(rd "$s/residency")us disable=$(rd "$s/disable")"
done

# ------------------------------------------------------------------ 4
hr "4. cgroup"
CG=/sys/fs/cgroup
if grep -q ' cgroup2 ' /proc/mounts 2>/dev/null && [ -e "$CG/cgroup.controllers" ]; then
    kv "version" "v2 (unified)"
    show "root controllers" "$CG/cgroup.controllers"
    show "root subtree_control" "$CG/cgroup.subtree_control"
    sub "1·2단계 그룹: cpu.weight / cpu.max / cpuset.cpus / uclamp.min  (* = 기본값과 다름, systemd .mount/.socket/.swap 제외)"
    printf '  %-1s %-48s %-7s %-16s %-10s %s\n' '' group weight max cpuset uclamp.min
    for g in "$CG"/*/ "$CG"/*/*/; do
        [ -e "$g/cgroup.procs" ] || continue
        rel=${g#$CG/}; rel=${rel%/}
        case $rel in *.mount|*.socket|*.swap) continue ;; esac
        w=$(rd "$g/cpu.weight"); m=$(rd "$g/cpu.max"); c=$(rd "$g/cpuset.cpus"); u=$(rd "$g/cpu.uclamp.min")
        mark=""
        { [ "$w" != 100 ] && [ "$w" != - ]; } && mark='*'
        case $m in max\ *|-) ;; *) mark='*' ;; esac
        { [ -n "$c" ] && [ "$c" != - ]; } && mark='*'
        case $u in 0.00|-|'') ;; *) mark='*' ;; esac
        printf '  %-1s %-48s %-7s %-16s %-10s %s\n' "$mark" "$rel" "$w" "$m" "$c" "$u"
    done
else
    kv "version" "v1 (or hybrid)"
    grep cgroup /proc/mounts 2>/dev/null | awk '{print "  " $2 " " $4}'
    for d in "$CG/cpu" "$CG/cpu,cpuacct"; do
        [ -d "$d" ] || continue
        sub "$d: cpu.shares / cfs_quota_us / rt_runtime_us"
        printf '  %-40s %-8s %-10s %s\n' group shares quota_us rt_runtime_us
        for g in "$d" "$d"/*/; do
            [ -e "$g/cpu.shares" ] || continue
            rel=${g#$d}; rel=${rel%/}; [ -z "$rel" ] && rel=/
            printf '  %-40s %-8s %-10s %s\n' "$rel" "$(rd "$g/cpu.shares")" "$(rd "$g/cpu.cfs_quota_us")" "$(rd "$g/cpu.rt_runtime_us")"
        done
        break
    done
    for d in "$CG/cpuset"; do
        [ -d "$d" ] || continue
        sub "$d: cpuset.cpus"
        for g in "$d" "$d"/*/; do
            [ -e "$g/cpuset.cpus" ] && printf '  %-40s %s\n' "${g#$d}" "$(rd "$g/cpuset.cpus")"
        done
    done
fi

# ------------------------------------------------------------------ 5
hr "5. RT / 특수 정책 thread (policy != OTHER) — BSP의 FIFO thread 확인용"
echo "  정렬: policy(FIFO/RR → DEADLINE → BATCH/IDLE), rtprio 높은 순"
printf '  %-8s %-8s %-9s %-6s %-5s %-4s %s\n' pid tid policy rtprio nice cpu comm
for t in /proc/[0-9]*/task/[0-9]*; do
    st="$t/stat"; [ -r "$st" ] || continue
    set -- $(stat_fields "$st")
    pol=${39:-0}; [ "$pol" = 0 ] && continue
    pid=${t#/proc/}; pid=${pid%%/*}; tid=${t##*/}
    case $pol in 1|2) rank=1 ;; 6) rank=2 ;; *) rank=3 ;; esac
    printf '%s %03d  %-8s %-8s %-9s %-6s %-5s %-4s %s\n' "$rank" "$((99 - ${38}))" "$pid" "$tid" "$(policy_name "$pol")" "${38}" "${17}" "${37}" "$(rd "$t/comm")"
done | sort -k1,1n -k2,2n -k3,3n | cut -d' ' -f3- | sed 's/^/ /' > "${TMPDIR:-/tmp}/sched_profile.$$"
cat "${TMPDIR:-/tmp}/sched_profile.$$"
echo "  total: $(wc -l < "${TMPDIR:-/tmp}/sched_profile.$$" | tr -d ' ') threads"
rm -f "${TMPDIR:-/tmp}/sched_profile.$$"

# ------------------------------------------------------------------ 6
if [ -n "$TARGET" ]; then
    hr "6. target process: $TARGET"
    case $TARGET in
        *[!0-9]*) pids=$(for p in /proc/[0-9]*; do [ "$(rd "$p/comm")" = "$TARGET" ] && echo "${p#/proc/}"; done) ;;
        *) pids=$TARGET ;;
    esac
    [ -z "$pids" ] && echo "  (no process: $TARGET)"
    for pid in $pids; do
        [ -d "/proc/$pid" ] || { echo "  (no pid $pid)"; continue; }
        sub "pid $pid ($(rd /proc/$pid/comm))  cmdline: $(tr '\0' ' ' < /proc/$pid/cmdline 2>/dev/null | cut -c1-120)"
        kv "  cgroup" "$(rd /proc/$pid/cgroup)"
        kv "  Cpus_allowed_list" "$(grep Cpus_allowed_list /proc/$pid/status 2>/dev/null | awk '{print $2}')"
        echo "  exec_ms/wait_ms/slices: /proc/<tid>/schedstat 누적값 (wait = runqueue 대기). vol/invol = 자발적/비자발적 context switch"
        printf '  %-8s %-16s %-9s %-6s %-5s %-4s %-10s %-10s %-8s %-8s %-8s %s\n' \
            tid comm policy rtprio nice cpu exec_ms wait_ms slices vol invol allowed
        for t in /proc/$pid/task/[0-9]*; do
            set -- $(stat_fields "$t/stat")
            pol=${39:-0}; tprio=${38}; tnice=${17}; tcpu=${37}
            ss=$(rd "$t/schedstat")
            ex=$(echo "$ss" | awk '{printf "%.1f", $1/1e6}'); wt=$(echo "$ss" | awk '{printf "%.1f", $2/1e6}'); sl=$(echo "$ss" | awk '{print $3}')
            vol=$(grep '^voluntary_ctxt_switches' "$t/status" 2>/dev/null | awk '{print $2}')
            inv=$(grep '^nonvoluntary_ctxt_switches' "$t/status" 2>/dev/null | awk '{print $2}')
            alw=$(grep Cpus_allowed_list "$t/status" 2>/dev/null | awk '{print $2}')
            printf '  %-8s %-16s %-9s %-6s %-5s %-4s %-10s %-10s %-8s %-8s %-8s %s\n' \
                "${t##*/}" "$(rd "$t/comm")" "$(policy_name "$pol")" "$tprio" "$tnice" "$tcpu" "$ex" "$wt" "$sl" "$vol" "$inv" "$alw"
        done
    done
    echo
    echo "  tip: 이슈 재현 전/후로 두 번 실행해 thread별 wait_ms 증가량을 비교하면 runqueue 대기가 큰 thread를 찾을 수 있다."
fi
echo
