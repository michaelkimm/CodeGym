# 3. 물리적 탐색 — 최종 평가

- 상태: `통과`
- 평가일: `2026-10-05`
- 최종 정리: [학습자가 작성한 정리](learner-notes.md)
- 원본: [Notion 최종 정리](https://app.notion.com/p/3ef74b55ec7c8072b784ee7a4722a1bc)
- 이 문서는 설명자가 작성한 평가 기록이다. 학습자의 최종 설명은 별도 정리에 보존한다.

## 평가 범위와 전제

이번 과정은 “Get과 Iterator는 어디를 읽는가?”를 중심으로 MemTable·immutable MemTable, SST data/index/filter block, L0 중첩과 L1+ 비중첩, Bloom filter와 block cache, sorted-run 병합과 Iterator의 일관된 읽기 뷰를 다뤘다. 공식 논문 §2.2·Table 3과 공식 문서의 자연어 원문을 주 근거로 사용했다.

- 기본 skiplist MemTable과 BlockBasedTable, 일반적인 leveled 구조를 전제로 한다. MemTable 구현과 Compaction 정책을 모든 구성에 일반화하지 않는다.
- Get의 조기 종료와 삭제 표식 예시는 일반 Put/Delete와 고정된 읽기 시점을 전제로 한다. Merge operand와 Snapshot 버전 선택의 상세는 이번 평가 범위가 아니다.
- L0의 “중첩”은 파일 간 키 범위의 중첩이다. 각 L0 SST 내부는 key 순서로 정렬되어 있다.
- SST 범위 검사, Bloom 검사, index를 통한 후보 Data block 선택, 실제 키 확인을 구분한다. 후보 파일이 여러 개여도 범위 밖 파일은 제외할 수 있으며, 결과를 찾으면 남은 후보를 탐색하지 않아도 된다.
- CPU cache line과 RocksDB block cache는 별개다. Full Filter가 키 하나의 probe bits를 같은 CPU cache line에 배치해도 cache miss 자체를 없애지는 않는다.
- 일반 Iterator는 생성 시점의 일관된 읽기 뷰를 사용한다. 명시적 Snapshot과 refresh의 상세, SuperVersion과 자원 회수의 구현은 다음 과정들에서 다룬다.

## 공개된 기준별 최종 판정

| 기준 | 판정 | 확인한 근거 |
|---|---|---|
| MemTable·immutable MemTable·Flush·SST 연결 | 충족 | 쓰기를 받는 MemTable이 immutable로 전환되고 새 MemTable이 쓰기를 받는 과정, immutable 데이터가 SST로 Flush되는 과정을 설명했다. |
| SST data/index/filter block 구분 | 충족 | key 순서의 데이터가 SST 내부 Data block에 있고, index가 후보 블록을 찾으며, Full Filter와 Partitioned Filter가 존재 가능성을 확인하는 역할임을 설명했다. |
| L0 중첩·L1+ 비중첩과 Get 후보 선택 | 충족 | L0의 여러 후보를 범위로 제외할 수 있음을 확인 문제에서 설명했다. 최종 문서는 조기 종료와 L1+ 파일 간 키 범위 비중첩을 명시한다. |
| Bloom의 보장과 실제 키 확인 | 충족 | Bloom에는 false positive가 있으므로 실제 Data block을 확인해야 한다고 답했다. Full Filter의 양성 결과도 존재 확정이 아니라 가능성임을 최종 문서에 반영했다. |
| Block cache와 CPU cache 효과 구분 | 충족 | 이미 block cache에 있는 블록에서 실제 데이터를 확인하는 흐름을 답했다. CPU cache line을 다시 학습한 뒤, Full Filter의 probe bits가 CPU가 함께 가져올 수 있는 구간에 모인다는 설명을 최종 정리에 반영했다. |
| Iterator Seek·Next와 sorted-run 병합 | 충족 | Seek가 각 run의 시작 커서를 설정하고, Next가 이전에 선택된 쪽을 전진시키며 유지된 다른 후보들과 병합을 계속한다는 과정을 재구성했다. |
| 버전·삭제 표식과 일관된 Iterator 뷰 | 충족 | 새 b와 옛 b의 선택, 삭제된 d의 제외를 확인 문제에서 설명했다. 최종 정리는 생성 이후 update·insert가 들어와도 일관된 읽기 뷰를 유지함을 설명한다. |

최종 판정은 Notion의 최종 재구성, 확인 문제 답변, 대화에서의 오개념 교정과 마지막 수정본을 함께 근거로 삼았다. 공식 인용문이나 설명자가 그린 그림만으로 통과를 판정하지 않았다.

## 확인 문제의 근거

### L0 후보 선택

문제는 A=[a,f], B=[c,z], C=[h,t] 범위에서 Get(m)과 Get(d)의 후보 파일을 고르는 것이었다.

학습자는 “Get(m)은 B와 C를 후보로 남겨. Get(d)는 A,B만 남기고”라고 답했다. 중첩이 있어도 범위 밖 파일을 제외할 수 있다는 핵심은 맞았다. 실제 Get에서 모든 파일의 검사를 반드시 끝내는 것은 아니며, 앞에서 결과를 찾으면 멈춘다는 조건을 최종 정리에 반영했다.

### Bloom 양성 결과와 block cache

Full Filter가 may exist를 반환하고 후보 Data block이 이미 block cache에 있는 상황을 제시했다.

학습자는 “block cache를 실제로 읽어 해당 데이터가 실제로 있는지 확인 해야해. bloom filter는 false, positive가 가능하거든”이라고 답했다. 설명자는 이 경우 SST 파일에서 해당 블록을 다시 가져올 필요가 없다는 경계를 확인했다.

### Iterator와 삭제된 키

최신 MemTable에 b=새 값과 d=삭제 표식이 있고, 오래된 SST에 a, b=옛 값, c, d=옛 값이 있는 상황을 제시했다.

학습자는 b의 새 값과 d의 삭제를 반영한 결과를 설명했다. “삭제 반환”은 API의 삭제 표식 반환이 아니라 NotFound라는 점, Iterator는 a → b=새 값 → c를 반환하고 종료한다는 점을 교정했다.

Next의 구현에 대해서는 처음에 매번 독립적인 Get을 수행한다고 생각했다. 공식 Prefix Seek 원문과 커서 상태 예시를 다시 읽은 뒤, “포인터를 여러개 두는 방법이네”라고 설명하고, 유지된 다른 sorted run의 후보와 전진한 쪽의 후보를 병합해 다음 키를 고른다는 방식으로 재구성했다. 최종 Notion 정리는 이 커서 유지·갱신 방식을 포함한다.

## 학습에서 교정한 경계

- 정렬 기준은 value가 아니라 key이며, Data block은 별도 파일이 아니라 SST 파일 내부의 블록이다.
- L0 파일의 키 범위가 겹친다고 범위 필터링이 불가능한 것은 아니다. 여러 후보가 남을 수 있다는 의미다.
- L1+ 후보를 레벨별로 좁히는 이유는 파일 내부 정렬만이 아니라 같은 레벨 파일 간 범위의 비중첩이다.
- Full Filter 양성 결과는 키의 존재 확정이 아니다. 양성 뒤에도 실제 블록의 키 확인이 필요하다.
- Full Filter는 이후에 구식 block-based Bloom을 한 번 더 사용하는 구조가 아니다.
- CPU cache miss와 RocksDB block cache miss를 구분했다. Filter partition 선택도 해당 partition의 캐시 적중을 보장하지 않는다.
- Seek는 모든 후속 키의 위치를 계산하지 않는다. 각 sorted run에서 시작 위치를 찾고 커서를 유지한다.
- Next는 독립적인 Get의 반복이 아니다. 병합은 Seek에서 시작되고 Next에서도 계속된다.
- 커서 전진이 매번 새 데이터를 RAM으로 가져온다는 뜻은 아니다. 이미 메모리에 있는 블록 안에서 전진할 수 있다.
- 같은 사용자 키의 버전·삭제 처리에서는 여러 커서가 전진할 수 있다. 그림과 최종 설명은 이를 사용자 키 단위로 단순화했다.
- 일반 Iterator의 읽기 시점은 Seek 호출 시점이 아니라 Iterator 생성 시점이다.
- 최종 문서의 MemTable 탐색 대상과 L1+ 비중첩 표현은 학습자가 직접 수정을 요청해 설명자가 교정했다. 이 문장들만을 독립적인 이해 증거로 삼지 않았다.

## 이번 통과에 요구하지 않은 내용

- Prefix Seek의 세부 옵션, prefix_extractor 설정과 모든 제한 조건
- Secondary index 키 설계와 유지 절차의 반복 평가: 책임 경계와 쓰기 유지는 앞선 1·2장의 근거를 유지한다.
- Heap 구현, Iterator 클래스·포인터의 메모리 배치, 전체 merge iterator 코드
- Sequence·InternalKey·Snapshot·SuperVersion의 상세 버전 선택과 물리 자원 수명
- Compaction 정책과 picker, 버전·tombstone 제거의 정확성, restart·checksum

Prefix의 개념과 whole-key 대비 고유 prefix 수의 감소는 읽었지만, Prefix Seek API 활용 숙련까지 통과로 주장하지 않는다. 합의된 전체 커리큘럼을 삭제하거나 재배열하지 않았다.

이 세션은 3장만 완료했다. 4장의 본 학습과 평가는 시작하지 않았다.

## 공식 근거

- [RocksDB 논문 (2021), §2.2·Table 3](https://doi.org/10.1145/3483840)
- [RocksDB Overview — Memtable Pipelining / Compaction Styles](https://github.com/facebook/rocksdb/wiki/RocksDB-Overview)
- [Rocksdb BlockBasedTable Format](https://github.com/facebook/rocksdb/wiki/Rocksdb-BlockBasedTable-Format)
- [RocksDB Bloom Filter](https://github.com/facebook/rocksdb/wiki/RocksDB-Bloom-Filter)
- [Block Cache](https://github.com/facebook/rocksdb/wiki/Block-Cache)
- [Iterator — Introduction / Consistent View](https://github.com/facebook/rocksdb/wiki/Iterator)
- [Prefix Seek — Why Prefix Seek?](https://github.com/facebook/rocksdb/wiki/Prefix-Seek#why-prefix-seek)

현재 구현은 문서 설명을 보충하는 용도로만 확인했다.

- [FilePicker: L0 키 범위 검사](https://github.com/facebook/rocksdb/blob/c2b86f3ec0ca714e0f63872c3fc610c54ec1b301/db/version_set.cc#L360-L399)
- [MergingIterator::Next: 현재 커서 전진과 후보 갱신](https://github.com/facebook/rocksdb/blob/c2b86f3ec0ca714e0f63872c3fc610c54ec1b301/table/merging_iterator.cc#L349-L385)
