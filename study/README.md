# 개인 학습 노트 (study 브랜치)

원본 강의 자료(`WeekN/`)는 **수정하지 않고**, 정리·실습 결과는 모두 이 `study/` 아래에 둡니다.

## 브랜치 규칙

| 브랜치 | 용도 |
| --- | --- |
| `main` | 강의 원본 미러. 직접 커밋하지 않음 (upstream 동기화 전용) |
| `study` | 개인 정리·실습. `main`을 주기적으로 merge |

```bash
# 새 주차 자료가 올라왔을 때
git checkout main && git pull upstream main && git push origin main
git checkout study && git merge main
./study/new-week.sh 5          # study/Week5 를 원본과 같은 구조로 생성
```

원본 파일은 `study/`에서만 복사본으로 다루므로 merge 충돌이 나지 않습니다.

## 주차별 구조

원본과 **같은 경로**를 `study/` 아래에 그대로 둡니다. (`WeekN/LabN/src/x.c` ↔ `study/WeekN/LabN/src/x.c`)

```
study/WeekN/
├── notes.md                    주차 개념 정리 (강의 내용, 핵심 질문, 참고 자료)
├── LabN/                       원본 LabN 복사본 (자유롭게 수정·빌드)
│   ├── LabN_instructions.md    원본 LabN_instructions.docx 를 md로 변환
│   ├── LabN_answers.md         원본 LabN_answers.docx 를 md로 변환
│   ├── lab_record.md           내 실습 기록 (명령, 관측값, 해석, 기록지 답변)
│   └── logs/                   관측 결과 (원본과 같은 위치, 커밋 대상)
└── AssignmentN/                원본 AssignmentN 복사본 (과제 구현)
    └── assignment_record.md    과제 설계·구현 메모·결과
```

## 진행 현황

| 주차 | 주제 | 정리 | Lab | 과제 |
| --- | --- | :---: | :---: | :---: |
| 1 | Linux process & system call | ☐ | ☐ | ☐ |
| 2 | Blocking & signal / IRQ | ☐ | ☐ | ☐ |
| 3 | Event-driven server (epoll, IPC) | ☐ | ☐ | ☐ |
| 4 | CPU 구조와 cache, scheduling | ☐ | ☐ | ☐ |
