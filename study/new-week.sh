#!/usr/bin/env bash
# 사용법: ./study/new-week.sh <주차번호>
# 원본 WeekN의 Lab/Assignment 소스를 study/WeekN 으로 복사하고 노트 템플릿을 생성한다.
set -euo pipefail

n="${1:?usage: $0 <week-number>}"
root="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
src="$root/Week$n"
dst="$root/study/Week$n"
tpl="$root/study/_template"

[[ -d "$src" ]] || { echo "원본 $src 가 없습니다 (main merge 먼저)"; exit 1; }
mkdir -p "$dst/results"

copy_src() {  # 문서(docx/pdf)와 빌드 결과는 제외하고 복사
    local from="$1" to="$2"
    [[ -d "$from" ]] || return 0
    if [[ -e "$to" ]]; then echo "skip: $to 이미 존재"; return 0; fi
    mkdir -p "$to"
    rsync -a --exclude='*.docx' --exclude='*.pdf' --exclude='bin/' --exclude='logs/' --exclude='service_log_dataset/' "$from/" "$to/"
    echo "copied: ${from#$root/} -> ${to#$root/}"
}
copy_src "$src/Lab$n" "$dst/lab"
# 대용량 데이터셋은 복사 대신 원본을 symlink
[[ -d "$src/Lab$n/service_log_dataset" && ! -e "$dst/lab/service_log_dataset" ]] &&
    ln -s "../../../Week$n/Lab$n/service_log_dataset" "$dst/lab/service_log_dataset"
copy_src "$src/Assignment$n" "$dst/assignment"

for f in notes lab assignment; do
    out="$dst/$f.md"
    [[ -e "$out" ]] && continue
    sed -e "s/{{N}}/$n/g" \
        -e "s|{{KERNEL}}|$(uname -r)|" \
        -e "s|{{CPU}}|$(lscpu | sed -n 's/^Model name: *//p' | head -1)|" \
        -e "s|{{DATE}}|$(date +%F)|" \
        "$tpl/$f.md" > "$out"
    echo "created: ${out#$root/}"
done
