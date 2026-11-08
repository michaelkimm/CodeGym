# [RocksDB] 6. Compaction과 데이터 생명주기

- 원본: [학습자가 작성한 Notion 정리](https://app.notion.com/p/40c74b55ec7c80c784c7d791289d50ae)
- 원본 최종 수정: `2026-11-08T08:06:00.593Z`
- 가져온 날짜: `2026-11-08`
- 아래 본문은 학습자가 수정한 최종 정리를 Markdown으로 옮긴 것이다. 소제목 수준·접기·문단·코드 블록 서식만 변환하고 문장은 유지했다.
- 마지막의 “문답에서 학습자가 직접 교정한 내용”은 실제 답변을 옮긴 것이다. 원본 Notion은 수정하지 않았다.
- 공개한 통과 기준별 판정과 교정 근거는 [평가 기록](evaluation.md)에 남겼다.

## 1. Flush로 SST 생성

flush를 하여 영속적으로 저장될 때 불필요한 논리적인 레코드는 제외된다. 아래 연산을 실행 했을 때 1,2는 남아있지 않고 3만 있는 채로 sstable이 생성된다.

```text
1. Put(k, A) @10
2. Put(k, B) @20
3. Delete(k) @30
4. Flush()
```

그 결과 아래와 같은 SST가 만들어진다

```text
SuperVersion
 ├─ mem → 현재 MemTable
 │
 ├─ imm → immutable MemTable 목록
 │
 └─ current → Version
                └─ SST 파일 목록
```

<details>
<summary>근거 원문</summary>

[garbage-collection-during-memtable-flush](https://github.com/meta/rocksdb/wiki/RocksDB-Overview#garbage-collection-during-memtable-flush)

> When a memtable is being flushed to storage, an inline-compaction process is executed.

</details>

## 2. Compaction으로 sorted data 병합 및 새 version 설치

Compaction으로 인해 정렬된 데이터가 병합되면 읽기가 참조할 수 있는 새 Version을 설치한다. 기존 읽기들이 참조하고 있는 Version은 새 Version 설치와 무관하게 계속 읽힐 수 있다.

```text
현재 Version V1 = {F1, F2, F9}

1. F1, F2의 정렬된 레코드를 병합한다.
2. 필요한 레코드만 모아 F1+F2=F3을 완성한다.
3. 새 Version V2 = {F3, F9}를 설치한다.
4. 새 읽기는 V2를 사용한다
5. 기존 읽기는 V1를 사용한다.
```

### Before

```text
현재 존재하는 SST 파일 목록
- F1.sst: ...
- F2.sst: ...
- F9.sst: ...

SuperVersion
 ├─ mem → 현재 MemTable
 │          ...
 │
 ├─ imm → immutable MemTable 목록
 │          ...
 │
 └─ current → Version 1
                └─ SST 파일 목록
                     F1.sst: ...
                     F2.sst: ...
                     F9.sst: ...
```

### After

```text
현재 존재하는 SST 파일 목록
- F1.sst: ...
- F2.sst: ...
- F3.sst: ...
- F9.sst: ...

SuperVersion
 ├─ mem → 현재 MemTable
 │          ...
 │
 ├─ imm → immutable MemTable 목록
 │          ...
 │
 └─ current → Version 2
                └─ SST 파일 목록
                     F3.sst: ...
                     F9.sst: ...
```

<details>
<summary>근거 원문</summary>

[How-we-keep-track-of-live-SST-files](https://github.com/meta/rocksdb/wiki/How-we-keep-track-of-live-SST-files)

> In the end of a compaction or a mem table flush, a new `version` is created for the updated LSM tree.

</details>

> Version과 SuperVersion은 다르다. Version은 어떤 SST 파일들이 현재 LSM을 구성하는지 나타내고 SuperVersion은 그 Version과 memtable, imm을 묶은 읽기용 물리 뷰다.

## 3. 논리적인 자원 정리

아래 연산이 실행 됐을 때 A는 남고 B는 남지 않는다. Flush나 Compaction을 통해 파일을 영속화하고 최적화 하더라도 스냅샷이 읽을 수 있는 데이터는 보존 돼야 한다. 이때 @10은 Snapshot S에 의해 참조되기에 보존될 필요가 있다. 하지만 @20은 아무도 참조하는 곳이 없기에 Flush 혹은 Compaction에서 지워져도 된다.

<details>
<summary>근거 원문</summary>

[flushcompaction](https://github.com/meta/rocksdb/wiki/Snapshot#flushcompaction)

> ensures that the data visible to each snapshot is preserved.

</details>

### Tombstone의 안전한 제거

Tombstone을 없앨 땐 오래된 값이 부활할지 확인 돼야 한다. 즉 더 오래된 레벨에 해당 키가 없는지 확인 해야 한다.

아래 경우에, 당연히 @30는 삭제되면 안된다. @30이 삭제되면 @10이 부활하기 때문이다. tombstone을 없앨 땐 오래된 값이 부활할지 확인 돼야 한다.

<details>
<summary>근거 원문</summary>

[https://www.eecg.toronto.edu/\~stumm/Papers/Dong-ACMToS21.pdf#page=18](https://www.eecg.toronto.edu/~stumm/Papers/Dong-ACMToS21.pdf#page=18)

> the key is not present in any SSTable at one of the older levels.

</details>

```text
1. Put(k, A) @10
2. Snapshot S 획득 - 경계 10
3. Put(k, B) @20
4. Delete(k) @30
5. Flush()
```

```text
SuperVersion
 ├─ mem → 현재 MemTable
 │
 ├─ imm → immutable MemTable 목록
 │
 └─ current → Version
                └─ SST 파일 목록
                      F1.sst: ...
                         k = Delete. @30
                         k = A.      @10
```

Snapshot이 없어도 tombstone을 함부로 버릴 수 없는 경우도 있다.

```text
살아 있는 Snapshot 없음
L1: Delete(k)@30
L3: Put(k,A)@10

L1 → L2 Compaction 수행, L3는 입력에 포함되지 않음
```

Flush와 Compaction 전후에도 읽기 뷰가 참조하고 있는 논리적인 값은 같아야 한다. 일관성은 Snapshot이 참조하는 seq로 달성 가능하다. 물론 mem, imm, sst 중 어떤 파일을 읽을지는 달라질 수 있다. 따라서 flush와 compaction로 인한 물리적인 자원 정리가 논리적인 일관성에 영향을 주면 안된다. 이 방법은 다음 파트에서 서술한다.

## 4. 물리적인 자원 정리

iterator와 같은 객체를 사용하면 참조하고 있는 물리 뷰가 고정 돼야 한다. SuperVersion을 이용하여 참조할 물리 구조들의 각 table에 seek를 할 pointer를 설정해두기 때문이다. Flush 혹은 Compaction이 발생했다고 해서 컴팩션 대상 파일이 바로 물리적으로 정리가 된다면 해당 pointer가 가리킬 next가 달라진다. 따라서 SuperVersion이 존재하는 한 이것이 참조하는 물리 구조는 유지돼야한다.

물리적인 자원 정리는 compaction이 아닌 해당 물리 데이터에 대한 참조가 모두 풀렸을 때 진행된다. 따라서 아래 상황에서도 F1, F2는 Version 1를 참조하고 있는 곳이 모두 해제 돼야 물리적으로 정리될 수 있다. 논리적인 자원 정리와 물리적인 자원 정리는 다르다.

<details>
<summary>근거 원문</summary>

[resource-pinned-by-iterators-and-iterator-refreshing](https://github.com/meta/rocksdb/wiki/Iterator#resource-pinned-by-iterators-and-iterator-refreshing)

> they are still preserved if an iterator pinned them.

</details>

```text
현재 존재하는 SST 파일 목록
- F1.sst: ...
- F2.sst: ...
- F3.sst: ...
- F9.sst: ...

SuperVersion
 ├─ mem → 현재 MemTable
 │          ...
 │
 ├─ imm → immutable MemTable 목록
 │          ...
 │
 └─ current → Version 2
                └─ SST 파일 목록
                     F3.sst: ...
                     F9.sst: ...
```

## 문답에서 학습자가 직접 교정한 내용

다음은 별도 오답노트 대신 대화에서 제출한 학습자의 실제 답변이다. 설명자가 작성한 모범 답안과 구분한다.

### Flush 출력과 immutable MemTable의 구별

> F1에 반영돼. F1은 current가 참조하는 Version의 SST 목록에 들어가. imm이랑 SST를 헷갈렸네.

이 답변 후 최종 Notion에서 1절 제목을 “Flush로 SST 생성”으로 바꾸고, 3절의 Flush 출력 레코드를 `current → Version → SST 파일 목록 → F1.sst` 아래에 배치했다.

### Compaction 이후 기존 Iterator의 읽기 대상

> F1, F2 자체의 내용은 바뀌지 않았어. 근데 I는 F1, F2를 계속 순회할거야

최종 Notion 4절에는 사용 중인 물리 구조의 참조가 모두 해제되어야 회수할 수 있다는 설명을 함께 남겼다.
