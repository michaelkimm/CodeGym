# [RocksDB] 4. 버전과 논리적 시간

- 원본: [학습자가 작성한 Notion 정리](https://app.notion.com/p/40374b55ec7c80ec84e9f7ea8ffe8609)
- 원본 최종 수정: `2026-10-24T11:44:01.538Z`
- 가져온 날짜: `2026-10-24`
- 아래 본문은 학습자의 정리를 Markdown으로 옮긴 것이다. 표·접기·코드 블록 서식을 변환하고 미완성 소제목의 오타를 바로잡았다.
- 평가에서 지적한 `type DESC`의 역할에 관한 한 문장은 설명자가 교정했다. 원래 표현과 교정 이유는 [평가 기록](evaluation.md)에 남겼다.
- 마지막의 “설명자 보완”은 평가 후 추가한 설명이다. 학습자가 별도 답안으로 재구성한 내용과 구분한다. 원본 Notion은 수정하지 않았다.

## 1. InternalKey를 이용한 같은 key 구별

### InternalKey

하나의 column family에는 같은 KV 쌍이 존재할 수 있다. 이를 구별하기 위해 seq과 valueType를 사용한다.

즉 Key는 DB에선 물리적으론 InternalKey로 저장되며  (user\_key, sequence, type)으로 구성된다.

```text
Put("user:7", "Pepper") -> seq 101
Put("user:7", "Doni")   -> seq 102
Delete("user:7")        -> seq 103
```

예를들어, 첫번째 연산 결과로 column family user의 memtable에는 Put이 됐다는 정보(정확히 어떤 정보인지는 이후 설명), “user:7”과 ‘seq 101’로 이루어진 Key가 기록된다. 이 seq는 RocksDB instance 내에서 고유 해야 한다. 이를 통해 읽기 가시성을 확보할 수 있는데, 자세한 얘기는 이후에 설명한다.

<details>
<summary>근거 원문</summary>

[RocksDB 논문 §7.1 — Versions and Timestamps](https://doi.org/10.1145/3483840)

> multiple KV-pairs with the same key may co-exist, differentiated by their sequence numbers.

> each RocksDB instance assigns its own sequence numbers

</details>

<details>
<summary>근거 원문</summary>

[InternalKey — upstream 코드 주석](https://github.com/facebook/rocksdb/blob/c2b86f3ec0ca714e0f63872c3fc610c54ec1b301/db/dbformat.h#L26-L31)

> Each internal key contains a user key, a sequence number (SequenceNumber) and a type (ValueType), and they are usually encoded together.

</details>

type에는 valueType이 들어가며 Put 연산을 의미하는 kTypeValue, 삭제 연산을 의미하는 kTypeDeletion, Merge 연산을 의미하는 kTypeMerge가 있다.

<details>
<summary>근거 원문</summary>

[ValueType — MemTable Lookup](https://github.com/facebook/rocksdb/blob/c2b86f3ec0ca714e0f63872c3fc610c54ec1b301/docs/components/read_flow/04_memtable_lookup.md#savevalue-callback)

| Type | Action |
| --- | --- |
| `kTypeValue` | Return the value, search complete |
| `kTypeDeletion` | Return NotFound, search complete |
| `kTypeMerge` | Push operand to `MergeContext`, continue if merge not finalized |

</details>

### Merge 연산

Merge 연산은 여러 연산을 합치는데 사용한다. Merge 연산에 어떤 Operator를 등록했는지에 따라 연산 종류가 달라진다.

```text
Put("count", 1000)    -> seq 101
Merge("count", +1)    -> seq 102
Merge("count", +10)   -> seq 103
```

덧셈을 수행하는 MergeOperator를 등록했고 위 순서로 연산을 실행 했다고 가정하자. count를 읽을 때 기준 값 1000에서 + Operator 연산자가 1, 10 operand를 merge하여 결과 값 1011을 낸다.

MergeOperator의 특징

- **CF마다 Operator 하나를 따로 등록**할 수 있음.
- **하나의 Operator 내부에서도** key prefix에 따라 덧셈·이어붙이기 등으로 동작을 분기 가능.
- 기능을 추가하거나 구현을 수정해도 **기존 값과 operand가 해석되는 의미는 유지**해야 함. 그렇지 않으면 과거에 기록한 데이터의 읽기 결과까지 달라질 수 있음.

## 2. Key ordering을 이용한 스캔 효율화

```text
Delete("user:7")        -> seq 103
Put("user:7", "Doni")   -> seq 102
Put("user:7", "Pepper") -> seq 101
```

InternalKey는 (user\_key ASC, sequence DESC, type DESC)로 정렬된다. 이를 통해 가장 최신의 연산 결과를 먼저 읽어 불필요한 연산을 줄일 수 있다. 최신 버전을 먼저 찾는 주된 기준은 sequence DESC다. type DESC의 순서는 특정 sequence에서 탐색을 시작할 Seek용 InternalKey의 type 선택에도 영향을 준다.

<details>
<summary>근거 원문</summary>

[InternalKey ordering — 공식 읽기 문서](https://github.com/facebook/rocksdb/blob/c2b86f3ec0ca714e0f63872c3fc610c54ec1b301/docs/components/read_flow/index.md#key-invariants)

> InternalKey ordering (user\_key ASC, sequence DESC, type DESC) ensures newest version found first

</details>

## 3. Key 읽기 가시성

### Get 연산 시

연산 시작 전에 내가 읽을 수 있는 값의 경계를 미리 알고 있으면 새로운 연산이 들어와도 내가 연산을 시작한 시점의 데이터만 읽을 수 있다. RocksDB는 Snapshot을 통해 이를 달성한다.

아래 연산을 진행 했을 때 Get 연산에서 어떤 값을 얻을 수 있는지 생각해보자.

```text
t1 Put(user:7, Alice) 공개 완료  -> seq 101
t2 SnapShot S 획득                 S의 경계 101
t3 Put(user:7, Bob)   공개 완료  -> seq 102
t4 일반 Get(user:7)
t5 S를 지정한 Get(user:7)
t6 Delete(user:7)     공개 완료  -> seq 103
t7 일반 Get(user:7)
t8 S를 지정한 Get(user:7)
```

동시에 다른 쓰기가 없을 경우에 결과는 아래와 같다.

| 읽기 | 읽기 경계 | 결과 |
|---|---|---|
| t4 | 102 | Bob |
| t5 | 101 | Alice |
| t7 | 103 | NotFound |
| t8 | 101 | Alice |

일반 Get은 `GetLastPublishedSequence()`을 사용하고 명시적인 SnapShot이 있으면 그것의 sequence를 사용하여 읽기 가시성을 확보한다.

<details>
<summary>근거 원문</summary>

[Snapshot — Visibility](https://github.com/facebook/rocksdb/wiki/Snapshot)

> If a key's sequence number is smaller than or equal to that of a snapshot, then the key is visible to the snapshot.

</details>

<details>
<summary>근거 원문</summary>

[Basic Operations — Snapshots](https://github.com/facebook/rocksdb/wiki/Basic-Operations#snapshots)

> If `ReadOptions::snapshot` is NULL, the read will operate on an implicit snapshot of the current state.

</details>

### Iterator 연산 시

Iterator를 만들 때도 같다. Iterator가 만들어질 때 명시적인 SnapShot이 있으면 그것을 사용하고 아닐 시에 가장 최근 공개된 Sequence를 읽는다.

```text
Put(k, A) @301
Snapshot S 획득 — 경계 301
Put(k, B) @302
일반 Iterator I 생성
Put(k, C) @303
I.Seek(k)
S를 지정한 Iterator J 생성 후 J.Seek(k)
```

<details>
<summary>근거 원문</summary>

[Iterator — Consistent View](https://github.com/facebook/rocksdb/wiki/Iterator#consistent-view)

> If it is `nullptr`, the iterator will read from an implicit snapshot as of the time the iterator is created.

</details>

## 4. SuperVersion을 활용하여 읽기 구조 확보

SuperVersion을 참조하여 읽을 구조를 확보하고 read sequence에서는 그 구조에서 보일 버전을 정한다.

SuperVersion은 읽을 수 있는 memtable, immutable tables, SSTables를 참조한다. 이를 이용하여 compaction이 일어나도 참조 중인 물리 구조를 유지하고 파일 수명을 관리할 수 있다. RocksDB 또한 compaction이 일어나도, 사용되고 있기에, 당분간은 유지 해야 하는 files를 확인할 수 있다.

```text
SuperVersion
 ├─ mem → 현재 MemTable
 │          a = 1
 │
 ├─ imm → immutable MemTable 목록
 │          b = 2
 │
 └─ current → Version
                └─ SST 파일 목록
                     F1.sst: c = 3
```

<details>
<summary>근거 원문</summary>

[SuperVersion — Impact of Long-Lasting Reads and Snapshots](https://github.com/facebook/rocksdb/blob/553b52b4a709820fac1dbadc7796506740517582/docs/components/read_flow/03_superversion_and_snapshots.md#impact-of-long-lasting-reads-and-snapshots)

> A held SuperVersion reference pins `mem`, `imm`, and `current` (Version).

> The pinned Version prevents obsolete SST files from being deleted after compaction.

</details>

## 설명자 보완

학습자는 세 확인 문제에 대해 “셋다 문제없어. 넘어가.”라고 확인하고 PR 생성과 머지를 요청했다. 다음은 정리의 빈 부분을 보완한 설명이며, 확인 문제에 대한 학습자의 제출 답안은 아니다.

### 읽기 경계와 버전 선택

읽기 경계가 R이면 같은 사용자 키에서 `sequence <= R`인 레코드 중 최신 레코드부터 해석한다. Value를 찾으면 값을 반환하고, Deletion이면 NotFound로 끝내며 더 오래된 Value를 되살리지 않는다. Merge이면 operand를 모으고 MergeOperator로 해석해야 하므로 최신 레코드 하나를 그대로 최종 값으로 반환하지 않는다.

### type DESC와 Seek 경계

기본 Put/Delete 쓰기에서 같은 키의 연속된 변경은 서로 다른 sequence를 받는다. 따라서 type 순서를 같은 sequence를 공유한 Put/Delete의 실행 순서를 정하는 장치로 해석하지 않는다.

그렇지만 검색을 위해 만드는 InternalKey도 같은 비교 규칙을 따른다. `(k, 100, Value=1)`을 찾을 때 검색 키를 `(k, 100, type=0)`으로 만들면, type DESC 순서에서 Value 레코드는 검색 키보다 앞에 놓이므로 Seek가 이를 지나칠 수 있다. 현재 구현의 `kValueTypeForSeek`는 읽기 경계의 레코드를 빠뜨리지 않도록 가장 높은 번호의 유효 ValueType을 사용한다. 이 비교 규칙과 검색 키 구성이 서로 맞아야 한다.

근거: [Seek용 ValueType의 코드 주석](https://github.com/facebook/rocksdb/blob/ea313605367281013c2c81158069e88411516357/db/dbformat.cc#L22-L29). 이 구현 확인은 학습자의 원래 “규칙을 위한 규칙”이라는 표현을 교정하는 보조 근거다.

### CF와 DB 인스턴스의 경계

같은 DB의 CF들은 MemTable과 SST 구성을 따로 가지지만 Sequence 공간과 Snapshot의 논리적 경계는 공유한다. DB A에서 얻은 Snapshot S로 A의 users CF와 orders CF를 같은 논리적 경계에서 읽을 수 있다.

별도 DB B는 Sequence와 Snapshot의 경계를 공유하지 않는다. A와 B에 같은 숫자의 sequence가 있어도 같은 논리적 시점을 의미하지 않으며, A의 Snapshot 객체를 B의 읽기에 재사용할 수 없다.

근거: [논문 §7.1](https://doi.org/10.1145/3483840), [Column Families](https://github.com/facebook/rocksdb/wiki/Column-Families), [Snapshot](https://github.com/facebook/rocksdb/wiki/Snapshot).

### Iterator 예제의 결과

일반 Iterator I가 생성될 때 공개된 최신 sequence는 302이고, 명시적 Snapshot S의 경계는 301이다.

| Iterator | 읽기 경계 | Seek(k)의 결과 |
|---|---|---|
| I | 302 | B |
| S를 지정한 J | 301 | A |

나중에 C@303이 공개되어도 기존 I의 Seek는 읽기 경계를 갱신하지 않는다. 여기서는 일반 Iterator를 다루며 명시적 refresh API는 범위 밖이다.

근거: [Iterator — Consistent View](https://github.com/facebook/rocksdb/wiki/Iterator#consistent-view).

### SuperVersion의 current

SuperVersion의 `current`는 특정 CF의 SST 파일 구성을 나타내는 Version 객체다. 같은 사용자 키의 값 하나를 의미하는 “버전”과 구분한다. MemTable과 immutable MemTable은 SST 파일이 아니므로 SuperVersion은 이들을 `mem`, `imm`으로 별도 참조한다.
