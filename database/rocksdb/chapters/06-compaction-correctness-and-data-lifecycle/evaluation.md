# 6. Compaction 정확성과 데이터 생명주기 — 평가와 통과 기록

- 상태: `통과`
- 평가일: `2026-11-08`
- 학습자 최종 정리와 직접 교정한 답변: [learner-notes.md](learner-notes.md)
- 원본: [Notion 정리](https://app.notion.com/p/40c74b55ec7c80c784c7d791289d50ae)
- 평가한 원본 최종 수정: `2026-11-08T08:06:00.593Z`
- 시작 기준: `upstream/main`의 `0f0c4ee clarify-database-learning-prerequisite-references (#13)`
- 이 문서는 설명자가 작성했다. 학습자가 작성한 정리, 실제 문답, 설명자의 판단을 구분한다.

## 평가 범위와 선행 학습

이번 과정의 중심 질문은 “물리 구조가 바뀌어도 왜 논리 결과가 유지되는가?”다. immutable MemTable과 Flush, sorted-run 병합, 새 Version 설치, Snapshot이 요구하는 과거 버전 보존, tombstone 제거 조건, SuperVersion과 obsolete file 회수를 다뤘다. 한 CF의 일반 Put/Delete와 Snapshot을 예시의 전제로 삼았다.

이미 학습한 [3장의 MemTable·SST·정렬 병합](../03-physical-lookup/learner-notes.md)과 [4장의 논리적 읽기 경계·SuperVersion](../04-versions-and-logical-time/learner-notes.md)은 참조했다. 정렬 병합의 기초나 Snapshot API를 반복 시험하지 않고, 이번 장에서 새롭게 연결한 보존·구조 교체·회수 조건을 평가했다. 레코드를 안전하게 제외할 수 있는지를 판단했으며, 모든 Flush·Compaction이 매번 최소 레코드만 출력한다고 보장하는 것은 평가 전제가 아니다.

## 공개한 통과 기준별 최종 판정

| 기준 | 첫 평가 | 최종 판정과 근거 |
|---|---|---|
| immutable MemTable에서 SST로 읽기 구조를 바꾸는 동안 데이터가 사라지지 않는 이유를 설명한다 | 잘못 이해함 | 충족. 처음에는 Flush가 immutable MemTable을 만든다고 적었다. 확인 문제 ①에서 필터링한 결과는 F1에 반영되고 F1은 current가 참조하는 Version의 SST 목록에 들어간다고 답했다. 최종 정리의 제목과 Flush 이후 그림도 수정했다. |
| sorted-run 병합, 출력 SST 완성, 새 Version 설치, 기존 독자의 읽기를 시간순으로 연결한다 | 충족 | 충족. F1·F2를 병합해 F3을 완성한 뒤 V2={F3,F9}를 설치하고, 새 읽기는 V2, 기존 읽기는 V1을 사용한다고 설명했다. Version과 SuperVersion의 구별도 명시했다. |
| 같은 읽기 시점의 논리 결과를 보존한다는 Compaction 정확성 조건을 설명한다 | 충족 | 충족. 저장 위치가 mem·imm·SST 사이에서 달라져도 읽기 뷰가 참조하는 논리적 값은 같아야 한다고 설명했다. |
| 현재 읽기와 살아 있는 Snapshot을 기준으로 보존해야 할 과거 버전을 판단한다 | 충족 | 충족. S=10에서 A@10은 필요하고 B@20은 제거할 수 있으며, 현재 읽기의 삭제 결과를 위해 Delete@30도 필요하다고 설명했다. |
| tombstone 제거 시 Snapshot 보존과 오래된 값의 부활 방지를 각각 확인한다 | 핵심 누락 | 충족. 삭제 전 Snapshot이 요구하는 A와 삭제 표식을 함께 보존하는 이유를 설명했다. 수정본에는 더 오래된 레벨에 해당 키가 없는지 확인해야 한다는 조건과, Snapshot 없이 L1의 삭제 표식·L3의 옛 값이 남고 L3가 Compaction 입력에 포함되지 않는 사례를 추가했다. |
| Snapshot의 논리 버전 보존과 Iterator·SuperVersion의 물리 자원 보존을 구분한다 | 핵심 누락 | 충족. 정리의 논리적·물리적 자원 구분에 더해 확인 문제 ③에서 F1·F2의 내용은 바뀌지 않으며 기존 Iterator I는 F1·F2를 계속 순회한다고 직접 답했다. 최종 정리는 참조 중인 파일을 바로 제거하면 안 되는 이유를 함께 설명한다. |
| 논리적 삭제, 레코드 정리, 현재 파일 구성에서 제외, 실제 파일 회수를 구분한다 | 충족 | 충족. 현재 Version의 목록은 F3·F9이지만 디스크에는 F1·F2도 남아 있는 상태를 표현하고, V1을 사용하는 참조가 모두 해제되어야 기존 파일을 회수할 수 있다고 설명했다. |

원문 접기의 인용문만으로 독립적인 이해를 판정하지 않았다. 기준별 근거는 학습자가 작성한 본문·그림과 실제 확인 문제 답변을 함께 사용했다.

## 확인 문제와 유효했던 교정

첫 평가 이후 다음 세 문제를 제시했다.

1. M1이 immutable로 전환되고 M2가 새 쓰기를 받는 중, M1을 Flush해 F1을 만들고 설치했을 때 레코드 제외 결과와 F1의 SuperVersion 내 위치를 설명한다.
2. Snapshot 없이 L1에 Delete(k)@30, L3에 Put(k,A)@10이 있고 L1→L2 Compaction 입력에 L3가 없을 때 tombstone 제거의 결과와 안전 조건을 설명한다.
3. Iterator I가 F1·F2를 읽는 중 Compaction으로 F3과 새 Version이 만들어졌을 때, 기존 파일의 내용·순회 대상·회수 조건을 설명한다.

①과 ③은 대화에서 직접 답변을 받았다. ②의 별도 문제 답안은 받지 않았으며, 최종 정리에 추가한 하위 레벨 확인 조건과 Snapshot 없는 사례를 근거로 누락 해소를 판정했다. 이를 세 문제 모두의 개별 풀이를 받았다고 기록하지 않는다.

| 처음 이해하거나 표현한 내용 | 드러난 오류나 경계 | 수정한 이해와 근거 |
|---|---|---|
| Flush가 불필요한 레코드를 제외한 immutable MemTable을 만든다 | immutable 전환, Flush의 입력, 출력 SST를 혼동했다. | 학습자가 “F1에 반영돼”, “current가 참조하는 Version의 SST 목록에 들어가”, “imm이랑 SST를 헷갈렸네”라고 직접 답했다. 제목과 출력 그림을 수정했다. |
| Snapshot이 필요로 하는 A를 가리기 위해 tombstone을 남긴다 | Compaction 입력 밖의 더 오래된 값도 부활할 수 있다. | 최종 정리에 더 오래된 레벨의 키 존재 확인 조건과 Snapshot 없는 L1·L3 사례를 추가했다. |
| Compaction 때문에 기존 포인터의 next가 달라지므로 물리 구조를 유지한다 | 새 출력 파일 생성과 기존 파일의 변경을 구분해야 한다. | 학습자가 F1·F2 자체는 바뀌지 않고 I가 계속 기존 파일을 읽는다고 답했다. 원본의 물리 자원 설명도 사용 중인 파일을 바로 정리할 수 없다는 문맥으로 수정했다. |

최종 재확인에서는 남아 있던 1절 제목, 3절의 Flush 출력 그림, “다음 장”이라는 연결 표현을 확인했다. 제목은 “Flush로 SST 생성”, 출력 레코드는 current→Version→F1.sst 아래로 바뀌었다. “다음 파트”는 같은 문서의 다음 4절인 물리적 자원 정리를 가리키므로 문맥에 맞는다.

## 최종 판정과 진행 범위

공개한 7개 기준을 최종 정리와 문답으로 충족하여 6장을 통과했다. 학습자의 별도 오답노트를 새로 작성한 것으로 취급하지 않고, 유효했던 직접 교정 답변과 최종 정리의 수정만 보존했다. 답안 생략 승인을 받아 통과시킨 경우와 구분한다.

이번 세션은 6장만 종료했다. 7장의 Compaction 정책과 증폭, 8장의 애플리케이션 callback, 9장의 장애 복구 학습은 시작하지 않았다. 전체 커리큘럼과 공통 학습 절차는 변경하지 않았다.

## 공식 근거

- [2021 RocksDB 논문 §2.2·§6.3](https://www.eecg.toronto.edu/~stumm/Papers/Dong-ACMToS21.pdf)
- [RocksDB Overview — Memtable Pipelining / Garbage Collection during Memtable Flush](https://github.com/meta/rocksdb/wiki/RocksDB-Overview#memtable-pipelining)
- [Compaction](https://github.com/meta/rocksdb/wiki/Compaction)
- [Snapshot — Flush/compaction](https://github.com/meta/rocksdb/wiki/Snapshot#flushcompaction)
- [How we keep track of live SST files](https://github.com/meta/rocksdb/wiki/How-we-keep-track-of-live-SST-files)
- [Iterator — Resource pinned by iterators](https://github.com/meta/rocksdb/wiki/Iterator#resource-pinned-by-iterators-and-iterator-refreshing)
- [SuperVersion and Snapshot Isolation](https://github.com/meta/rocksdb/blob/main/docs/components/read_flow/03_superversion_and_snapshots.md)
