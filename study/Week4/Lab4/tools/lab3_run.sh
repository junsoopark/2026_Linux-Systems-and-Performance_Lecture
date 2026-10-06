#!/usr/bin/env bash
# [study 추가] 실습 3 단계 2~7을 안내서 명령 그대로 자동 실행한다.
# 터미널 A/B/세 번째 터미널에서 동시에 하던 일을 background 실행 + 대기로 묶고, 결과는 logs/ 에 남긴다.
#
# usage: bash tools/lab3_run.sh <step>
#   2  기본 조건 + perf sched 기록          (tag=base)
#   3  조치 A: indexer nice 10              (tag=nice)
#   4  조치 B: cgroup cpu.weight 20         (tag=weight)
#   5  조치 C: cgroup cpu.max 30%           (tag=max)
#   6  조치 D: cgroup cpuset 1              (tag=cpuset)
#   7  정리: cgroup teardown
#   all  2~7 순서대로 (약 2분)
set -eu
cd "$(dirname "$0")/.."
mkdir -p logs

RENDERER_SPEC="periodic:16667:4000,cpu=0"

# 공통 흐름: indexer(14s) 시작 → 1s 뒤 renderer(10s) 시작 → 1s 뒤 perf 8s 기록 → 모두 종료 대기
# $1 tag, $2 sudo 여부("sudo" 또는 ""), $3 indexer spec, $4 cgroup 옵션(예: "-c lab/bg"), $5 renderer cgroup 옵션
run_pair() {
    local tag=$1 su=$2 ispec=$3 icg=$4 rcg=$5
    local ilog="logs/lab3-$tag-indexer.txt" rlog="logs/lab3-$tag-renderer.txt"
    echo "=== [$tag] indexer: $su ./bin/mtwork -d 14 -n indexer $icg $ispec"
    $su ./bin/mtwork -d 14 -n indexer $icg $ispec > "$ilog" &
    local ipid=$!
    sleep 1
    if [ -n "${ON_INDEXER_STARTED:-}" ]; then "$ON_INDEXER_STARTED" "$ilog"; fi
    echo "=== [$tag] renderer: $su ./bin/mtwork -d 10 -n renderer $rcg $RENDERER_SPEC"
    $su ./bin/mtwork -d 10 -n renderer $rcg $RENDERER_SPEC > "$rlog" &
    local rpid=$!
    sleep 1
    if [ -n "${ON_BOTH_STARTED:-}" ]; then "$ON_BOTH_STARTED"; fi
    bash tools/perf_jank.sh "$tag" 8 | tee "logs/lab3-$tag-perf_jank.txt"
    wait "$rpid" "$ipid"
    echo "--- renderer"; cat "$rlog"
    echo "--- indexer";  cat "$ilog"
    echo
}

indexer_tid() { sed -n 's/^TIDS=//p' "$1" | cut -d, -f1; }

renice_indexer() {   # 단계 3: TIDS 줄의 TID에 nice 10 (자기 thread의 nice를 올리는 것은 root 불필요)
    local tid; tid=$(indexer_tid "$1")
    echo "=== [nice] renice -n 10 -p $tid (indexer TID)"
    renice -n 10 -p "$tid"
}

show_psr() {         # 단계 6: indexer가 cpuset 때문에 CPU 1에서 도는지 확인
    echo "=== [cpuset] thread별 실행 CPU(PSR)"
    ps -eLo tid,psr,ni,comm | awk 'NR==1 || $4 ~ /^(indexer|renderer)-/' | tee logs/lab3-cpuset-psr.txt
}

step() {
    case $1 in
        2) run_pair base "" "busy,cpu=0" "" "" ;;
        3) ON_INDEXER_STARTED=renice_indexer run_pair nice "" "busy,cpu=0" "" "" ;;
        4) sudo bash tools/fixcg.sh setup 20
           run_pair weight sudo "busy,cpu=0" "-c lab/bg" "-c lab/fg" ;;
        5) sudo bash tools/fixcg.sh setup 100
           sudo bash tools/fixcg.sh max 30000 100000
           run_pair max sudo "busy,cpu=0" "-c lab/bg" "-c lab/fg"
           echo "--- lab/bg cpu.stat"; tee logs/lab3-max-cpu.stat < /sys/fs/cgroup/lab/bg/cpu.stat ;;
        6) sudo bash tools/fixcg.sh max max 100000
           sudo bash tools/fixcg.sh cpuset 1
           ON_BOTH_STARTED=show_psr run_pair cpuset sudo "busy" "-c lab/bg" "-c lab/fg" ;;
        7) sudo bash tools/fixcg.sh teardown
           if [ -e /sys/fs/cgroup/lab ]; then echo "WARN /sys/fs/cgroup/lab 남아 있음"; else echo "OK cgroup 정리 완료"; fi ;;
        *) echo "usage: $0 <2|3|4|5|6|7|all>"; exit 1 ;;
    esac
}

trap 'echo "!! 중간에 실패함. cgroup이 남았다면: sudo bash tools/fixcg.sh teardown"' ERR
sudo -v   # 비밀번호를 처음에 한 번만 묻는다
if [ "${1:-}" = all ]; then
    for s in 2 3 4 5 6 7; do step "$s"; done 2>&1 | tee logs/lab3-all.txt
else
    step "${1:-}"
fi
