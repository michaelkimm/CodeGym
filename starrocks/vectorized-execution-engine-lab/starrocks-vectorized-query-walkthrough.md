# StarRocks 벡터화 실행 엔진 학습 정리

이 문서는 다음 쿼리가 StarRocks에서 실행되는 큰 흐름을 따라가며 데이터베이스
벡터화의 핵심 개념을 정리한다.

```sql
SELECT channel_id, COUNT(*)
FROM user_chats
WHERE status = 'OPEN'
GROUP BY channel_id;
```

설명의 목적은 특정 실행 계획이나 함수 호출 순서를 외우는 것이 아니다. 다음 정신
모델을 연결하는 것이 목적이다.

```text
Columnar storage
→ Column/Chunk 기반 Scan
→ Column batch expression 평가
→ Chunk 기반 Operator 실행
→ 필요하면 columnar batch를 다른 BE로 전송
→ 최종 결과
```

> 이 실습 환경은 StarRocks 3.3.22를 사용한다. 실제 실행 계획, Operator 배치,
> predicate 위치와 Profile 이름은 버전, 통계, 데이터 분포와 클러스터 구성에 따라
> 달라질 수 있다.

참고한 글: [Deep Dive: How StarRocks Built a High-Performance Vectorized Engine](https://www.starrocks.io/blog/deep-dive-how-starrocks-built-a-high-performance-vectorized-engine/index.html)

## 1. 먼저 기억할 핵심

데이터베이스 벡터화는 행을 하나씩 Operator에 전달하는 대신 여러 행을 Column 형태의
batch로 묶어 계산하는 실행 모델이다.

```text
Row-at-a-time
row 1 → Filter → Aggregate
row 2 → Filter → Aggregate
row 3 → Filter → Aggregate

Vectorized execution
Chunk 1 → Filter → Aggregate
Chunk 2 → Filter → Aggregate
```

StarRocks에서는 길이가 같은 여러 `Column`을 `Chunk`로 묶는다.

```text
Chunk: 4 rows

chat_id    = [1,      2,        3,       4]
channel_id = [1,      1,        2,       3]
status     = [OPEN,   CLOSED,   OPEN,    SNOOZED]
```

같은 위치의 값들이 하나의 논리적 행을 구성한다. 따라서 행을 필터링할 때는 같은
selection mask를 필요한 모든 Column에 적용하여 위치 대응을 유지해야 한다.

```text
mask       = [1, 0, 1, 0]

chat_id    = [1, 3]
channel_id = [1, 2]
status     = [OPEN, OPEN]
```

`Column batch로 계산한다`와 `CPU SIMD를 사용한다`는 같은 뜻이 아니다.

```text
데이터베이스 벡터화
= Chunk와 Column을 중심으로 한 실행 모델

CPU SIMD
= 하나의 CPU 명령으로 여러 값을 계산하는 저수준 최적화
```

Column batch는 SIMD를 적용하기 좋은 구조를 제공하지만 실제 SIMD 사용 여부는 연산,
자료형, 컴파일 결과와 CPU 아키텍처에 따라 달라진다.

## 2. 예제 데이터와 결과

실습의 `tiny_user_chats.csv`에는 다음 12행이 있다.

| chat_id | channel_id | status |
|---:|---:|---|
| 1 | 1 | OPEN |
| 2 | 1 | CLOSED |
| 3 | 2 | OPEN |
| 4 | 3 | SNOOZED |
| 5 | 1 | OPEN |
| 6 | 2 | CLOSED |
| 7 | 3 | OPEN |
| 8 | 1 | OPEN |
| 9 | 2 | OPEN |
| 10 | 3 | CLOSED |
| 11 | 2 | OPEN |
| 12 | 3 | OPEN |

쿼리 결과는 다음과 같다. 쿼리에 `ORDER BY`가 없으므로 실제 출력 순서는 보장되지
않는다.

| channel_id | COUNT(*) |
|---:|---:|
| 1 | 3 |
| 2 | 3 |
| 3 | 2 |

아래에서는 설명을 위해 최대 Chunk 크기를 4행으로 가정한다. 실제 StarRocks의 Chunk
크기와 각 Operator가 출력하는 행 수는 실행 상황에 따라 달라질 수 있다.

## 3. 아키텍처 관점: FE가 계획하고 BE가 실행한다

### FE

FE는 SQL을 분석하고 최적화하여 실행 계획을 만든다.

```text
SQL parse/analyze
→ 필요한 Column과 predicate 파악
→ 논리/물리 실행 계획 생성
→ predicate pushdown, column pruning 등 결정
→ 분산 실행을 위한 plan fragment와 scan 범위 구성
→ BE에 실행 요청
```

FE는 partition이나 tablet 수준에서 제외할 대상을 결정할 수도 있다. 하지만 개별
Segment/Page의 Zone Map을 읽어 실제 Page를 건너뛰는 작업은 BE의 storage reader가
수행한다.

```text
FE: status = 'OPEN'을 Scan에서 적용할 수 있도록 계획
BE: 실제 index와 Zone Map을 확인하고 읽을 데이터 범위를 결정
```

### BE

BE는 전달받은 plan fragment를 실행한다.

```text
Storage Scan
→ Column/Chunk 생성
→ predicate 평가
→ Aggregate
→ 필요하면 Exchange
→ 최종 Aggregate/Result Sink
```

여러 BE가 참여하면 각 BE가 일부 데이터를 Scan하고 부분 집계할 수 있다. Coordinator는
분산 실행을 조정하고 결과가 클라이언트에 반환되도록 한다.

## 4. Operator와 Expression

Operator는 Chunk를 입력받아 쿼리의 한 단계를 수행한다.

```text
Scan Operator
Filter Operator
Project Operator
Aggregate Operator
Join Operator
Exchange Operator
```

Expression은 Operator 내부에서 하나 이상의 Column을 계산하여 결과 Column이나 Boolean
mask를 만든다.

```text
status = 'OPEN'
→ Boolean selection

amount * quantity
→ 새 결과 Column
```

핵심 관계는 다음과 같다.

```text
Operator 사이에서는 Chunk를 전달한다.
Operator 내부 Expression은 Column batch를 평가한다.
```

Operator가 쿼리 전체에서 한 번만 호출되는 것은 아니다. 하나의 Operator 인스턴스가
행마다 호출되는 대신 Chunk마다 반복해서 실행된다.

```text
10,000 rows, maximum Chunk size 4,096

Chunk 1: 4,096 rows
Chunk 2: 4,096 rows
Chunk 3: 1,808 rows
```

## 5. 이 쿼리의 실행 흐름

### 5.1 Column pruning: 필요한 열 결정

쿼리에서 논리적으로 필요한 사용자 Column은 두 개다.

```text
channel_id: SELECT와 GROUP BY에 필요
status: WHERE 평가에 필요
```

`chat_id`는 이 쿼리 결과와 조건에 직접 필요하지 않으므로 가능하면 읽지 않는다. 이를
Column pruning이라고 한다.

```text
Column pruning
= 실행 계획에서 불필요한 Column을 제외하고
  가능하면 해당 Column의 storage I/O와 decode를 피하는 최적화
```

Column pruning은 `column index를 조회한다`는 뜻이 아니다. Columnar storage가 각
Column을 독립적으로 읽을 수 있는 물리적 기반을 제공하고, optimizer와 reader가 필요한
Column만 요청한다. Snapshot 처리 등 엔진 내부 사유로 추가 Column을 읽을 가능성은
있다.

### 5.2 Storage pruning: 읽지 않을 데이터 영역 제외

BE의 storage reader는 조건에 따라 Zone Map, Bloom filter, Bitmap/Inverted index 등의
사용 가능성을 확인한다.

가령 어떤 Page의 `status` 범위상 `OPEN`이 존재할 수 없다고 판단할 수 있다면:

```text
Page metadata/index 확인
→ status = 'OPEN'을 만족할 수 없음
→ Page data를 읽거나 decode하지 않고 건너뜀
```

이 단계의 주된 이득은 비교 연산을 SIMD로 빠르게 하는 것이 아니라 비교할 데이터를
아예 읽지 않는 데 있다. 조건과 index 종류에 따라 Segment, Page 또는 row range
수준에서 제외할 수 있는 범위가 달라진다.

### 5.3 Scan: storage data를 인메모리 Chunk로 변환

건너뛰지 않은 data page를 읽고 압축 해제와 decode를 수행하여 `Column` 객체를 만든다.

첫 네 행을 읽은 Chunk를 단순화하면 다음과 같다.

```text
channel_id = [1,      1,       2,       3]
status     = [OPEN,   CLOSED,  OPEN,    SNOOZED]
```

Chunk는 Segment나 Page처럼 영구 저장되는 파일 형식이 아니다. BE 메모리에 존재하는
일시적인 실행 객체다.

```text
영구 저장 계층: Segment / Page / Index
실행 메모리 계층: Column / Chunk
```

### 5.4 Filter: predicate expression을 Column batch로 평가

`status = 'OPEN'` expression을 Column 전체에 평가한다.

```text
status = [OPEN, CLOSED, OPEN, SNOOZED]
              ↓ status = 'OPEN'
mask   = [1,    0,      1,    0]
```

같은 mask를 Chunk의 필요한 Column에 적용한다.

```text
before
channel_id = [1, 1, 2, 3]
status     = [O, C, O, S]

after
channel_id = [1, 2]
status     = [O, O]
```

Predicate가 Scan에 완전히 pushdown되면 별도의 Filter Operator가 없고 Scan 내부에서
동일한 Column predicate 평가가 일어날 수 있다. Pushdown되지 않았다면 Scan 위의
Filter Operator가 평가할 수 있다.

어느 위치에서 실행되더라도 단순한 연속 Column 비교라면 compiler auto-vectorization이나
SIMD를 적용할 가능성이 있다. 하지만 pushdown과 SIMD는 서로 다른 축이다.

```text
Predicate pushdown
= 조건을 어디에서 평가하는가

Vectorized execution
= 조건을 어떤 데이터 단위로 평가하는가

SIMD
= CPU가 반복 계산을 어떤 명령으로 수행하는가
```

Pushdown이 index/Zone Map과 결합하면 물리 I/O까지 줄일 수 있다. Page를 이미 읽은 뒤
평가하더라도 탈락한 행의 다른 Column 처리와 상위 Operator 전달 비용을 줄일 수 있다.

### 5.5 Aggregate: Hash Table로 group 상태 갱신

Aggregate Operator는 필터링된 `channel_id` Chunk를 받아 group별 COUNT 상태를
관리한다.

첫 번째 Chunk:

```text
selected channel_id = [1, 2]

Aggregate Hash Table
1 → count 1
2 → count 1
```

두 번째 Chunk:

```text
channel_id = [1, 2, 3, 1]
status     = [O, C, O, O]
mask       = [1, 0, 1, 1]
selected   = [1, 3, 1]

cumulative state
1 → count 3
2 → count 1
3 → count 1
```

세 번째 Chunk:

```text
channel_id = [2, 3, 2, 3]
status     = [O, C, O, O]
mask       = [1, 0, 1, 1]
selected   = [2, 2, 3]

final state
1 → count 3
2 → count 3
3 → count 2
```

Aggregate의 큰 흐름은 다음과 같다.

```text
channel_id Column
→ key의 hash 계산
→ Hash Table에서 group을 찾거나 생성
→ group의 COUNT 상태 갱신
```

고정 길이 key의 hash 계산 등 일부 루프는 batch/SIMD 최적화 가능성이 있다. 그러나
Hash Table lookup과 상태 갱신 전체를 단순 SIMD화하기는 어렵다.

```text
key마다 다른 Hash Table 위치 접근
→ data cache miss 가능

서로 다른 key가 같은 bucket에 도달
→ hash collision 처리 필요

같은 group이 한 batch에 여러 번 등장
→ 같은 count 상태에 대한 dependency 발생
```

`COUNT`나 `SUM`의 덧셈 자체보다 어느 group 상태를 찾아 안전하게 갱신할지가 어려운
부분이다. 그럼에도 Chunk 단위로 입력받고 hash 계산, prefetch, 자료구조 접근 등을 batch
처리에 맞게 구성할 수 있으므로 vectorized Aggregate Operator다. Vectorized Operator의
모든 내부 명령이 SIMD라는 뜻은 아니다.

### 5.6 Exchange와 최종 Aggregate

테이블은 여러 BE/Tablet에 분산될 수 있고, 같은 `channel_id`의 행이 서로 다른 BE에
있을 수 있다. 실제 plan이 요구한다면 각 BE에서 부분 집계한 뒤 같은 group key가 같은
목적지로 가도록 Exchange한다.

```text
BE 1 partial aggregate ┐
                       ├─ hash(channel_id)로 shuffle
BE 2 partial aggregate ┘
                                ↓
                     final aggregate/merge
```

네트워크에서는 C++ `Chunk` 객체 자체를 보낼 수 없으므로 columnar batch를 bytes로
직렬화한다.

```text
BE 1의 Chunk
→ batch serialize
→ Network
→ deserialize
→ BE 2의 Chunk
→ 다음 Operator가 Column batch 처리
```

Exchange나 다단계 Aggregate는 항상 존재하는 것이 아니라 분산 방식과 실제 실행 계획에
따라 등장한다.

## 6. 서로 다른 최적화를 구분하기

| 최적화 | 줄이거나 바꾸는 것 | 이 쿼리의 예 |
|---|---|---|
| Storage/index pruning | 읽을 데이터 영역 | `OPEN`이 불가능한 Page 건너뛰기 |
| Column pruning | 읽을 열 | `channel_id`, `status` 중심으로 읽기 |
| Predicate pushdown | 조건의 실행 위치와 상위로 보낼 행 | `status='OPEN'`을 Scan 가까이에서 평가 |
| Vectorized execution | 호출·처리 단위 | 행 대신 Chunk/Column batch 처리 |
| SIMD | CPU 명령당 처리할 값 수 | 여러 `status` 값 비교 |

이 최적화들은 경쟁 관계가 아니며 함께 적용할 수 있다.

```text
Column pruning
→ 필요한 열만 읽음

Predicate pushdown
→ 불필요한 행을 일찍 제거

Vectorized execution
→ 남은 값을 Chunk/Column batch로 계산

SIMD
→ 적합한 batch loop의 계산 명령 수를 줄임
```

## 7. End-to-end columnar layout

Columnar storage만 사용한다고 전체 엔진이 vectorized되는 것은 아니다.

```text
Storage Column
→ Row 객체로 변환
→ Row-at-a-time Operator
→ 다시 Column으로 변환
```

중간에 Row 방식으로 바뀌면 Column↔Row 변환, 객체 할당, Operator 호출, cache locality
저하 비용이 생긴다. StarRocks가 지향하는 큰 흐름은 다음과 같다.

```text
Disk의 columnar data
→ Memory의 Column/Chunk
→ Operator의 Column batch
→ Network의 serialized columnar batch
→ 다음 BE의 Column/Chunk
```

End-to-end columnar layout은 모든 내부 자료구조가 반드시 Chunk라는 뜻이 아니다. Join
Hash Table, Aggregate state, selection vector, index와 직렬화 bytes는 별도 구조다. 핵심은
쿼리의 행 데이터가 storage, memory, operator, network를 지날 때 불필요하게 Row 객체로
변환되지 않고 가능한 한 Column batch 형태를 유지하는 것이다.

## 8. Chunk, SIMD width와 tail

Chunk 크기와 SIMD register가 한 번에 처리하는 값의 수는 서로 다르다.

```text
Chunk 크기
= Operator가 한 번에 주고받는 행 수

SIMD width
= CPU 명령 하나가 한 번에 처리하는 값 수
```

가령 하나의 Column에 `int32` 값 1,811개가 있고 SIMD 명령 하나가 8개씩 처리한다고
단순화하면:

```text
SIMD main loop: 1,808 values = 8 × 226
tail: 3 values
```

마지막 3개는 scalar loop, 더 좁은 SIMD 명령 또는 masked SIMD로 처리할 수 있다. 이를
위해 8행짜리 작은 Chunk 226개를 새로 만드는 것은 아니다. 하나의 Column 내부 loop가
SIMD width만큼 전진한다.

## 9. Column buffer, Pool과 Spill

`Column` 객체는 실제 값들을 저장할 backing buffer를 가진다.

```text
Column
├─ type
├─ size
├─ capacity
└─ buffer → [value 0, value 1, ...]
```

Chunk마다 새 buffer를 할당하고 해제하면 allocator 비용과 메모리 압력이 커질 수 있다.
Column Pool은 사용이 끝난 buffer의 capacity를 유지하여 다음 Column에서 재사용한다.

```text
새로 할당 → 사용 → free → 다시 할당

대신

초기 할당 → 사용 → Pool 반환 → 재사용
```

여러 객체가 Column을 read-only로 공유할 수는 있다. 하지만 Pool에서 꺼내 buffer를
덮어쓰려면 기존 사용자가 없어야 한다. 그렇지 않으면 동시 접근의 data race 또는
수명이 끝나기 전 재활용으로 인한 데이터 오염이 발생할 수 있다.

메모리가 부족하여 Operator가 spill하면 Chunk의 내용이 임시 block/file에 직렬화될 수
있다.

```text
메모리 Chunk
→ serialize
→ spill bytes
→ 나중에 read/deserialize
→ 메모리 Chunk 복원
```

파일 속 bytes 자체가 살아 있는 `Chunk` 객체인 것은 아니다. Operator가 다시 계산하려면
Column과 Chunk로 복원해야 한다.

## 10. SIMD를 활성화하는 방법

SIMD 적용 방법은 높은 추상화부터 다음처럼 나눌 수 있다.

```text
Compiler auto-vectorization
Compiler hint/directive
Parallel programming API
SIMD wrapper library
SIMD intrinsic
Assembly
```

StarRocks 글에서 설명하는 기본 원칙은 compiler auto-vectorization과 hint를 우선하고,
자동 벡터화가 어려운 성능 중요 경로에서는 SIMD intrinsic을 사용하는 것이다. Assembly
직접 작성도 가능한 가장 낮은 수준의 선택지지만 모든 중요 경로를 Assembly로 강제한다는
뜻은 아니다.

Column이 연속적으로 배치되었다고 실제 SIMD 사용이 자동으로 보장되지는 않는다. 다음과
같은 방법으로 확인해야 한다.

```text
Compiler vectorization report
Assembly의 SIMD register/instruction 확인
perf, VTune 등의 성능 측정
```

## 11. CPU 관점에서 왜 빨라질 수 있는가

SIMD가 없어도 batch 실행은 이점을 가질 수 있다.

```text
Batch 처리
→ 행마다 반복하던 Operator/함수 진입 횟수 감소
→ 행별 control flow와 branch 부담 감소

Column 처리
→ 계산에 필요한 같은 타입의 값이 조밀하게 배치
→ cache line 활용과 spatial locality 개선

단순하고 반복적인 Column loop
→ compiler auto-vectorization과 SIMD 적용에 유리
```

실제 값 비교 횟수가 사라지는 것은 아니다. 4,096행 Chunk도 4,096개의 값을 검사한다.
다만 expression 평가 경로를 행마다 호출하지 않고 한 번의 batch loop로 수행한다.

CPU 시간은 다음처럼 단순화할 수 있다.

```text
CPU Time = Instruction Count × CPI × Clock Cycle Time
```

- `Instruction Count`: 실행한 CPU 명령 수
- `CPI`: 완료한 명령 하나당 평균 cycle 수. 메모리 대기 등의 시간도 반영된다.
- 현대 CPU는 여러 명령을 겹쳐 실행하므로 CPI가 1보다 작을 수도 있다.

SIMD가 명령 수를 줄여도 CPI가 크게 증가하면 전체 실행 시간은 늘어날 수 있다.

```text
Scalar:     10억 instructions × CPI 0.5 = 5억 cycles
Vectorized:  3억 instructions × CPI 2.0 = 6억 cycles
```

따라서 `SIMD를 사용했다` 또는 `Instruction Count가 낮다`만으로 더 빠르다고 단정할 수
없다.

### Pipeline과 branch prediction

한 CPU 코어는 한 instruction stream의 여러 명령 단계를 pipeline으로 겹쳐 처리한다.

```text
Cycle 1: I1 Fetch
Cycle 2: I1 Decode  | I2 Fetch
Cycle 3: I1 Execute | I2 Decode | I3 Fetch
```

이는 여러 코어가 여러 thread의 instruction stream을 실행하는 것과 다르다.

Conditional branch는 다음에 가져올 명령 주소를 조건에 따라 바꾼다. CPU는 pipeline을
멈추지 않기 위해 과거 branch 결과를 기반으로 `taken/not taken`을 예측한다. 예측이
틀리면 잘못 가져오고 실행한 명령을 폐기하고 pipeline을 다시 채워야 한다.

```text
거의 항상 같은 방향인 loop branch
→ 예측하기 쉬움

무작위에 가까운 행별 조건 branch
→ branch misprediction 가능성 증가
```

Boolean mask 기반의 branchless/SIMD 비교는 행별로 불규칙한 control flow를 줄일 수 있다.
다만 소스 코드의 `if`가 반드시 branch 명령이 되는 것은 아니며 compiler가 branchless
명령으로 바꿀 수도 있다.

### Top-Down의 네 분류

원문의 단순화된 CPU Top-Down 모델은 다음과 같다.

| 분류 | 의미 | 대표 사례 |
|---|---|---|
| Retiring | 올바른 명령 결과가 확정됨 | 유용하지만 너무 많은 scalar 명령 |
| Bad Speculation | 잘못 추측한 작업을 폐기 | Branch misprediction |
| Frontend Bound | 실행할 명령을 충분히 공급하지 못함 | Instruction cache miss, decode 병목 |
| Backend Bound | 명령 실행이나 데이터 공급이 막힘 | Data cache miss, memory bandwidth, dependency |

Retiring이 높다는 것 자체는 보통 CPU가 유용한 일을 잘 수행한다는 뜻이다. 다만 같은
계산을 위해 scalar 명령을 너무 많이 Retire한다면 SIMD로 Instruction Count를 줄일 수
있는지 살펴볼 수 있다.

### Columnar layout도 cache miss를 없애지는 않는다

Locality는 CPU가 한 번 가져온 cache line을 얼마나 알차게, 그리고 얼마나 자주 다시
사용하는지를 설명하는 관점이다.

- **Spatial locality(공간 지역성)**: 지금 읽은 메모리 주소의 **근처 주소**를 곧 읽는
  성질이다. 예를 들어 cache line이 64 byte이고 `int32`가 4 byte라면, 한 cache line에
  연속된 값 16개가 담긴다. Column을 순서대로 scan하면 가져온 16개를 차례로 계산에
  사용하므로 cache line을 낭비하지 않는다.
- **Temporal locality(시간 지역성)**: 방금 읽은 **같은 데이터나 주소**를 가까운 시간
  안에 다시 읽는 성질이다. 예를 들어 같은 group이 반복되어 Aggregate Hash Table의
  동일한 상태를 자주 갱신하면, 그 entry가 cache에 남아 있는 동안 빠르게 재사용할 수
  있다.

따라서 Columnar layout은 같은 타입의 값을 연속 배치하여 spatial locality를 개선한다.
그러나 locality가 항상 좋은 것은 아니다. Hash Table에서 서로 멀리 떨어진 bucket을
무작위로 조회하면 spatial locality가 낮다. 매우 큰 Column을 한 번만 훑거나 Hash
Table이 너무 커서 같은 entry를 다시 찾기 전에 cache에서 밀려나면 temporal locality도
낮다.

```text
int32 10억 개 Column ≈ 4GB
→ 전체를 CPU cache에 보관할 수 없음
→ 새로운 cache line을 계속 메모리에서 가져와야 함
```

이런 불규칙한 접근과 cache eviction은 Data cache miss를 만든다. SIMD로 한 번에 더
많은 값을 계산해 소비 속도를 높여도 메모리에서 읽어야 할 총 byte 수는 그대로다.
따라서 계산보다 데이터 공급이 따라오지 못하면서 메모리 대역폭이 새 병목이 될 수
있다.

```text
Compute-bound
→ SIMD 적용
→ 계산 명령 감소
→ Memory-bound로 병목 이동
```

## 12. Practical Optimization을 보는 관점

고성능 vectorized engine은 Chunk와 SIMD만 도입한다고 완성되지 않는다. 원문은 실제
최적화를 일곱 범주로 정리한다.

| 범주 | 핵심 예시 |
|---|---|
| High-performance libraries | Parallel HashMap, SIMD JSON 등 검증된 구현 활용 |
| Data structures and algorithms | Low-cardinality dictionary로 문자열 연산을 정수 연산으로 전환 |
| Adaptive optimization | 실행 중 selectivity를 측정해 효과적인 Join Runtime Filter만 선택 |
| SIMD optimization | 적합한 Operator와 Expression의 batch loop 가속 |
| Low-level C++ optimization | 복사 제거, capacity 예약, inline, loop 단순화 |
| Memory management | Column Pool, block 기반 할당과 재사용 |
| CPU cache optimization | 데이터 배치 개선, 검증된 경우에 한해 prefetch 적용 |

이 쿼리에는 Join이 없으므로 Join Runtime Filter가 등장하지 않는다. Runtime Filter는
Adaptive Optimization을 설명하기 위한 별도의 Join 사례다.

## 13. 최종 실행 흐름

이 쿼리를 데이터베이스 벡터화 관점에서 한 번에 정리하면 다음과 같다.

```text
1. FE
   SQL 분석과 최적화
   → 필요한 Column 결정
   → predicate pushdown과 분산 계획 수립

2. BE Scan
   Index/Zone Map으로 불필요한 데이터 영역 제외
   → 필요한 storage Column을 읽고 decode
   → 인메모리 Column/Chunk 생성

3. Predicate expression
   status Column을 batch 평가
   → [1, 0, ...] selection 생성
   → Chunk의 모든 필요한 Column에 동일하게 적용

4. Aggregate Operator
   channel_id key의 hash 계산
   → Hash Table에서 group 상태 조회/생성
   → COUNT 갱신

5. 필요한 경우 Exchange
   부분 집계 Chunk를 columnar batch로 serialize
   → 같은 group key가 같은 목적지로 가도록 전송
   → 다음 BE에서 Chunk로 복원하고 최종 집계

6. 결과 반환
   channel 1 → 3
   channel 2 → 3
   channel 3 → 2
```

마지막으로 유지할 핵심 문장은 다음과 같다.

> StarRocks의 데이터베이스 벡터화는 SIMD 명령 몇 개를 추가하는 것이 아니라,
> Column/Chunk 기반 batch 실행 모델을 storage, expression, operator와 network 경로에
> 걸쳐 유지하고 자료구조·메모리·cache까지 함께 최적화하는 체계적인 엔지니어링이다.
