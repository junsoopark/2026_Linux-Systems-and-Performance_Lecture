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
./study/new-week.sh 5          # Week5 작업 공간 생성
```

원본 파일은 `study/`에서만 복사본으로 다루므로 merge 충돌이 나지 않습니다.

## 주차별 구조

```
study/WeekN/
├── docs/           원본 docx를 md로 변환한 문서
├── notes.md        개념 정리 (강의 내용, 핵심 질문, 참고 자료)
├── lab.md          실습 기록 (명령, 관측값, 해석)
├── assignment.md   과제 설계·구현 메모·결과
├── lab/            Lab 원본 소스 복사본 (자유롭게 수정·빌드)
├── assignment/     Assignment 원본 소스 복사본 (과제 구현)
└── results/        측정 로그, 스크린샷, perf 데이터 등
```

## 진행 현황

| 주차 | 주제 | 정리 | Lab | 과제 |
| --- | --- | :---: | :---: | :---: |
| 1 | Linux process & system call | ☐ | ☐ | ☐ |
| 2 | Blocking & signal / IRQ | ☐ | ☐ | ☐ |
| 3 | Event-driven server (epoll, IPC) | ☐ | ☐ | ☐ |
| 4 | CPU 구조와 cache, scheduling | ☐ | ☐ | ☐ |
