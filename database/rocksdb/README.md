# RocksDB 학습 목표

상위 학습 목표와 [공통 출처 원칙](../README.md#학습-원칙), [학습·통과 절차](../README.md#학습과-통과-절차)는 [`database/README.md`](../README.md)를 따른다.

RocksDB를 단일 노드에 내장되는 LSM 기반 ordered key-value storage engine으로 이해한다. 하나의 key update가 만든 논리 버전이 어디에 기록되고 언제 공개되며, 탐색, Flush, Compaction, 삭제, 공간 회수와 장애 후 복구 과정에서 어떻게 유지·재구성·제거되는지 추적한다. 또한 여러 key를 묶는 원자성과 충돌 제어가 이 흐름에 어떤 보장을 더하는지 설명할 수 있어야 한다.

RocksDB만 고립해서 암기하지 않는다. 『Database Internals』에서 배운 파일 구조, 동시성 제어, 복구, 무결성, 자원 관리 원리를 RocksDB에 적용하고, 이후 Berkeley DB, InnoDB, PostgreSQL과 비교할 수 있는 기반을 만든다.

## 최종 이해 평가 축

아래 8개 축은 학습 순서가 아니라 RocksDB 학습을 마쳤을 때 갖춰야 할 이해를 평가하는 관점이다.

| 평가 축 | 중심 질문 | RocksDB에서 설명할 수 있어야 하는 것 |
|---|---|---|
| 1. 요구사항과 경계 | RocksDB는 어떤 문제를 해결하고 무엇을 상위 계층에 남기는가? | RocksDB가 byte-array key를 comparator 순서로 정렬하고 byte-array value와 함께 저장하는 embedded single-node engine임을 설명한다. SQL, JOIN, schema, constraint, secondary index의 자동 유지, shard 배치, replication, consensus는 기본 엔진의 책임이 아니며, 필요한 인덱스와 제약의 의미·유지 절차를 애플리케이션이 설계하고 필요에 따라 RocksDB의 원자성·충돌 제어 수단을 조합해야 한다는 경계를 구분한다. |
| 2. 저장과 탐색 | 값은 어디에 있고 point lookup과 range scan은 어떻게 다른가? | MemTable, immutable MemTable, SSTable의 data/index/filter block, block cache, L0의 겹치는 범위와 L1 이상의 겹치지 않는 범위를 연결한다. `Get`이 Bloom filter로 많은 파일을 제외하는 과정과 Iterator가 여러 MemTable·run·level을 정렬 병합하며 tombstone의 영향까지 받는 과정을 구분한다. |
| 3. 변경과 비용 이연 | 현재의 작은 쓰기가 미래에 어떤 비용을 만드는가? | Put, Delete, Merge가 WAL, MemTable, Flush, Compaction을 거치는 과정을 설명한다. Leveled와 Universal/Tiered를 대표 사례로 read, write, space amplification의 비용 배치를 비교하고 워크로드 선택에 연결한다. 정책·옵션 전체의 암기와 compaction picker 내부 구현은 요구하지 않는다. |
| 4. 동시성과 가시성 | 여러 읽기와 쓰기가 겹칠 때 무엇이 보이고 충돌은 어떻게 처리되는가? | InternalKey, Sequence Number, LastPublishedSequence, Snapshot, read sequence, SuperVersion으로 논리적 시점과 물리 구조 뷰를 구분한다. WriteBatch atomicity와 transaction isolation의 차이, `TransactionDB`의 비관적 잠금, `OptimisticTransactionDB`의 commit-time conflict validation, `GetForUpdate`의 역할과 wait·abort·retry 비용을 설명한다. |
| 5. 장애, 복구, 무결성 | 성공한 쓰기는 어떤 장애까지 살아남고 저장된 바이트가 손상되면 어떻게 아는가? | `sync=true`, buffered WAL, no-WAL과 process crash, machine/power crash를 구분한다. `CURRENT → MANIFEST → VersionSet과 live SST 집합 → WAL replay → MemTable 재구성` 흐름으로 재시작을 설명하고 Flush를 commit으로 해석하지 않는다. Durability와 data integrity, checksum을 이용한 손상 탐지와 정상 replica·backup을 이용한 복구를 구분한다. |
| 6. 시간 경과와 자원 | 오래 실행될수록 죽은 버전과 백그라운드 작업은 어떤 압력을 만드는가? | tombstone, 과거 버전, 오래된 Snapshot과 Iterator가 논리 버전 또는 물리 파일의 회수를 어떻게 지연하는지 구분한다. 단일 DB에서 입력 쓰기율이 Flush·Compaction 처리 능력을 넘을 때 backlog, LSM 비대화, amplification 증가, foreground write stall로 이어지는 과정을 설명한다. 다중 인스턴스의 공유 예산·공정성·컨트롤러는 논문 사례로 읽으며 운영 설계·설정 능력을 필수로 평가하지 않는다. |
| 7. 분산 책임 경계 | 상위 분산 시스템을 위해 무엇을 제공하고 무엇을 보장하지 않는가? | Snapshot과 Checkpoint, logical copy와 physical copy, live-file 고정, Backup Engine의 역할을 구분한다. RocksDB가 제공하는 로컬 원자성·복구·복사 재료와 상위 시스템이 담당하는 replication order, consensus, cross-shard transaction, 전역 논리 시점, load balancing, backup 정책을 구분한다. |
| 8. 설계 평가 | 어떤 워크로드와 하드웨어에서 RocksDB와 LSM이 적합한가? | point/range 읽기, 쓰기량, value 크기, 필요한 보장, SSD·메모리·CPU 조건을 바탕으로 LSM과 B+tree 계열을 검토할 이유와 측정 지표를 제시한다. 로컬 SSD를 중심으로 발전한 전제와 큰 value 분리 같은 대안을 고려하되 보편적인 승자를 선언하지 않는다. |

Column Family와 DB 인스턴스의 경계는 모든 단계에 걸쳐 다음과 같이 유지한다.

- 같은 DB의 Column Family는 각자의 MemTable, SSTable, 설정을 가지지만 WAL과 Sequence 공간을 공유한다.
- 하나의 WriteBatch 또는 Transaction은 같은 DB의 여러 Column Family에 대한 변경을 원자적으로 묶을 수 있다.
- 서로 다른 DB 인스턴스는 Sequence, Snapshot, WAL, atomic commit 경계를 공유하지 않는다.
- Column Family는 관계형 또는 columnar database의 column과 같은 개념이 아니다.

## 애플리케이션 확장 기능의 경계

- Merge Operator는 read-modify-write의 일부 비용을 지연시키지만, unresolved operand가 길어지면 읽기와 Compaction 비용이 증가한다.
- Compaction Filter는 TTL이나 MVCC garbage collection에 활용할 수 있지만, 잘못 사용하면 Snapshot의 반복 읽기 같은 보장을 약화할 수 있다.
- 4장에서 배운 Merge Operator는 참조한다. Compaction Filter의 TTL·MVCC garbage collection 사례와 Snapshot 반복 읽기·여러 키의 원자성에 미치는 영향은 10장의 논문 전체 완독에서 다룬다. 별도의 callback 과정, 구현 코드와 모든 옵션의 암기는 요구하지 않는다.

## 출처와 학습 깊이

- RocksDB의 주 근거는 2021 RocksDB 논문과 현재 공식 문서의 자연어 설명이다.
- SuperVersion, LastPublishedSequence, MANIFEST recovery, TransactionDB처럼 논문만으로 부족한 내용은 공식 문서를 먼저 사용하고, 공식 자연어 근거만으로 확인하기 어려운 동작에만 현재 upstream 코드를 보조 근거로 사용한다.

Checksum은 RocksDB 핵심 완료 범위에 포함한다. 다만 checksum과 CRC의 구현 알고리즘, 모든 관련 옵션은 학습하지 않고 `durability와 integrity의 차이`, `탐지와 복구의 차이`, `검증 범위`까지만 배운다.

On-disk format versioning과 compatibility의 개념 및 RocksDB 논문 §4.4의 upgrade, rollback, file copy 사례는 『Database Internals』 3장의 일반 원리와 연결해 10번의 논문 전체 완독과 종합 평가에서 다룬다. 이 과정은 개념과 논문 사례의 이해까지를 범위로 한다.

## 학습 순서

앞의 8개 평가 축은 최종 이해를 평가하는 관점이고, 아래 10개 과정은 그 목표에 도달하기 위한 학습 순서다. 한 인스턴스의 읽기·쓰기에서 시작해 동시성과 데이터 생명주기, 장애 후 복구, 일관된 복사, 비용과 설계 선택으로 연결한다.

아래 표의 `주 근거`에는 논문과 공식 문서만 적는다. 현재 upstream 코드는 공식 자연어 근거만으로 부족한 동작을 확인하는 보조 근거다.

현재 1~6장은 `통과`, 7~10장은 `미학습`이다. 다음 과정은 **7. 재시작과 데이터 무결성**이다.

### 1부: 한 인스턴스에서 읽고 쓰기

| 순서 | 중심 질문 | 주요 내용 | 주 근거 |
|---|---|---|---|
| 1. 책임과 데이터 모델 | RocksDB는 어떤 형태의 데이터를 어떤 인스턴스 경계에서 저장하는가? | ordered byte-array KV, embedded single-node library, local SSD 중심의 설계 배경, DB·Column Family·인스턴스 경계 | 논문 §1, §2.1, §2.2, §7과 공식 Basic Operations·Column Families 문서 |
| 2. 쓰기와 공개 | Put은 언제 기록되고 언제 독자에게 보이는가? | WriteBatch, 여러 KV와 Column Family의 원자적 변경, secondary index 쓰기 유지, Sequence 할당, WAL, MemTable, LastPublishedSequence, `sync`, no-WAL, acknowledgement | 논문 §2.2, §4.3과 공식 Basic Operations·Write-Ahead Log 문서 |
| 3. 물리적 탐색 | Get과 Iterator는 어디를 읽는가? | MemTable·immutable MemTable, SST data/index/filter block, block cache, Bloom filter, L0 중첩, L1+ 비중첩, point lookup과 merge iterator, secondary index와 prefix scan | 논문 §2.2, Table 3과 공식 Basic Operations·Iterator·Prefix Seek 문서 |
| 4. 버전과 논리적 시간 | 같은 키의 여러 버전 중 무엇이 보이는가? | InternalKey, ValueType, Snapshot, read sequence, SuperVersion, 일반 Get과 Snapshot Get, Column Family와 인스턴스별 Sequence | 논문 §7.1과 공식 Snapshot 문서 |

### 2부: 동시성과 Compaction

| 순서 | 중심 질문 | 주요 내용 | 주 근거 |
|---|---|---|---|
| 5. 원자성과 충돌 제어 | 여러 read-modify-write가 겹치면 어떻게 되는가? | WriteBatch atomicity와 isolation, lost update, `TransactionDB`, `OptimisticTransactionDB`, `GetForUpdate`, wait·timeout·abort·retry, `UNIQUE` 같은 논리적 제약조건 유지 | 공식 Transactions 문서 |
| 6. Compaction 정확성과 데이터 생명주기 | 물리 구조가 바뀌어도 왜 논리 결과가 유지되는가? | immutable MemTable, Flush, sorted-run merge, 새 Version 설치, Snapshot이 요구하는 과거 버전 보존, tombstone의 안전한 제거, SuperVersion과 obsolete file 회수 | 논문 §2.2, §6.3과 공식 Compaction·Snapshot 문서 |

### 3부: 복구와 복사

| 순서 | 중심 질문 | 주요 내용 | 주 근거 |
|---|---|---|---|
| 7. 재시작과 데이터 무결성 | 재시작 후 일관된 상태를 어떻게 복원하고, 남아 있는 데이터의 손상은 어떻게 발견하는가? | CURRENT → MANIFEST → live SST·VersionSet 복원 → WAL replay·MemTable 재구성, checksum의 탐지·검증 범위, 내구성과 무결성·탐지와 복구의 구별 | 논문 §5와 공식 MANIFEST·WAL·Full File Checksum and Checksum Handoff 문서 |
| 8. 일관된 복사와 복제·백업 경계 | 변경 중인 DB를 일관되게 복사하려면 무엇이 필요하며 복제·백업의 책임은 어디에 있는가? | Snapshot과 Checkpoint, logical/physical copy, live-file 고정, Backup Engine의 역할, replication order·consensus·전역 시점과 백업 정책의 상위 시스템 책임 | 논문 §4.2, §7.1과 공식 Checkpoints·Backup Engine 문서 |

### 4부: 설계 판단과 전체 회수

| 순서 | 중심 질문 | 주요 내용 | 주 근거 |
|---|---|---|---|
| 9. 워크로드에 따른 LSM의 비용과 선택 | 주어진 워크로드와 하드웨어에서 LSM은 무엇을 얻고 어떤 비용을 지불하는가? | Leveled·Universal/Tiered 대표 정책의 read/write/space amplification, 단일 DB의 backlog·write stall, point/range 비율·value 크기·하드웨어, 큰 value 분리, LSM과 B+tree 비교·측정 지표 | 논문 §2.2 Table 3, §3.1–§3.5, §6.3과 공식 Compaction·Write Stalls 문서 및 『Database Internals』 |
| 10. 논문 전체 완독과 종합 평가 | 빠뜨린 문맥 없이 논문의 설계를 읽고 데이터 생명주기와 설계 선택을 연결할 수 있는가? | 논문 전체 완독, callback·다중 인스턴스 자원 공유를 사례로 이해, format compatibility·configuration·column support·failed initiatives, 단일 DB 생명주기와 워크로드 선택의 종합 평가 | 논문 전체 |

### 남은 과정의 깊이

- **7장:** 2장의 WAL 모드·장애별 내구성은 참조하고 재시작 시 구조 복원에 집중한다. 무결성은 바이트 손상의 탐지, block·file checksum의 검증 범위, 정상 replica·backup을 이용한 복구의 경계까지만 다룬다. checksum 알고리즘과 모든 복구 옵션은 제외한다.
- **8장:** 변경 중에도 일관된 복사를 만드는 재료와 복제·백업의 책임 경계를 배운다. Backup Engine API 사용법이나 운영 절차 전체까지 확장하지 않는다.
- **9장:** 대표 Compaction 정책의 구조와 비용을 실제 워크로드 선택에 연결한다. 자명한 자원 총합의 일반론, 모든 정책·옵션·벤치마크 수치의 암기는 요구하지 않는다.
- **10장:** 논문은 처음부터 끝까지 읽되 이미 통과한 기초 설명과 장별 반복 평가는 생략한다. 앞 과정에서 빠진 문맥과 새 연결을 다루고, 단일 DB 생명주기와 워크로드 선택을 종합 평가한다. callback과 다중 인스턴스 자원 공유는 사례로 이해하며 구현·운영 설계 능력을 필수로 평가하지 않는다.

### 과정 개편 기록

2026-11-08 합의에 따라 기존 13개 과정을 10개로 정리했다. 기존 7장의 정책·증폭·backlog·stall은 새 9장에 통합하고, 기존 8장의 callback과 10장의 다중 인스턴스 자원 관리는 새 10장의 논문 사례로 옮겼다. 기존 9·11·12·13장은 새 7·8·9·10장이 되었다. 1~6장의 통과 기록은 보존하며 그 기록에 남은 이후 장 번호는 작성 당시 목차 기준이다.

## 과정별 학습 기록

아래에는 RocksDB 과정별 상태, 학습 자료와 학습자 정리의 링크, 최종 평가를 기록한다.

### 1. 책임과 데이터 모델

- 상태: `통과`
- [AI가 제공한 학습 자료와 통과 기준](chapters/01-responsibility-and-data-model/lesson.md)
- [학습자가 직접 작성한 정리](chapters/01-responsibility-and-data-model/learner-notes.md)
- 최종 평가: 공식 원문 학습, 자기 언어의 재구성, single node와 storage 위치의 구분 및 Column Family 경계에 대한 오개념 교정을 완료해 통과했다. 아직 배우지 않은 Sequence Number·Snapshot이나 이후 과정의 secondary index·constraint·복제·백업 구현은 통과 기준에 포함하지 않았다.
- 통과 커밋: `eabd4ee record-rocksdb-responsibility-data-model-learning`

### 2. 쓰기와 공개

- 상태: `통과`
- [학습자가 직접 작성한 정리](chapters/02-write-publication/learner-notes.md)
- [통과 기준별 최종 평가와 교정 기록](chapters/02-write-publication/evaluation.md)
- 최종 평가: 여러 KV·Column Family의 원자적 변경, Sequence 할당과 publication의 안전 조건, WAL·MemTable의 역할, 세 WAL 모드의 장애별 내구성, 가시성과 내구성의 차이를 자기 언어로 설명해 통과했다. WriteBatch와 Transaction 용어의 혼동을 교정했으며, WriteGroup 내부 구현과 UNIQUE 사례의 문서 반복은 평가에서 제외했다.
- 평가일: `2026-10-04`

### 3. 물리적 탐색

- 상태: `통과`
- [학습자가 직접 작성한 정리](chapters/03-physical-lookup/learner-notes.md)
- [통과 기준별 최종 평가와 교정 기록](chapters/03-physical-lookup/evaluation.md)
- 최종 평가: MemTable·SST의 저장 구조, data/index/filter block과 두 cache의 역할, L0 중첩·L1+ 비중첩을 이용한 Get 후보 선택과 조기 종료, Bloom의 false positive, Iterator의 커서 유지·갱신과 지속적인 sorted-run 병합 및 일관된 읽기 뷰를 설명해 통과했다. Prefix Seek 세부 옵션은 이번 통과에 요구하지 않았다.
- 평가일: `2026-10-05`

### 4. 버전과 논리적 시간

- 상태: `통과` — 추가 풀이 생략에 대한 학습자의 진행 승인
- [학습자가 작성한 정리와 설명자 보완](chapters/04-versions-and-logical-time/learner-notes.md)
- [기준별 평가와 진행 승인 기록](chapters/04-versions-and-logical-time/evaluation.md)
- 최종 평가: InternalKey·ValueType, 읽기 경계별 Get·Delete·Merge 해석, Iterator의 읽기 시점, Snapshot과 SuperVersion의 역할 구분을 확인했다. type 순서의 역할과 CF·DB 경계, Iterator 예제의 결과는 설명자가 보완했으며 추가 답안은 받지 않았다. 학습자가 세 확인 문제의 추가 풀이를 생략하고 진행하라고 승인해 통과로 기록했다.
- 평가일: `2026-10-24`

### 5. 원자성과 충돌 제어

- 상태: `통과` — 일부 추가 풀이 생략과 정리·평가 범위 제외에 대한 학습자 승인 반영
- [학습자가 작성한 최종 정리와 설명자 보완](chapters/05-atomicity-and-conflict-control/learner-notes.md)
- [기준별 평가와 생략·제외 승인 기록](chapters/05-atomicity-and-conflict-control/evaluation.md)
- 최종 평가: WriteBatch와 isolation의 차이, lost update, 비관적 잠금과 낙관적 커밋 검사, 읽기 Snapshot과 충돌 기준의 구분을 확인했다. isolation 정의와 같은 Snapshot을 공유하는 읽기 조건은 학습자가 수정했다. Transaction 가시성과 읽기 의존성의 추가 풀이, 대기·timeout·abort·retry와 UNIQUE의 별도 정리·평가는 학습자 승인으로 생략·제외했으며 독립적인 재검증을 마쳤다고 기록하지 않는다.
- 평가일: `2026-11-02`
- 이번 세션은 5장만 종료했다. 6장은 아직 시작하지 않았다.

### 6. Compaction 정확성과 데이터 생명주기

- 상태: `통과`
- [학습자가 작성한 최종 정리와 직접 교정한 답변](chapters/06-compaction-correctness-and-data-lifecycle/learner-notes.md)
- [통과 기준별 최종 평가와 교정 기록](chapters/06-compaction-correctness-and-data-lifecycle/evaluation.md)
- 최종 평가: Flush 출력 SST와 immutable MemTable의 구별, 정렬 병합과 새 Version 설치, Snapshot의 과거 버전 보존, tombstone의 하위 레벨 확인 조건, Iterator·SuperVersion의 물리 자원 보존과 obsolete file 회수를 설명해 통과했다. Flush의 출력 위치와 기존 Iterator의 순회 대상을 문답으로 교정하고 최종 Notion의 제목·그림·연결 표현을 재확인했다.
- 평가일: `2026-11-08`
- 이번 세션은 6장만 종료했다.

## 종료 시험

다음 흐름을 보고 논리 결과와 물리 상태를 함께 설명할 수 있어야 한다.

```text
Put(v1)
→ Snapshot S
→ concurrent read-modify-write
→ Put(v2)
→ Delete
→ Flush
→ Compaction
→ 일반 Get / Snapshot Get / Iterator
→ process crash 또는 power loss
→ 재시작
```

최소한 다음 질문에 답할 수 있어야 한다.

- 각 읽기가 반환하는 값과 그 값을 선택한 Sequence 경계는 무엇인가?
- plain RocksDB, TransactionDB, OptimisticTransactionDB에서 동시 변경의 결과가 왜 다른가?
- 각 버전과 tombstone이 존재할 수 있는 물리 구조와 안전하게 제거되는 시점은 언제인가?
- Snapshot과 SuperVersion 또는 Iterator가 각각 무엇의 생존을 요구하는가?
- 재시작할 때 MANIFEST, SST, WAL이 각각 어떤 역할을 하는가?
- checksum 실패는 무엇을 의미하며 RocksDB 단독으로 원본을 복원할 수 있는가?
- 이 생명주기에서 발생하는 read, write, space amplification은 무엇인가?

단일 DB에서 입력 쓰기율이 Flush·Compaction 처리 능력을 넘는 상황을 비용·backlog·write stall과 연결하고, 주어진 워크로드에 적합한 구조와 대표 Compaction 정책을 선택할 이유를 설명한다. 위 질문은 하나의 생명주기를 연결하는 종합 평가 기준이며, 이미 통과한 장의 기초 개념을 별도로 다시 시험하지 않는다. 100개 인스턴스의 호스트 운영 분석과 자원 컨트롤러 설계·설정은 필수 종료 시험에서 제외한다.

## 선택 심화 또는 비목표

- `WriteThread`, `WriteGroup`, mutex, writer queue와 scheduler 내부 구현
- compaction picker와 모든 Compaction 옵션의 내부 동작
- lock table, deadlock detector, `WritePrepared`, `WriteUnprepared`의 내부 구현
- MANIFEST record encoding과 checksum 알고리즘 구현
- 모든 복구 옵션과 Backup Engine API·운영 절차의 숙련
- callback 구현과 다중 인스턴스의 공유 예산·공정성·자원 컨트롤러 설계·설정
- 모든 설정값과 benchmark 수치 암기
- Timestamp API와 Table 6의 상세
- on-disk format compatibility matrix와 migration tool 구현
- RocksDB가 담당하지 않는 Raft, consensus, 분산 트랜잭션 coordinator의 구현
- SuperVersion 클래스와 reference count 코드 암기
