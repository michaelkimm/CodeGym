# [RocksDB] 3. 이미 공개된 값을 실제로 어떤 구조에서 읽는가?

- 원본: [학습자가 작성한 Notion 정리](https://app.notion.com/p/3ef74b55ec7c8072b784ee7a4722a1bc)
- 원본 최종 수정: `2026-10-05T08:06:23.716Z`
- 가져온 날짜: `2026-10-05`
- 아래 본문은 학습자가 작성한 최종 정리다. Notion 서식을 저장소 Markdown으로 변환하고, 그림은 원본 Notion 블록 링크로 보존했다.
- Get 설명의 두 표현은 학습자의 요청에 따라 설명자가 교정했다: MemTable의 “범위 비교 대상”을 “탐색 대상”으로, L1+ 후보 선택의 이유를 “파일 간 키 범위 비중첩”으로 수정했다. 그 밖의 문장과 예시는 다시 작성하지 않았다.

# 1. 저장 구조
---
쓰여진 데이터가 저장 구조를 지나는 flow는 아래와 같다.
## 1. MemTable과 SSTable의 생성 과정
### 1. WAL & MemTable 쓰기
[그림: WAL 기록과 skiplist MemTable](https://app.notion.com/p/3ef74b55ec7c8072b784ee7a4722a1bc#3f074b55ec7c80c3b3bac382c52f69d4)
Wrtie Ahead Log를 포함하여 in-memory write buffer인 MemTable에 먼저 데이터를 기록한다. MemTable는 O(logn)으로 읽고 쓰기 위해 sorted order 형태로 데이터를 저장하고 SkipList로 구현된 in-memory write buffer다.
### 2. Immutable MemTable 생성
[그림: Immutable 전환과 새 MemTableWAL](https://app.notion.com/p/3ef74b55ec7c8072b784ee7a4722a1bc#3f074b55ec7c80ec8eb9c890bbdb6fc1)
MemTable이 일정 이상 크기가 될 경우엔 immutable MemTable이 된다. 그리고 새로운 쓰기를 받을 MemTable이 생성된다.
<details>
<summary>**출처:** [RocksDB Overview — Memtable Pipelining](https://github.com/facebook/rocksdb/wiki/RocksDB-Overview#memtable-pipelining)</summary>
**읽을 범위:** `Memtable Pipelining` 전체.
> RocksDB supports configuring an arbitrary number of memtables for a database. When a memtable is full, it becomes an immutable memtable and a background thread starts flushing its contents to storage. Meanwhile, new writes continue to accumulate to a newly allocated memtable. If the newly allocated memtable is filled up to its limit, it is also converted to an immutable memtable and is inserted into the flush pipeline. The background thread continues to flush all the pipelined immutable memtables to storage. This pipelining increases write throughput of RocksDB, especially when it is operating on slow storage devices.
</details>
### 3. Flush로 인한 SSTable 생성
[그림: SST Flush와 MemTableWAL 정리](https://app.notion.com/p/3ef74b55ec7c8072b784ee7a4722a1bc#3f074b55ec7c80a3a69aec4e83bad154)
immutable MemTable은 Sorted String Table(SSTable) 형태로 디스크에 flush 된다.
<details>
<summary>**출처:** Dong et al., *RocksDB: Evolution of Development Priorities in a Key-value Store Serving Large-scale Applications*, ACM Transactions on Storage, 2021.</summary>
**위치:** §2.2, 본문 페이지 `26:5`. [논문 출처](https://doi.org/10.1145/3483840)
### Writes — MemTable에서 SST로
> Whenever data is written to RocksDB, the written data is added to an in-memory write buffer called MemTable, as well as an on-disk Write Ahead Log (WAL). MemTable is implemented as a skiplist to keep the data ordered with O(log n) insert and search overheads. The WAL is used for recovery after a failure, but is not mandatory. Once the size of the MemTable reaches a configured size, then (i) the MemTable and WAL become immutable, (ii) a new MemTable and WAL are allocated for subsequent writes, (iii) the contents of the MemTable are flushed to a Sorted String Table (SSTable) data file on disk, and (iv) the flushed MemTable and associated WAL are discarded. Each SSTable stores data in sorted order, divided into uniformly sized blocks. Once written, each SSTable is immutable. Every SSTable also has an index block with one index entry per SSTable block for binary search.
</details>
## 2. SSTable이란
SSTable은 sorted key를 가진 Data block들과 해당 block들을 가리키는 Index block이 저장된 파일이다. Index block을 이용하여 binary search하여 읽기를 O(logn)에 처리할 수 있다.
[그림: Sorted data block과 index binary search](https://app.notion.com/p/3ef74b55ec7c8072b784ee7a4722a1bc#3f074b55ec7c80bc95b1e5750214f192)
### 기본 SST 형식 in RocksDB
> BlockBasedTable is the default SST table format in RocksDB.
원문의 파일 배치:
```plain text
<beginning_of_file>
[data block 1]
[data block 2]
...
[data block N]
[meta block 1: filter block]
[meta block 2: index block]
[meta block 3: compression dictionary block]
[meta block 4: range deletion block]
[meta block 5: stats block]
...
[meta block K: future extended block]
[metaindex block]
[Footer]
<end_of_file>
```
### 구성요소
[그림: get filter index data](https://app.notion.com/p/3ef74b55ec7c8072b784ee7a4722a1bc#3f074b55ec7c805c9094fd44334572cd)
1. **Data blocks: **key/value가 key를 기준으로 정렬된 SSTable 내부 블록이다. 연속된 data block들로 파티션된다.
2. **Index Block: **binary search로 Data block을 찾을 때 사용하는 자료구조다. Lookup key가 정렬돼있으며 하나 이상의 index block으로 이루어져있다. 여러개일 경우엔 Partitioned Index block 역할이다.
3. **Full filter: **전체 SST file에 대한 단 하나의 filter다.
4. **Partitioned Filter: **Full filter가 파티셔닝된 Filter다. Key range별로 Partitioned Filter가 생성된다. Key가 주어지면 Filter용 Top-level index를 사용하여 사용할 Partition Filter를 선택한다.
<details>
<summary>**출처:** [Rocksdb BlockBasedTable Format](https://github.com/facebook/rocksdb/wiki/Rocksdb-BlockBasedTable-Format)</summary>
### Data blocks
> The sequence of key/value pairs in the file are stored in sorted order and partitioned into a sequence of data blocks. These blocks come one after another at the beginning of the file. Each data block is formatted according to the code in `block_builder.cc` (see code comments in the file), and then optionally compressed.
### Index Block
> Index blocks are used to look up a data block containing the range including a lookup key. It is a binary search data structure. A file may contain one index block, or a list of partitioned index blocks (see Partitioned Index Filters).
### Full filter
> In this filter there is one filter block for the entire SST file.
### Partitioned Filter
> The full filter is partitioned into multiple blocks. A top-level index block is added to map keys to corresponding filter partitions.
</details>
## 2. Compaction과 Level-N의 SSTable 생성
[그림: Compaction으로 Level-(N1)에 새 SST 쓰기](https://app.notion.com/p/3ef74b55ec7c8072b784ee7a4722a1bc#3f074b55ec7c80498d91f5a8d22d24c4)
RocksDB는 백그라운드에서 Level-N(N≥0) 이상의 SSTable을 Compacition하여  Level-N+1 SSTable을 만든다. Level-N의 SSTable이 일정 조건을 만족할 정도로 커지만 compaction이 발생하여 Level-N+1의 SSTable과 합친다. 물론, SStable은 immutable file이므로 다시 쓰여진다고 보는 것이 맏다.
[그림: L1의 비중첩 범위와 L0의 중첩 범위](https://app.notion.com/p/3ef74b55ec7c8072b784ee7a4722a1bc#3f074b55ec7c80989d22fa94457a3f64)
각 Level-N(N≥1) 내의 SStable들은 겹치는 구간이 존재하지 않는다. Compaction 대상이 상위 레벨의 SSTable과 Level-N의 SSTable이기 때문이다. 다만 Level-0의 SSTable은 겹치는 구간이 존재한다. Immutable MemTable들이 flush 되어 Level-0의 SSTable을 만들지만 이때는 flush만 진행하지 따로 compaction을 진행하지 않는다. 그렇기에 Level-0내 SSTable간 sorted order는 보장할 수 없다.
<details>
<summary>**출처:** Dong et al., *RocksDB: Evolution of Development Priorities in a Key-value Store Serving Large-scale Applications*, ACM Transactions on Storage, 2021.</summary>
**위치:** §2.2, 본문 페이지 `26:5`. [논문 출처](https://doi.org/10.1145/3483840)
### Compaction — level이 만들어지는 배경
> The LSM-tree has multiple levels, as shown in Figure 1. The newest SSTables are created by MemTable flushes, as described above, and are placed in Level-0. The other levels are created by a process called compaction. The maximum size of each level is limited by configuration parameters. When level-L’s size target is exceeded, some SSTables in level-L are selected and merged with the overlapping SSTables in level-(L+1) to create a new SSTable in level-(L+1). In doing so, deleted and overwritten data is removed, and the new SSTable is optimized for read performance and space efficiency. This process gradually migrates written data from Level-0 to the last level. Compaction I/O is efficient, as it can be parallelized and only involves bulk reads and writes of entire files. (To avoid confusion with the terms “higher” and “lower,” given that levels with a higher number are generally located lower in images depicting multiple levels, we will refer to levels with a higher number as older levels.)
이번에는 읽기 구조의 배경으로 읽으면 돼. Compaction의 정확성과 정책은 각각 6·7장에서 다룬다.
### L0의 중첩과 L1 이상의 비중첩
> MemTables and level-0 SSTables have overlapping key ranges, since they contain keys anywhere in the keyspace. Each older level, i.e., a level-1 or older level, consists of SSTables covering non-overlapping partitions of the keyspace. To save disk space, the blocks of SSTables in older levels may optionally be compressed.
</details>
# 2. Get I/O 과정
---
## 1. Binary search with MemTable and SSTable
[그림: get 전체 탐색 ](https://app.notion.com/p/3ef74b55ec7c8072b784ee7a4722a1bc#3f074b55ec7c8036a508deb98ece509b)
Get 요청이 들어올 경우 아래 과정을 거쳐 목표하는 value를 찾게 된다. 키를 찾을 때 까지 계속해서 더 높은 레벨의 SSTable을 찾는다. 키를 찾은 순간 검색을 멈출 수 있지만 찾지 못한 경우엔 모든 레벨을 탐색해야한다.
1. 모든 MemTable들을 검색한다. Immutable 또한 포함된다. MemTable간에 겹치는 key 구간이 존재하기 때문에 기본적으론 모든 MemTable이 탐색 대상이다. 물론 키를 찾으면 멈춘다.
2. 다음으로 모든 Level-0 SSTable을 검색한다. Level-0 또한 SSTable간에 겹치는 key 구간이 존재하기 때문에 기본적으론 모든 SSTable이 범위 비교 대상이다. 물론 키를 찾으면 멈춘다.
3. Level-1+ 부터는 같은 레벨의 SSTable 간 키 범위가 겹치지 않기 때문에 탐색 대상이 되는 SSTable만 찾아 선택적으로 binary search를 진행한다.
> SSTable에서 실제로 binary search를 진행하기 전에 Bloom filter 등을 사용하여 정말로 해당 파일을 읽을 필요가 있을지 확인한다.
<details>
<summary>**출처:** 같은 논문, 본문 페이지 `26:6`, Table 3.</summary>
### Reads — Get, block cache, Bloom filter
> In the read path, a key lookup occurs by first searching all MemTables, followed by searching all Level-0 SSTables, followed by the SSTables in successively older levels whose partition covers the lookup key. Binary search is used in each case. The search continues until the key is found, or it is determined that the key is not present in the oldest level.¹ Hot SSTable blocks are cached in a memory-based block cache to reduce I/O as well as decompression overheads. Bloom filters are used to eliminate most unnecessary searches within SSTables.
> Scans require that all levels be searched.
</details>
## 2. Bloom Filter - ensure \<true,negative\>
\</tr\>
### 1. Full filter vs block-based filter
[그림: full block based filter skip index](https://app.notion.com/p/3ef74b55ec7c8072b784ee7a4722a1bc#3f074b55ec7c80cab3e3d78dfe0a8db0)
Bloom Filter를 이용하여 읽어야 하는 SSTable을 선택할 수 있다. 이때 full filter를 block-based filter 대신 사용할 경우 일부 index block을 불필요하게 읽는 경우를 방지할 수 있다. block-based filter에서 false가 나오면 data block을 읽지 않아도 되서 그것 자체로의 이점은 존재하지만, 결국 index block을 불필요하게 사용했다고도 볼 수 있다. 대신 Full filter를 사용하면 불필요하게 block-based filter를 사용하지 않고 키가 존재할 가능성이 있는 경우에만 index block을 사용하게 된다.
[그림: bloom filter with cpu cache line](https://app.notion.com/p/3ef74b55ec7c8072b784ee7a4722a1bc#3f074b55ec7c8080b865cef288b845f8)
Block-based filter는 cache aligned돼있지 않다. 하나의 key에 대한 filter를 사용하더라도 cache miss가 중간에 발생 가능하다. 그에 비해 full filter는 키 하나를 Bloom filter로 검사할 때 확인하는 여러 비트를 CPU가 한 번에 가져올 수 있는 메모리 구간 안에 모아 둔다. 물론 full filter 사용 시, 더 많은 데이터를 메모리에 올려야하는 점은 감수해야한다. Trade off를 고려하여 full filter와 block-based filter를 중 하나를 선택해야 한다.
<details>
<summary>**출처:** [RocksDB Bloom Filter](https://github.com/facebook/rocksdb/wiki/RocksDB-Bloom-Filter)</summary>
### What is a Bloom Filter?
> For any arbitrary set of keys, an algorithm may be applied to create a bit array called a Bloom filter. Given an arbitrary key, this bit array may be used to determine if the key *may exist* or *definitely does not exist* in the key set. For a more detailed explanation of how Bloom filters work, see this Wikipedia article.
	In RocksDB, when the filter policy is set, every newly created SST file will contain a Bloom filter, which is used to determine if the file may contain the key we're looking for. The filter is essentially a bit array. Multiple hash functions are applied to the given key, each specifying a bit in the array that will be set to 1. At read time also the same hash functions are applied on the search key, the bits are checked, i.e., probe, and the key definitely does not exist if at least one of the probes return 0.
### Full filter가 필요한 이유
> The individual filter blocks in the old format are not cache aligned and could result into a lot of cache misses during lookup. Moreover although negative responses (i.e., key does not exist) of the filter saves the search from the data block, the index is already loaded and looked into. The new format, full filter, addresses these issues by creating one filter for the entire SST file. The tradeoff is that more memory is required to cache a hash of every key in the file (versus only keys of a 2KB block in the old format).
> “Full filter limits the probe bits for a key to be all within the same CPU cache line.”
</details>
### 2. Prefix vs whole key
전체 키의 해시를 bloom filter에 넣지 않고 prefix만 넣을 수도 있다. prefix key의 카디널리티는 whole key 보다 낮으므로 더 적은 데이터 양으로 bloom filter를 구성할 수 있다.
<details>
<summary>**출처:** [RocksDB Bloom Filter](https://github.com/facebook/rocksdb/wiki/RocksDB-Bloom-Filter)</summary>
> By default a hash of every whole key is added to the bloom filter. This can be disabled by setting `BlockBasedTableOptions::whole_key_filtering` to false. When `Options.prefix_extractor` is set, a hash of the prefix is also added to the bloom. Since there are less unique prefixes than unique whole keys, storing only the prefixes in bloom will result into smaller blooms with the down side of having larger false positive rate. Moreover the prefix blooms can be optionally (using `check_filter` when creating the iterator) also used during `::Seek` and `::SeekForPrev` whereas the whole key blooms are only used for point lookups.
</details>
## 3. Iterator의 구현 방식
Iterator를 이용하여 증가하는 키의 값을 순차적으로 가져올 수 있다.
```javascript
iterator = db.createIterator()
iterator.seek("b")

while iterator.valid():
    key = iterator.key()
    value = iterator.value()
    iterator.next()
```
이때 next를 호출 할 때 마다 Get 호출 할 수는 없다. 성능 저하가 심하다. 따라서 아래 순서로 seek과 next가 진행된다.
[그림: iterator 작동 원리](https://app.notion.com/p/3ef74b55ec7c8072b784ee7a4722a1bc#3f074b55ec7c80eeb05cf05301e87202)
1. seek할 때 미리 모든 sorted run(memtable, level-0 file, other levels)에 seek 대상 이상인 첫 키의 위치를 미리 찾아둔다. 포인터들을 각 sorted run마다 둔다고 생각하면 된다.
2. 각 포인터에서 가져온 값들을 메모리에서 병합하여 이번 키 값을 정한다. 이 값들은 메모리에 유지된다.
3. next 진행 시 이전에 선택된 key의 sorted run의 포인터가 전진한다. 메모리에 존재하던 다른 sorted run 내 포인터 값들과 병합을 진행하여 다음 키 값을 정한다.
iterator는 consistent-point-in-time view를 사용한다. 즉 새로운 update가 들어오거나 insert가 들어와도 iterator는 일관된 view로 부터 값을 읽는다.
<details>
<summary>출처: [Prefix Seek — Why Prefix Seek?](https://github.com/facebook/rocksdb/wiki/Prefix-Seek#why-prefix-seek)</summary>
> Normally, when an iterator seek is executed, RocksDB needs to place the position at every sorted run (memtable, level-0 file, other levels, etc) to the seek position and merge these sorted runs. This can sometimes involve several I/O requests. It is also CPU heavy for decompression of several data blocks and other CPU overheads.
</details>
<details>
<summary>출처: [Iterator — Introduction / Consistent View](https://github.com/facebook/rocksdb/wiki/Iterator)</summary>
> All data in the database is logically arranged in sorted order. An application can specify a key comparison method that specifies a total ordering of keys. An Iterator API allows an application to do a range scan on the database. The Iterator can seek to a specified key and then the application can start scanning one key at a time from that point. The Iterator API can also be used to do a reverse iteration of the keys in the database. A consistent-point-in-time view of the database is created when the Iterator is created. Thus, all keys returned via the Iterator are from a consistent view of the database.
</details>
