# 5. 원자성과 충돌 제어 — 평가와 통과 기록

- 상태: `통과` — 일부 추가 풀이 생략과 정리·평가 범위 제외에 대한 학습자 승인 반영
- 평가일: `2026-11-02`
- 학습자 최종 정리와 설명자 보완: [learner-notes.md](learner-notes.md)
- 원본: [Notion 정리](https://app.notion.com/p/40c74b55ec7c804e9a12f865e53a790d)
- 평가한 원본 최종 수정: `2026-11-02T05:43:01.277Z`
- 이 문서는 설명자가 작성했다. 학습자의 재구성, 설명자 보완, 추가 풀이 생략 승인을 구분한다.

## 평가 범위와 전제

이번 과정은 “여러 read-modify-write가 겹치면 어떻게 되는가?”를 중심으로 WriteBatch의 원자성과 isolation, lost update, Transaction의 준비된 쓰기와 가시성, GetForUpdate, TransactionDB와 OptimisticTransactionDB, 읽기 Snapshot과 충돌 기준 Snapshot의 관계를 다뤘다. 공식 Transactions 문서와 공개 API의 자연어 설명을 주 근거로 사용했다. 예시는 기본 WriteCommitted 설정을 전제로 하며, lock table·deadlock detector·특수 transaction 모드의 내부 구현은 요구하지 않았다.

전체 설명은 아래 여덟 소제목으로 제공했다. 평가 전에 학습자는 7·8번을 이번 정리에 적지 않겠다고 명시했고, 설명자는 이번 정리·평가에서 제외하겠다고 알렸다.

1. WriteBatch의 원자성과 isolation은 무엇이 다른가?
2. Transaction은 읽기·준비한 쓰기·커밋을 연결한다
3. GetForUpdate는 어떤 읽기를 보호하는가?
4. TransactionDB: 키를 먼저 잠그는 비관적 방식
5. OptimisticTransactionDB: 먼저 진행하고 커밋 때 검사한다
6. Snapshot에는 읽기 시점과 충돌 검사 기준이라는 두 역할이 있다
7. 대기·timeout·abort·retry는 누가 처리하는가? — 이번 정리·평가에서 제외
8. UNIQUE 제약은 어떻게 유지하는가? — 이번 정리·평가에서 제외

## 공개한 통과 기준별 평가

| 기준 | 첫 평가 | 최종 근거와 처리 |
|---|---|---|
| WriteBatch 원자성과 read-modify-write의 lost update를 구별한다 | 일부 잘못 이해함 | count=100을 둘이 읽고 각각 101을 저장해 최종 101이 되는 흐름은 맞았다. isolation 정의와 “동시성 문제로 오해”라는 표현, 배치 전후 읽기 상태의 조건을 지적했다. 최종 정리에서 간섭·가시성 제어라는 정의와 같은 Snapshot을 공유한다는 조건으로 수정해 충족했다. |
| Transaction의 준비된 쓰기, 자신의 쓰기 읽기, 외부 가시성, Commit과 Rollback을 연결한다 | 핵심 누락 | 원자적 적용과 자신의 쓰기 읽기는 적었지만 준비된 변경과 DB의 구분, 외부 가시성, Commit·Rollback의 차이는 직접 설명하지 않았다. 추가 확인 문제 ②에 대해 학습자가 기본기라며 풀이 생략을 승인했다. 추가 답안으로 충족을 검증했다고 기록하지 않는다. |
| 비관적 잠금과 낙관적 커밋 검사를 실행 순서와 비용으로 비교한다 | 충족 | 비관적 예시에서 A의 잠금 때문에 B가 기다리고, A의 커밋 후 B가 101을 읽어 102를 커밋하는 흐름을 설명했다. 낙관적 예시에서는 둘이 100을 읽고 계산한 뒤 A만 커밋하고 B가 실패해 처음부터 다시 시작해야 함을 설명했다. |
| 일반 Get과 GetForUpdate, 읽기 의존성의 보호 범위를 구별한다 | 핵심 누락 | 키를 커밋 전제로 등록한다는 기본 역할은 설명했다. 일반 Get과의 차이와 읽은 x를 근거로 다른 y를 쓰는 경우는 직접 재구성하지 않아 문제 ③을 제시했다. 학습자가 풀이 생략을 승인했다. 부재 키 보호를 적용하는 UNIQUE 사례도 이번 별도 정리·평가에서 제외했으며 독립적인 재구성 근거로 계산하지 않는다. |
| 읽기 Snapshot과 트랜잭션 충돌 기준을 구별하고 함께 설정한다 | 충족 | SetSnapshot 후에도 읽기 Snapshot 없는 Get은 현재 값을 읽는 예시, ReadOptions.snapshot을 txn.GetSnapshot()으로 지정하는 코드, 과거 S_past를 읽어도 충돌 기준은 S이며 S_past부터 S까지의 변경은 보호되지 않는다는 설명을 작성했다. |
| 대기·timeout·abort·retry의 엔진과 애플리케이션 책임을 구별한다 | 이번 정리·평가에서 제외 | 학습자의 명시적 요청을 반영했다. 4·5번 예시에 대기와 재시작이 있지만 오류별 정리·재읽기·재계산 절차 전체를 검증한 근거로 확대하지 않는다. |
| 공통 제약 키의 보호와 원자적 쓰기로 UNIQUE를 유지하는 책임을 설명한다 | 이번 정리·평가에서 제외 | 학습자의 명시적 요청을 반영했다. UNIQUE 사례를 작성하거나 확인 문제를 풀었다고 기록하지 않는다. |

원문 토글의 인용문만으로 학습자가 독립적으로 설명했다고 판정하지 않았다. 5번의 “데이터가 깨졌는지”라는 표현은 설명자가 충돌 검사와 데이터 손상을 구분하도록 보완했으며, 예시 자체는 경쟁 변경으로 인한 커밋 실패를 맞게 설명했다.

## 추가 확인과 수정

첫 평가는 `보완 필요`였다. 실제 누락과 오개념에 대해 다음 세 문제를 제시했다.

1. Snapshot 없이 Get(A)와 Get(B) 사이에 배치가 공개될 때 결과가 섞일 수 있는가? 이것이 원자성 위반인지 설명하고 isolation 정의를 다시 쓴다.
2. 초기 x=1에서 T.Put(x, 2) 후 T.Get과 외부 db.Get, Commit 또는 Rollback 후 외부 읽기의 결과와 이유를 설명한다.
3. 낙관적 트랜잭션이 Get(x) 후 다른 트랜잭션의 x 변경을 거쳐 y를 쓸 때, Get을 GetForUpdate로 바꾸면 커밋 결과가 어떻게 달라지는지 설명한다.

학습자는 ②를 Commit·Rollback 기본기에 해당한다며, ③을 읽은 키와 쓰는 키가 다른 당연한 경우라며 추가 풀이를 생략하라고 지시했다. 이는 해당 문제의 실제 풀이 제출과 구분해 기록한다.

①은 별도 문제 답안 대신 원본 Notion의 문장을 수정했다. 첫 수정 후 남아 있던 isolation 정의와 읽기 경계 조건을 다시 안내했고, 학습자가 두 문장을 수정했다. 최종 원본에서 다음을 확인했다.

- isolation을 “동시에 실행되는 연산들 사이의 간섭과 가시성을 제어하는 보장”으로 정의했다.
- 배치 전후의 두 상태 중 하나만 읽는다는 설명에 “같은 스냅샷을 공유할 때”라는 조건을 붙였다.
- lost update를 원자적 배치 쓰기만으로 해결되지 않는 동시성 문제로 설명했다.

별도의 학습자 오답노트나 ①~③의 개별 문제 답안은 받지 않았다. 최종 정리에 반영된 수정과 풀이 생략 승인을 근거로 과정 종료를 판정했다.

## 교정과 학습 중 구별한 경계

아래는 설명자가 문답과 최종 정리를 대조한 기록이며, 학습자가 별도 오답노트를 제출한 것으로 취급하지 않는다.

| 처음의 질문 또는 표현 | 드러난 경계 | 최종 정리와 보완 |
|---|---|---|
| 원자성이 있으면 동시성 문제는 오해인가? | 준비된 쓰기 묶음의 원자성과 읽기부터 계산·쓰기까지의 보호는 다르다. | 최종 정리에서 lost update를 실제 동시성 문제로 설명하고 isolation 정의를 수정했다. |
| 읽기는 항상 배치 전 또는 후 상태만 모으는가? | 하나의 논리적 읽기 경계와 서로 독립적인 여러 Get은 구분해야 한다. | 최종 정리에 같은 Snapshot을 공유한다는 조건을 명시했다. 별도 Get이 공개 시점을 사이에 둘 수 있다는 설명은 설명자 보완에 남겼다. |
| SetSnapshot이 읽을 데이터도 자동으로 고정하는가? | ReadOptions.snapshot의 읽기 버전과 txn.SetSnapshot의 충돌 기준은 별도로 설정된다. | 최종 정리에서 두 역할과 함께 지정하는 코드를 설명했다. |
| GetForUpdate에 과거 Snapshot을 넣으면 충돌 검사도 그 과거부터 수행하는가? | 읽기 Snapshot이 트랜잭션 충돌 기준을 덮어쓰지 않는다. | 최종 정리에서 S_past를 읽어도 충돌 기준은 S이며 이전 구간이 보호되지 않음을 명시했다. |

일반 WriteBatch도 메모리에 쓰기를 쌓는다는 점과 Transaction의 읽기 지원 차이, Get과 GetForUpdate의 구분, 값의 동일성과 변경 이력의 차이, Commit·Rollback의 역할은 저장소 정리의 “설명자 보완”에 표시했다.

## 최종 판정과 진행 범위

최종 상태는 `통과`다. WriteBatch·lost update의 관계와 읽기 경계 조건을 수정했고, 비관적·낙관적 실행 흐름과 Snapshot의 두 역할을 설명한 근거를 확인했다. Transaction 가시성과 읽기 의존성에 관한 추가 문제 ②·③은 학습자의 풀이 생략 승인을 반영했다. 대기·timeout·abort·retry와 UNIQUE의 별도 정리·평가는 학습자 요청으로 제외했다.

이 기록은 모든 원래 기준을 개별 답안으로 재검증한 통과와 근거가 다르다. 이번 생략·제외는 5장에 한정하며 공통 학습 절차, 전체 커리큘럼이나 다른 장의 통과 기준을 변경하지 않는다. 이번 세션은 5장만 종료하고 6장은 시작하지 않았다.

## 근거

- [Transactions](https://github.com/meta/rocksdb/wiki/Transactions)
- [Transaction API — SetSnapshot, GetSnapshot, Commit, Rollback, Get, GetForUpdate](https://github.com/meta/rocksdb/blob/main/include/rocksdb/utilities/transaction.h)
- [TransactionDB API](https://github.com/meta/rocksdb/blob/main/include/rocksdb/utilities/transaction_db.h)
- [OptimisticTransactionDB API](https://github.com/meta/rocksdb/blob/main/include/rocksdb/utilities/optimistic_transaction_db.h)
- [Basic Operations — Snapshots](https://github.com/meta/rocksdb/wiki/Basic-Operations#snapshots)
- [Snapshot](https://github.com/meta/rocksdb/wiki/Snapshot)
- [WriteBatch API](https://github.com/meta/rocksdb/blob/main/include/rocksdb/write_batch.h)
- [WriteBatchWithIndex](https://rocksdb.org/blog/2015/02/27/write-batch-with-index.html)
