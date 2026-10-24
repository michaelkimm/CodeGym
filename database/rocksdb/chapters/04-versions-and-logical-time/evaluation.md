# 4. 버전과 논리적 시간 — 평가와 진행 승인

- 상태: `통과` — 추가 풀이를 생략하라는 학습자의 명시적 진행 승인에 따른 기록
- 평가일: `2026-10-24`
- 학습자 정리와 설명자 보완: [learner-notes.md](learner-notes.md)
- 원본: [Notion 정리](https://app.notion.com/p/40374b55ec7c80ec84e9f7ea8ffe8609)
- 이 문서는 설명자가 작성한 평가 기록이다. 학습자의 작성 내용, 설명자의 보완, 학습자의 진행 승인을 구분한다.

## 평가 범위와 전제

이번 과정은 “같은 키의 여러 버전 중 무엇이 보이는가?”를 중심으로 InternalKey·Sequence·ValueType, 읽기 경계와 Delete·Merge의 해석, 일반 Get·Snapshot Get·Iterator, SuperVersion의 물리 구조 참조, CF와 DB 인스턴스의 논리적 시간 경계를 다뤘다.

논문 §7.1과 공식 문서의 자연어 설명을 주 근거로 삼고, type 순서와 Seek 경계처럼 설명을 구체화할 때만 고정된 upstream 코드를 보조 근거로 사용했다. Sequence 예시는 앞선 2장에서 다룬 기본 WriteBatch·WriteCommitted 경로를 전제로 한다. 사용자 지정 timestamp와 특수 transaction 모드는 이번 범위가 아니다.

## 첫 정리에 대한 공개 기준별 판정

| 기준 | 판정 | 확인한 근거 |
|---|---|---|
| UserKey·InternalKey·Sequence·ValueType의 역할 | 충족 | 같은 사용자 키의 여러 버전을 sequence와 type으로 구별하고 Put·Delete·Merge에 대응하는 ValueType을 설명했다. |
| 읽기 경계에 따른 최신 버전 선택과 Delete 처리 | 충족 | 일반 Get은 경계 102에서 Bob, 103에서 NotFound를 반환하고 Snapshot 101의 Get은 계속 Alice를 반환한다는 표를 작성했다. |
| Merge operand와 최종 값의 구별 | 충족 | 덧셈 MergeOperator를 가정해 base 1000과 operand 1·10을 결합한 결과 1011을 설명했다. |
| 일반 Get·Snapshot Get·Iterator의 읽기 시점 | 충족 | 일반 Get의 published sequence와 명시적 Snapshot의 sequence, Iterator 생성 시점의 경계를 구별했다. 다만 I·J 예제의 반환값은 적지 않아 추가 확인 문제를 제시했다. |
| Snapshot과 SuperVersion의 역할 구별 | 충족 | SuperVersion으로 읽을 구조를 확보하고 read sequence로 보일 버전을 정한다는 설명과 mem·imm·current의 참조 구조를 작성했다. |
| 같은 DB의 CF와 서로 다른 DB의 경계 | 핵심 누락 | instance 안에서 sequence가 고유하다는 설명은 있지만 CF 간 공유 범위와 다른 DB에서 Snapshot을 사용할 수 있는지는 직접 설명하지 않았다. |

InternalKey 정렬에 대한 부연 중 “type DESC는 사실상 규칙을 위한 규칙에 불과하다”는 결론은 잘못 이해한 부분으로 지적했다. 최신 버전 우선 탐색의 주된 기준이 sequence라는 설명은 맞지만, 현재 구현의 Seek 경계 키에도 type 순서가 사용된다.

첫 평가 결과는 `보완 필요`였다. 인용문이나 설명자의 보완만을 학습자가 독립적으로 재구성한 증거로 취급하지 않았다.

## 추가 확인과 최종 진행 승인

설명자는 다음 세 문제를 제시했다.

1. 저장된 `(k, 100, Value=1)`을 검색 키 `(k, 100, type=0)`으로 Seek할 때 type DESC 순서가 어떤 영향을 주는가?
2. DB A의 두 CF가 공유하는 Sequence·Snapshot 경계와 별도 DB B의 경계는 어떻게 다른가?
3. A@301 → Snapshot S → B@302 → Iterator I 생성 → C@303 예제에서 I와 S를 사용하는 J의 경계·반환값은 무엇이고 Seek가 경계를 바꾸는가?

학습자는 세 문제의 개별 풀이를 제출하는 대신 다음과 같이 진행을 지시했다.

> 셋다 문제없어. 넘어가. 이거 PR 만들어서 머지 진행해

이를 추가 풀이 생략과 과정 종료에 대한 명시적 승인으로 반영했다. 이번 과정의 최종 상태는 `통과`로 기록하되, 모든 항목을 추가 답안으로 재검증한 통상 절차의 통과와는 근거가 다르다. 이 세 문제를 실제로 풀었다거나 CF 경계를 자기 언어로 다시 설명했다고 기록하지 않는다.

누락과 교정 내용은 저장소 정리의 “설명자 보완”에 명시했다. 학습자의 원본 Notion은 평가 당시 상태로 두었다. 이 승인은 이번 4장의 진행에 한정하며 공통 학습 절차나 전체 커리큘럼을 변경하지 않는다.

## 학습 중 구별한 경계와 보완

- 최신 버전을 먼저 찾는 기준인 sequence DESC와 검색용 InternalKey까지 포함한 type 순서를 구분했다. 원문의 “규칙을 위한 규칙”이라는 문장은 저장소 본문에서 설명자가 교정했다.
- 기본 WriteBatch의 연속된 변경은 서로 다른 연속 sequence를 받는다. Transaction의 시작 시점에 sequence 범위를 먼저 확보하고 더 큰 범위를 받은 쪽이 항상 이긴다는 모델로 이해하지 않는다. 충돌 제어의 본 학습은 5장이다.
- Snapshot은 논리적 읽기 경계이고, SuperVersion은 mem·imm·current Version을 참조하는 물리 구조 뷰다. current Version은 특정 CF의 SST 파일 구성 메타데이터다.
- Compaction 후에도 과거 Version을 참조하는 독자가 있으면 해당 SST 파일은 즉시 삭제되지 않는다. Snapshot이 논리적 과거 값을 보존하게 하는 조건과 특정 SST의 물리 수명은 구분하며, 제거 정확성의 본 학습은 6장이다.
- MergeOperator는 CF 단위로 제공하며 하나의 구현 안에서 key prefix에 따라 동작을 분기할 수 있다. 기존 값과 operand의 해석 의미를 보존해야 한다. 동작 중 새 CF에 operator를 제공하는 것과 기존 CF의 operator를 임의로 교체하는 것은 구분한다.

이 경계들은 세션에서 다룬 설명과 교정의 기록이다. 별도 확인 문제 답안이 없는 부분까지 독립적인 이해 검증이 끝났다는 뜻은 아니다.

## 이번 과정에 요구하지 않은 내용

- WriteThread·writer group 내부 구현과 특수 transaction 모드
- TransactionDB·OptimisticTransactionDB의 충돌 제어 상세
- Compaction picker·정책·버전 및 tombstone 제거의 정확성
- MergeOperator callback 구현과 런타임 교체 절차
- Iterator refresh API, user-defined timestamp, SuperVersion reference count 코드
- 재시작·WAL replay·checksum과 복구 절차

이번 세션은 4장만 종료했다. 5장의 학습과 평가는 시작하지 않았다.

## 근거

- [RocksDB 논문 (2021), §7.1](https://doi.org/10.1145/3483840)
- [Basic Operations — Snapshots](https://github.com/facebook/rocksdb/wiki/Basic-Operations#snapshots)
- [Snapshot](https://github.com/facebook/rocksdb/wiki/Snapshot)
- [Iterator — Consistent View](https://github.com/facebook/rocksdb/wiki/Iterator#consistent-view)
- [Column Families](https://github.com/facebook/rocksdb/wiki/Column-Families)
- [Merge Operator](https://github.com/facebook/rocksdb/wiki/Merge-Operator)
- [How we keep track of live SST files](https://github.com/facebook/rocksdb/wiki/How-we-keep-track-of-live-SST-files)

보조 구현 근거:

- [InternalKey와 ValueType](https://github.com/facebook/rocksdb/blob/c2b86f3ec0ca714e0f63872c3fc610c54ec1b301/db/dbformat.h#L26-L31)
- [Seek용 ValueType 선택](https://github.com/facebook/rocksdb/blob/ea313605367281013c2c81158069e88411516357/db/dbformat.cc#L22-L29)
- [SuperVersion·Snapshot과 물리 구조 수명](https://github.com/facebook/rocksdb/blob/553b52b4a709820fac1dbadc7796506740517582/docs/components/read_flow/03_superversion_and_snapshots.md)
