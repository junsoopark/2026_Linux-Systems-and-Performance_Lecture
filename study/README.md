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

## 원본 대비 추가·제외된 파일

`study/`는 원본 복사본이지만, 아래 파일만 원본과 다릅니다. 이 외의 파일은 원본과 동일한 내용으로 출발합니다.

### study/ 공통 (원본에 없음)

| 파일 | 설명 |
| --- | --- |
| `README.md` | 이 문서. 브랜치 규칙, 구조, 진행 현황 |
| `new-week.sh` | 원본 `WeekN`을 같은 구조로 `study/WeekN`에 복사하고 기록 템플릿 생성 |
| `_template/notes.md` | `WeekN/notes.md` 템플릿 |
| `_template/lab.md` | `WeekN/LabN/lab_record.md` 템플릿 (커널·CPU·날짜 자동 기입) |
| `_template/assignment.md` | `WeekN/AssignmentN/assignment_record.md` 템플릿 |
| `.gitignore` | `bin/`, `perf.data*` 무시, `LabN/logs/`는 커밋하도록 루트 규칙 해제 |

### 주차별 추가 파일

| 파일 | 종류 | 설명 |
| --- | --- | --- |
| `WeekN/notes.md` | 직접 작성 | 주차 개념 정리 |
| `WeekN/LabN/lab_record.md` | 직접 작성 | 실습 명령, 관측값, 해석, 기록지 답변 |
| `WeekN/LabN/labK_*_record.md` | 직접 작성 | 중요한 실습 K를 따로 정리한 문서 (`lab_record.md`에서 링크) |
| `WeekN/LabN/logs/` | 실습 결과 | 원본 도구가 생성하는 관측 로그 (원본에서는 git 무시, 여기서는 커밋) |
| `WeekN/AssignmentN/assignment_record.md` | 직접 작성 | 과제 요구사항, 설계, 구현 메모, 결과 |
| `WeekN/LabN/LabN_*.md` | 원본 변환 | 같은 위치의 원본 `LabN_*.docx`를 pandoc으로 md 변환 (명령어 형광펜 → 코드 블록, 내용은 원문 그대로) |

| `WeekN/LabN/src/*`, `tools/*` (원본에 없는 파일) | 추가 테스트 | 질문 검증용으로 직접 만든 코드. 파일 상단에 `[study 추가]` 표기 |

현재 별도 실습 문서: `Week4/Lab4/lab3_scheduling_record.md` (실습 3 scheduling 지연 진단)

현재 추가된 테스트 코드: `Week4/Lab4/src/ws_seq.c` (실습 1 Q1.2 순차 접근 비교), `Week4/Lab4/tools/lab3_run.sh` (실습 3 단계 2~7 자동 실행)

현재 변환된 문서: `Week4/Lab4/Lab4_instructions.md`, `Week4/Lab4/Lab4_answers.md`

### 원본에서 제외·대체된 파일

| 원본 | study/ | 이유 |
| --- | --- | --- |
| `*.docx` | 같은 이름의 `.md` (변환한 주차만) | 바이너리 대신 읽기·diff 가능한 형식 |
| `*.pdf` (과제 문서) | 없음 → 원본 경로 참조 | 문서 중복 방지 |
| `Week1/Lab1/bin/` | 없음 → `make`로 생성 | 빌드 산출물 |
| `Week3/Lab3/service_log_dataset/` | symlink → 원본 | 51MB 읽기 전용 데이터, 복사 불필요 |

## 진행 현황

| 주차 | 주제 | 정리 | Lab | 과제 |
| --- | --- | :---: | :---: | :---: |
| 1 | Linux process & system call | ☐ | ☐ | ☐ |
| 2 | Blocking & signal / IRQ | ☐ | ☐ | ☐ |
| 3 | Event-driven server (epoll, IPC) | ☐ | ☐ | ☐ |
| 4 | CPU 구조와 cache, scheduling | ☐ | ☐ | ☐ |
