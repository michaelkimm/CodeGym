# [RocksDB] 5. 원자성과 충돌 제어

- 원본: [학습자가 작성한 Notion 정리](https://app.notion.com/p/40c74b55ec7c804e9a12f865e53a790d)
- 원본 최종 수정: `2026-11-02T05:43:01.277Z`
- 가져온 날짜: `2026-11-02`
- 아래 본문은 학습자가 수정한 최종 정리를 Markdown으로 옮긴 것이다. 소제목 수준·접기·문단·코드 블록 서식만 변환하고 문장은 유지했다.
- 마지막의 “설명자 보완”은 학습자의 독립적인 재구성과 구분한다. 원본 Notion은 수정하지 않았다.
- 추가 풀이 생략과 정리·평가에서 제외한 범위는 [평가 기록](evaluation.md)에 남겼다.

## 1. WriteBatch의 원자성과 isolation은 무엇이 다른가?

WriteBatch의 원자성은 배치로 묶인 연산들을 원자적으로 적용하는 것이고 isolation은 동시에 실행되는 연산들 사이의 간섭과 가시성을 제어하는 보장을 의미한다. 즉 각 WriteBatch는 원자적 연산에만 신경 쓰기 때문에 동시성 문제가 발생하여 isolation이 깨지게 된다.

예를 들어 두 계좌의 잔액을 함께 바꾸는 경우

```text
초기: A=100, B=0

WriteBatch {
  Put(A, 90)
  Put(B, 10)
}
```

읽기는 같은 스냅샷을 공유할 때 다음 두 상태 중 하나만 보게 된다. 이는 WriteBatch 내 연산들의 seq 연속성, WriteBatch의 publish, 읽기 시점에서의 readable publised seq 경계의 조합으로 가능하다. 자세한 내용은 앞 장에서 서술했다.

| 읽기 시점 | A | B |
| --- | --- | --- |
| 배치 공개 전 | 100 | 0 |
| 배치 공개 후 | 90 | 10 |

이때 원자적인 배치 연산만으로 다음 문제가 해결되지 않는다.

```text
초기 count=100

A: Get(count) -> 100
B: Get(count) -> 100

A: 100+1을 계산 -> 101
B: 100+1을 계산 -> 101

A: WriteBatch { Put(count, 101) } 성공
B: WriteBatch { Put(count, 101) } 성공

최종 count=101
```

각 쓰기에서 온전하게 1씩 증가 했는데 결과는 1만 증가했다. lost update 즉 갱신 유실이다.

WriteBatch의 원자성은 문제가 없었지만 isolation이 의미론적으로 문제가 있었다. 이를 해결하기 위해선 isolation을 물리적으로 보장 해야 한다.

<details>
<summary><a href="https://github.com/meta/rocksdb/blob/main/include/rocksdb/write_batch.h">write_batch.h — WriteBatch</a></summary>

> WriteBatch holds a collection of updates to apply atomically to a DB.

</details>

<details>
<summary><a href="https://rocksdb.org/blog/2015/02/27/write-batch-with-index.html">공식 글 — WriteBatchWithIndex (2015)</a></summary>

> consistency and isolation need to be enforced by concurrency controls on top of RocksDB

</details>

## 2. Transaction은 읽기·준비한 쓰기·커밋을 연결한다

- Transaction은 연산들을 RocksDB에 원자적으로 적용한다.
- Transaction 중 쓴 데이터를 바로 읽을 수 있다.

<details>
<summary><a href="https://github.com/meta/rocksdb/blob/main/include/rocksdb/utilities/transaction_db.h">transaction_db.h — BeginTransaction</a></summary>

> Starts a new Transaction.

</details>

<details>
<summary><a href="https://github.com/meta/rocksdb/wiki/Transactions#reading-from-a-transaction">Transactions — Reading from a Transaction</a></summary>

> transactions support Read-your-own-writes

</details>

<details>
<summary><a href="https://rocksdb.org/blog/2015/02/27/write-batch-with-index.html">공식 글 — WriteBatchWithIndex (2015)</a></summary>

> we atomically write the batch to RocksDB

</details>

<details>
<summary><a href="https://github.com/meta/rocksdb/blob/main/java/src/main/java/org/rocksdb/Transaction.java#L207-L215">공식 Java API — Transaction.rollback</a></summary>

> Discard all batched writes in this transaction.

</details>

## 3. GetForUpdate는 어떤 읽기를 보호하는가?

키를 읽고 해당 키를 커밋의 전제 조건으로 삼는다. 키 값을 충돌 제어 대상으로 등록하여 낙관락 혹은 비관 락을 사용하여 데이터의 동시성 문제를 방지한다.

<details>
<summary><a href="https://github.com/meta/rocksdb/wiki/Transactions#guarding-against-read-write-conflicts">Transactions — Guarding against Read-Write Conflicts</a></summary>

> make the read value a precondition for transaction commit

</details>

## 4. TransactionDB: 키를 먼저 잠그는 비관적 방식

비관락을 이용하여 동시성 문제를 해결하는 방식이다. Put 등의 연산은 키 잠금을 얻어야 한다. GetForUpdate을 사용하여 읽을 때 부터 키를 잠글 수 있다.

```text
초기 count=100

A: GetForUpdate(count) -> 100
  -> 잠금 획득, 100 읽음

B: GetForUpdate(count)
  -> A가 잠금을 가지고 있으므로 대기

A: Put(count, 101)
A: Commit
  -> 101 공개, 잠금 해제

B: 잠금 획득, 현재 값 101 읽음
B: Put(count, 102)
B: Commit
  -> 102 공개, 잠금 해제
```

<details>
<summary><a href="https://github.com/meta/rocksdb/wiki/Transactions#transactiondb">Transactions — TransactionDB</a></summary>

> keys that are written are locked

</details>

## 5. OptimisticTransactionDB: 먼저 진행하고 커밋 때 검사한다

OptimisticTransactionDB를 사용할 경우엔 읽고 계산하는 동안 키 잠금을 유지하지 않고 커밋할 때 데이터가 깨졌는지 학인한다.

아래 예시에서, 실패한 B는 처음부터 다시 시작해야한다.

```text
초기 count=100

A: GetForUpdate(count) → 100, 검사 대상으로 기록
B: GetForUpdate(count) → 100, 검사 대상으로 기록

A: Put(count, 101) → A 안에 준비
B: Put(count, 101) → B 안에 준비

A: Commit → 검사 통과, 101 공개
B: Commit → A의 변경을 발견, 실패
```

<details>
<summary><a href="https://github.com/meta/rocksdb/wiki/Transactions#optimistictransactiondb">Transactions — OptimisticTransactionDB</a></summary>

> conflict-detection at commit time

</details>

TransactionDB(비관적 방식)을 사용하지 OptimisticTransactionDB(낙관적 방식)을 사용할지는 DB를 여는 시점에서 결정한다.

## 6. Snapshot에는 읽기 시점과 충돌 검사 기준이라는 두 역할이 있다

- ReadOption.snapshot은 DB에서 읽을 시점의 버전을 정한다.
- txn.SetSnapshot()은 추적하는 키의 변경을 언제부터 충돌로 검사할지 정한다.

물론 둘은 같은 스냅샷을 가리킬 수도 있다. 다만 정의 자체는 분리 돼야한다. 두가지 예를 들어보자.

우선 SetSnapshot()이 Get()에 반환하는 데이터에 영향을 주지 않는 예시다.

```text
초기 x=100

T: BeginTransaction
T: SetSnapshot() → 기준 S, 이때 x=100

B: x=200으로 변경하고 커밋

T: Get(x), 읽기 Snapshot 지정 안 함 → 200
T: Get(x), 읽기 Snapshot S 지정    → 100
```

만약 같은 Snapshot을 읽기에도 쓰고 싶다면 다음 처럼 명시해야 한다.

```cpp
txn->SetSnapshot();  // 충돌 검사 기준 S 설정

rocksdb::ReadOptions read_options;
read_options.snapshot = txn->GetSnapshot();  // 읽기도 S 기준으로

rocksdb::Status s = txn->GetForUpdate(read_options, "x", &value);
```

유의할 것: 읽기는 S\_past 기준으로 수행하지만, 충돌 검사는 트랜잭션에서 설정한 S 기준으로 수행한다. 따라서 S\_past 부터 S까지 발생한 변경은 이 설정의 충돌 검사 대상이 아니다.

```cpp
txn->SetSnapshot();  // 충돌 검사 기준 S 설정

rocksdb::ReadOptions read_options;
read_options.snapshot = s_past;  // 읽기는 과거 S_past 기준

std::string value;
rocksdb::Status s = txn->GetForUpdate(read_options, "x", &value);
```

<details>
<summary><a href="https://github.com/meta/rocksdb/wiki/Snapshot">Snapshot</a></summary>

> A snapshot captures a point-in-time view of the DB at the time it's created.

</details>

<details>
<summary><a href="https://github.com/meta/rocksdb/wiki/Basic-Operations#snapshots">Basic Operations — Snapshots / ReadOptions.snapshot</a></summary>

> ReadOptions::snapshot may be non-NULL to indicate that a read should operate on a particular version of the DB state.

</details>

<details>
<summary><a href="https://github.com/meta/rocksdb/blob/main/include/rocksdb/utilities/transaction.h#L134-L154">transaction.h — SetSnapshot</a></summary>

> … not been modified … since the time the snapshot was set.

> will not affect the version of Data returned by Get()

</details>


## 설명자 보완

아래는 세션에서 다룬 API 동작과 문장 해석을 설명자가 정리한 것이다. 학습자가 추가 문제를 풀거나 이 문단을 자기 언어로 다시 작성한 근거로 취급하지 않는다.

- WriteBatch가 원자적으로 적용하는 것은 준비된 쓰기 묶음이다. 예시의 `Put(count, 101)`은 DB에 “현재 값에서 1 증가”를 요청하는 연산이 아니라, 앞서 읽은 값으로 계산한 101을 저장하는 연산이다. 두 쓰기 모두 원자적으로 성공해도 전체 read-modify-write는 보호되지 않을 수 있다.
- 같은 Snapshot을 사용하는 읽기들은 하나의 논리적 경계를 공유한다. Snapshot 없이 따로 수행한 `Get(A)`와 `Get(B)` 사이에 배치가 공개되면 두 호출의 결과를 합친 값이 배치 전후 상태를 섞을 수 있다. 이는 배치 자체가 부분 적용되었다는 뜻이 아니다.
- 기본 WriteCommitted 설정에서 `txn.Put`은 트랜잭션의 준비된 쓰기에 변경을 쌓는다. `txn.Get`은 이 변경과 DB를 함께 읽지만, 외부 `db.Get`은 커밋 전 변경을 볼 수 없다. 성공한 Commit은 준비된 쓰기를 원자적으로 적용하고, Rollback은 준비된 쓰기를 버린다. 일반 WriteBatch도 쓰기를 메모리에 보관하지만, 일반 `db.Get`에 그 배치를 함께 조회하는 동작은 없다.
- 일반 `txn.Get(x)`은 x를 충돌 검사 대상으로 등록하지 않는다. x를 근거로 y를 쓴다면 `GetForUpdate(x)`로 x의 읽기 의존성을 보호해야 한다. 이후 y에 Put했다는 사실만으로 앞선 x의 읽기가 보호되지는 않는다.
- `GetForUpdate`의 전제는 현재 값이 이전 값과 같은지를 비교하는 데 그치지 않는다. 기본 검증을 사용하는 경우 추적하는 키가 기준 이후 외부에서 변경되었는지를 검사한다. `SetSnapshot()`이 없으면 키별 첫 쓰기 또는 GetForUpdate 시점이 기준이며, 있으면 해당 연산에 적용되는 트랜잭션 Snapshot이 기준이다.
- 5번의 “데이터가 깨졌는지”는 데이터 손상이 아니라 충돌하는 변경이 있었는지 검사한다는 뜻으로 읽어야 한다. 예시는 두 트랜잭션의 준비된 쓰기 중 하나가 경쟁 변경 때문에 적용되지 않는 흐름이다.
- `txn.GetSnapshot()`은 인자를 받지 않고 마지막 `SetSnapshot()`으로 만든 Snapshot을 반환한다. 6번의 `s_past`는 같은 DB에서 미리 얻었고 아직 해제하지 않은 Snapshot을 전제로 한다. 트랜잭션 자체의 준비된 쓰기는 `ReadOptions.snapshot`과 별도로 읽힌다.

근거:

- [Transactions — Atomicity, Reading from a Transaction, Guarding against Read-Write Conflicts](https://github.com/meta/rocksdb/wiki/Transactions)
- [Transaction API — SetSnapshot, GetSnapshot, Commit, Rollback, Get, GetForUpdate](https://github.com/meta/rocksdb/blob/main/include/rocksdb/utilities/transaction.h)
- [Basic Operations — Snapshots](https://github.com/meta/rocksdb/wiki/Basic-Operations#snapshots)
- [WriteBatchWithIndex](https://rocksdb.org/blog/2015/02/27/write-batch-with-index.html)
