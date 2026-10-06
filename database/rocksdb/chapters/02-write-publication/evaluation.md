# 2. 쓰기와 공개 — 최종 평가

- 상태: `통과`
- 평가일: `2026-10-04`
- 최종 정리: [학습자가 작성한 정리](learner-notes.md)
- 원본: [Notion 최종 정리](https://app.notion.com/p/3ee74b55ec7c80dd86caf41faf8cf2ca)
- 이 문서는 설명자가 작성한 평가 기록이다. 학습자의 최종 설명은 별도 정리에 보존한다.

## 평가 범위와 전제

이번 과정은 일반 `WriteBatch`의 원자적 변경, Sequence 할당, WAL, MemTable 적용, publication, 성공 반환과 장애 내구성의 관계를 다뤘다. 공식 논문 §2.2·§4.3과 공식 문서의 원문을 주 근거로 사용했다.

- 기본 ordered write 동작을 전제로 한다. `unordered_write` 문서에서는 Background의 기본 동작을 근거로 사용했다.
- 원자적 가시성 예시는 하나의 일관된 읽기 시점을 전제로 한다. 별개의 Get들이 publication을 사이에 두고 실행되면 서로 다른 시점의 상태를 읽을 수 있다.
- 비동기 WAL의 프로세스 장애 보장은 WAL이 활성화되고 기본 자동 WAL flush가 사용되는 경우를 전제로 한다. `manual_wal_flush=true`로 프로세스 내부 버퍼에만 남은 기록에는 같은 보장을 적용하지 않는다.
- 일반 DB 읽기의 read-your-own-writes는 성공한 쓰기 이후의 읽기를 뜻한다. 의도적으로 과거 Snapshot을 사용하는 경우와 Transaction의 미커밋 변경 읽기는 구분한다.
- WAL은 복구와 장애 원자성의 기반이며, 정상 실행 중 부분 변경의 노출 방지는 publication과 연결된다. WAL 사용만으로 모든 장애에 대한 내구성이 자동 보장되지는 않는다.

## 공개된 기준별 최종 판정

| 기준 | 판정 | 확인한 근거 |
|---|---|---|
| 원자적 쓰기와 동시성 제어의 경계 | 충족 | 대화에서 학습자는 여러 배치가 각각 원자적으로 적용되어도 동시성 문제는 해결되지 않는다고 설명했다. UNIQUE 사례의 문서 반복은 평가에서 제외했다. |
| 같은 DB의 여러 Column Family와 인덱스 변경 | 충족 | users와 email_index의 변경을 하나의 WriteBatch에 담고, 같은 DB의 CF가 WAL을 공유하는 경계를 설명했다. 별도 DB 인스턴스의 원자적 쓰기는 포함하지 않는다. |
| Sequence 할당·MemTable 적용·publication | 충족 | 공개 경계 100에서 101·102가 내부에 적용돼도 기존 상태를 읽는 예시, 배치 내 연속 Sequence, 앞선 미완료 배치를 건너뛰어 105를 공개할 수 없다는 조건을 설명했다. |
| WAL과 MemTable의 역할·복구 | 충족 | WAL을 먼저 기록하고 MemTable을 변경하며, 장애 후 WAL로 MemTable을 재구성하는 역할을 구분했다. |
| sync·비동기·no-WAL의 장애 보장 | 충족 | 영속 저장장치 동기화, OS 버퍼까지 전달, 복구 로그 생략을 구별하고 프로세스 장애와 머신 장애의 차이를 설명했다. |
| 가시성과 내구성의 구분 | 충족 | 읽기에 공개되어 성공 반환한 no-WAL 쓰기도 SST Flush 전에 프로세스가 죽으면 복구할 수 없다는 예시를 제시했다. |

최종 판정은 학습자의 Notion 재구성, 대화 중 확인 문제 답변, 수정본을 함께 근거로 삼았다. 인용문을 붙였다는 사실만으로 통과를 판정하지 않았다.

## 학습에서 교정한 경계

- 최종 상태가 맞아졌다는 이유만으로 원자성이 성립하지 않는다. 학습자는 “원자성은 전부 적용되거나 전부 적용 안되는 것”이라고 설명했다.
- 배치 내 연속 Sequence만으로 publication 안전성이 충분하지 않다. 공개 경계가 미완료 배치의 일부를 포함해서는 안 된다는 조건을 최종 정리에 추가했다.
- WriteBatch를 Transaction이라고 부르며 “자기도 미커밋 쓰기를 읽지 못한다”고 일반화했던 설명을 교정했다. 최종 정리는 일반 DB 읽기와 Transaction의 자기 쓰기 읽기를 구분한다.
- WAL이 무조건 원자성과 내구성을 보장한다는 표현을 “보장시킬 수 있다”로 수정하고, 뒤의 세 WAL 모드와 장애 종류로 조건을 설명했다.
- Sequence는 DB 변경의 논리적 순서이며 WAL의 물리적 읽기 위치가 아니다.

## 이번 통과에 요구하지 않은 내용

- WriteGroup, WriteThread, writer queue, leader와 scheduling 내부 구현
- UNIQUE 사례의 문서 재작성과 Transaction의 구체적인 충돌 제어 구현
- SST 탐색, MANIFEST 재시작, checksum, 전체 recovery 절차

3장은 아직 시작하지 않았다. TransactionDB, OptimisticTransactionDB, GetForUpdate의 본 학습과 평가는 5장에서 진행한다.

## 공식 근거

- [RocksDB 논문 (2021), §2.2·§4.3](https://doi.org/10.1145/3483840)
- [Basic Operations — Atomic Updates / Synchronous Writes / Non-sync Writes](https://github.com/facebook/rocksdb/wiki/Basic-Operations)
- [RocksDB Overview — Updates](https://github.com/facebook/rocksdb/wiki/RocksDB-Overview#updates)
- [Write Ahead Log — Overview / manual_wal_flush](https://github.com/facebook/rocksdb/wiki/Write-Ahead-Log-%28WAL%29)
- [Unordered Writes — Background](https://github.com/facebook/rocksdb/wiki/unordered_write#background)
- [Two-Phase Commit Implementation — Sequence ID Distribution](https://github.com/facebook/rocksdb/wiki/Two-Phase-Commit-Implementation#sequence-id-distribution)
- [Transactions — Reading from a Transaction](https://github.com/facebook/rocksdb/wiki/Transactions#reading-from-a-transaction)
