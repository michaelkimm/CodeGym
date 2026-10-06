# [RocksDB] Atomic Write, Publication, Durability

- 원본: [학습자가 작성한 Notion 정리](https://app.notion.com/p/3ee74b55ec7c80dd86caf41faf8cf2ca)
- 원본 최종 수정: `2026-10-04T12:49:18.199Z`
- 가져온 날짜: `2026-10-04`
- 아래 본문은 학습자가 작성한 최종 정리다. Notion 전용 서식만 저장소 Markdown으로 변환했으며, 문장과 예시를 새로 작성하지 않았다.

# 1. Atomic Write
---
## 1. WriteBatch를 이용한 원자적 쓰기
RocksDB에선 WriteBatch를 이용하여 여러 Column Family에 대한 쓰기를 원자적으로 할 수 있다.
```javascript
WriteBatch
├─ Delete(email_index, "email/old@example.com")
├─ Put(users, "user/42", { email: "new@example.com" })
└─ Put(email_index, "email/new@example.com", "user/42")

DB::Write(batch)
```
위와 같은 연산을 진행 시 users CF에 email 값 업데이트를 하며 email_index CF에 인덱스 업데이트를 원자적으로 수행한다.
<details>
<summary>출처: [공식 Basic Operations — Atomic Updates](https://github.com/facebook/rocksdb/wiki/Basic-Operations#atomic-updates)</summary>

> Such problems can be avoided by using the `WriteBatch` class to atomically apply a set of updates:
> The `WriteBatch` holds a sequence of edits to be made to the database, and these edits within the batch are applied in order..

</details>
<details>
<summary>출처: [공식 RocksDB Overview — Updates](https://github.com/facebook/rocksdb/wiki/RocksDB-Overview#updates)</summary>

> A `Write` API allows multiple keys-values to be atomically inserted, updated, or deleted in the database. The database guarantees that either all of the keys-values in a single `Write` call will be inserted into the database or none of them will be inserted into the database.

</details>
WriteBatch는 한 DB 인스턴스 내에선 같은 WAL을 사용하기에 가능하다.
<details>
<summary>출처: 2021 RocksDB 논문 §2.2, pp. 5–6</summary>

> Each column family has its own set of MemTables and SSTables, but they share the WAL.
> The shared WAL enables atomic writes to different column families.
[RocksDB: Evolution of Development Priorities in a Key-value Store Serving Large-scale Applications](https://doi.org/10.1145/3483840) · [논문 PDF](https://dl.acm.org/doi/pdf/10.1145/3483840)

</details>

## 2. WAL의 용도와 작성 시점
```javascript
/* Let's exetute WriteBatch code! */
WriteBatch
├─ Delete(email_index, "email/old@example.com")
├─ Put(users, "user/42", { email: "new@example.com" })
└─ Put(email_index, "email/new@example.com", "user/42")

DB::Write(batch)

/*
During DB::Write.. WAL is written first.
Sequence number of the log is assigned from 101 to 103.
*/
101: Delete(email_index, "email/old@example.com")
102: Put(users, "user/42", { email: "new@example.com" })
103: Put(email_index, "email/new@example.com", "user/42")
```
WAL(Write Ahead Log)는 DB에 데이터를 쓰기 전에 먼저 선행하여 기록하는 로그다. in-memory 쓰기 버퍼인 MemTable에 작성하기 전에 WAL에 데이터를 쓴다. 물론 항상 동기로 작성하진 않는다. 구체적인 옵션은 이후에 설명한다.
WAL을 이용하여 프로세스 장애가 일어났을 때 복구를 진행하여 memTable을 재생성할 수 있다. in-memory MemTable에 쓰기를 진행하지만 영속적인 쓰기는 WAL를 이용하기에 WAL은 Durability(내구성)과 Atomicity(원자성)을 보장시킬 수 있다.
<details>
<summary>출처: 같은 논문 §2.2 — Writes, p. 5</summary>

> Whenever data is written to RocksDB, the written data is added to an in-memory write buffer called MemTable, as well as an on-disk Write Ahead Log (WAL).
> The WAL is used for recovery after a failure, but is not mandatory.

</details>
<details>
<summary>출처: [공식 Write Ahead Log — Overview](https://github.com/facebook/rocksdb/wiki/Write-Ahead-Log-%28WAL%29#overview)</summary>

> In the event of a failure, write ahead logs can be used to completely recover the data in the memtable, which is necessary to restore the database to the original state.
> In the default configuration, RocksDB guarantees process crash consistency by flushing the WAL after every user write.

</details>

# 2. Publication
---
## 1. 원자적 가시성(atomic reads) 보장
```javascript
이미 적용되고 공개된 변경

 98: Put(users, "user/42", { email: "old@example.com" })
 99: Put(email_index, "email/old@example.com", "user/42")
100: Put(users, "user/7", { name: "Alice" })

현재 공개 경계 = 100
```
```javascript
DB::Write(batch) 시작

101: Delete(email_index, "email/old@example.com")
102: Put(users, "user/42", { email: "new@example.com" })
103: Put(email_index, "email/new@example.com", "user/42")
```
RocksDB는 원자적 가시성(atomic reads)를 보장한다. 이는 `last_visible_seq`를 통해 달성된다. DB는 변경이 일어나는 연산마다 논리적 순서로서 Sequence number를 부여한다. 연속적인 Seq num 중에 새로운 읽기가 읽어도 되는 경계가 존재하며 DB는 이를 `last_visible_seq`에 저장한다. 유저는 쿼리를 시작할 때 이 값을 읽어 자신이 읽을 수 있는 쓰여진 데이터의 한계를 인지한다. 이 값 이하에 적용된 데이터들은 모두 읽을 수 있고 이후에 쓰여진 것들은 읽을 수 없다.
DB에 적용·공개 후에는 `last_visible_seq`(공개 경계)가 가장 마지막 연산의 seq로 전진하며, 쓰기를 실행한 스레드가 DB에 적용·공개 후에 이어서 읽기를 한다면 101~103 반영분을 읽을 수 있다. 반면, 자신의 WriteBatch 내에서 쓴 데이터는 DB에 적용·공개 되기 전까지는 자신이 읽지 못한다. 적용 중에 101 삭제와 102 새 값이 내부에 들어가 있어도, 읽기 경계가 100이면 그 변경을 포함하지 않은 기존 상태를 읽게된다.
| 단계 | 내부 적용 상태 | 공개 경계 |
| --- | --- | --- |
| 변경 전 | 기존 98·99·100까지 적용됨 | 100 |
| batch 적용 중 | 새 변경 101·102까지 적용됐다고 가정 | **100 유지** |
| batch 적용 완료·공개 | 새 변경 101·102·103 모두 적용됨 | **103으로 전진** |
<details>
<summary>출처: [공식 Unordered Writes — Background](https://github.com/facebook/rocksdb/wiki/unordered_write#background)</summary>

> When a write thread returns to the user, a subsequent read by the same thread will be able to see its own writes.
> When the user takes a snapshot of DB, it will be given the `last_visible_seq`. When the user reads from the snapshot, it only reads values with a sequence number <= the snapshot’s sequence number

</details>
> WriteBatch와 Transaction은 별개의 개념이다 Transaction에선 전체 쓰기 완료 전에도 자신이 쓴 데이터를 읽을 수 있다. Transaction 관련 내용은 추후 다룬다.

## 2. Publication의 조건
### 1. WriteBatch 내 연속적인 seq num의 필요성
여러 WriteBatch가 동시에 실행되고 있다고 가정하자. 만약 서로 다른 WriteBatch 내 연산들의 seq num가 연속적이지 않다면 Batch B의 연산들을 완료했다고 해서 공개할 수 없다. Batch A의 연산들이 노출될 것이다.
```javascript
기존 공개 경계 P = 100

Batch A: 연산 3개 -> Sequence 101, 103, 105
Batch B: 연산 2개 -> Sequence 102, 104
```
따라서 동일 WriteBatch 내에 있는 연산들의 seq num은 연속적으로 할당되도록 RocksDB가 보장한다.
```javascript
Batch A: 연산 3개 → Sequence 101, 102, 103
Batch B: 연산 2개 → Sequence 104, 105
```
<details>
<summary>출처: [공식 Two-Phase Commit Implementation — Sequence ID Distribution](https://github.com/facebook/rocksdb/wiki/Two-Phase-Commit-Implementation#sequence-id-distribution)</summary>

> When a WriteBatch is inserted into a memtable (via MemTableInserter) the sequence ID of each operation is equal to the sequence ID of the WriteBatch plus the number of sequence ID consuming records previous to this operation in the WriteBatch.

</details>
### 2. publication seq num 이전의 모든 seq의 DB에 적용·공개 완료
Batch B가 완료됐다고 해서 105를 `last_visible_seq`로 설정하면 안된다.

# 3. Durability
---
WAL은 in-memory MemTable에 쓰기 전에 작성되는 로그라고 설명했다. 다만 모든 애플리케이션의 경우에 WAL이 동기적으로 disk에 저장된 후 in-memory MemTable에 저장될 필요는 없을 것이다. 성능 저하가 크기 때문. 따라서 WAL을 저장하는 옵션엔 세가지가 있다. 동기적 저장, 비동기적 저장과 저장 않는 옵션이 그것이다.
<details>
<summary>출처: 2021 RocksDB 논문 §4.3 — WAL Treatment, p. 13</summary>

> Specifically, we introduced differentiated WAL operating modes: (i) synchronous WAL writes, (ii) buffered WAL writes, and (iii) no WAL writes at all.
[논문](https://doi.org/10.1145/3483840) · [PDF](https://dl.acm.org/doi/pdf/10.1145/3483840)

</details>
## 1. Synchronous WAL writes
동기적 저장 flag를 설정 시, 유저의 쓰기는 WAL이 영구 저장소에 저장된 후에 반환한다. 프로세스와 머신 장애에 모두 내구성을 가지지만, 성능 희생이 가장 크다.
```javascript
Put("user/42", "Alice", sync=true)
→ WAL 바이트를 OS에 전달
→ WAL을 영속 저장장치에 동기화하고 완료를 기다림
→ MemTable에 적용
→ 읽기에 공개
→ 성공 반환
```
<details>
<summary>출처: [공식 Basic Operations — Synchronous Writes](https://github.com/facebook/rocksdb/wiki/Basic-Operations#synchronous-writes)</summary>

> The `sync` flag can be turned on for a particular write to make the write operation not return until the data being written has been pushed all the way to persistent storage.

</details>
## 2. Buffered WAL writes
비동기적 저장 flag 설정 시, 유저의 쓰기는 WAL을 쓰기를 운영체제 페이지 캐시까지만 쓰고 반환한다. 따라서 프로세스 장애에는 내구성을 가지지만 머신 장애에 대한 내구성을 보장하진 않는다. asynchrounous가 기본 값이다.
프로세스 장애가 발생해도 재실행 시 운영체제 페이지 캐시에 저장된 데이터를 기반하여 MemTable 정보를 복원하기에, 프로세스의 장애에 내구성을 가진다. 머신 장애 시엔 운영체제 페이지 캐시가 비동기적으로 영구 저장소에 데이터를 썼는지 여부에 따라 복구 가능성이 달라진다.
```javascript
Put("user/42", "Alice")
→ WAL 바이트를 OS에 전달
→ MemTable에 적용
→ 읽기에 공개
→ 성공 반환

OS는 이후 WAL 바이트를 영속 저장장치에 반영한다.
```
<details>
<summary>출처: [공식 Basic Operations — Synchronous Writes](https://github.com/facebook/rocksdb/wiki/Basic-Operations#synchronous-writes), [Non-sync Writes](https://github.com/facebook/rocksdb/wiki/Basic-Operations#non-sync-writes)</summary>

> By default, each write to `rocksdb` is asynchronous: it returns after pushing the write from the process into the operating system. The transfer from operating system memory to the underlying persistent storage happens asynchronously.
> The downside of non-sync writes is that a crash of the machine may cause the last few updates to be lost.
> Note that a crash of just the writing process (i.e., not a reboot) will not cause any loss since even when `sync` is false, an update is pushed from the process memory into the operating system before it is considered done.

</details>
## 3. No WAL writes at all
WAL을 아예 저장 안할 수도 있다. 장애 내구성이 필요 없는 경우에 사용한다.
```javascript
Put("user/42", "Alice", disableWAL=true)
→ MemTable에 적용
→ 읽기에 공개
→ 성공 반환

아직 SST에 Flush되지 않은 상태에서 프로세스가 죽음
→ MemTable이 사라짐
→ 이 쓰기를 복구할 WAL 기록도 없음
```
<details>
<summary>출처: [공식 Basic Operations — Non-sync Writes](https://github.com/facebook/rocksdb/wiki/Basic-Operations#non-sync-writes)</summary>

> If you set `write_options.disableWAL` to true, the write will not go to the log at all and may be lost in an event of process crash.

</details>
