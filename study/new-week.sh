#!/usr/bin/env bash
# 사용법: ./study/new-week.sh <주차번호>
# 원본 WeekN/LabN, WeekN/AssignmentN 을 같은 경로 구조로 study/WeekN 에 복사하고 기록 템플릿을 생성한다.
set -euo pipefail

n="${1:?usage: $0 <week-number>}"
root="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
src="$root/Week$n"
dst="$root/study/Week$n"
tpl="$root/study/_template"

[[ -d "$src" ]] || { echo "원본 $src 가 없습니다 (main merge 먼저)"; exit 1; }
mkdir -p "$dst"

copy_src() {  # 문서(docx/pdf)·빌드 결과·대용량 데이터셋은 제외하고 복사
    local name="$1"
    [[ -d "$src/$name" ]] || return 0
    if [[ -e "$dst/$name" ]]; then echo "skip: study/Week$n/$name 이미 존재"; return 0; fi
    mkdir -p "$dst/$name"
    rsync -a --exclude='*.docx' --exclude='*.pdf' --exclude='bin/' --exclude='logs/' \
        --exclude='service_log_dataset/' "$src/$name/" "$dst/$name/"
    echo "copied: Week$n/$name -> study/Week$n/$name"
}
copy_src "Lab$n"
copy_src "Assignment$n"

# 대용량 데이터셋은 복사 대신 원본을 symlink
[[ -d "$src/Lab$n/service_log_dataset" && ! -e "$dst/Lab$n/service_log_dataset" ]] &&
    ln -s "../../../Week$n/Lab$n/service_log_dataset" "$dst/Lab$n/service_log_dataset"

render() {  # 템플릿 → 대상 파일 (이미 있으면 유지)
    local t="$1" out="$2"
    [[ -e "$out" ]] && return 0
    mkdir -p "$(dirname "$out")"
    sed -e "s/{{N}}/$n/g" \
        -e "s|{{KERNEL}}|$(uname -r)|" \
        -e "s|{{CPU}}|$(lscpu | sed -n 's/^Model name: *//p' | head -1)|" \
        -e "s|{{DATE}}|$(date +%F)|" \
        "$tpl/$t.md" > "$out"
    echo "created: ${out#$root/}"
}
render notes      "$dst/notes.md"
render lab        "$dst/Lab$n/lab_record.md"
render assignment "$dst/Assignment$n/assignment_record.md"

echo "docx 변환: pandoc <원본>.docx -t gfm --wrap=none -o study/Week$n/Lab$n/<같은 이름>.md"
