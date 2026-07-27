# Vectorized Execution Engine Learning Lab Design

## 결정 배경

이 저장소의 최상위 분류는 학습 대상에 맞춘다. 이번 실습은 Python 문법보다
StarRocks의 벡터화 실행 엔진을 학습하는 것이 목적이므로 최상위 디렉터리는
`starrocks/`로 둔다.

실습은 같은 `Filter + GROUP BY` 쿼리를 세 단계로 따라간다.

1. Row-at-a-time Python 모델
2. NumPy Column/Chunk Python 모델
3. StarRocks v3.3.22의 실제 실행 계획과 Query Profile

Python과 StarRocks의 속도를 직접 비교하거나 StarRocks C++ 엔진을 재구현하지
않는다. Python 모델은 데이터가 Row 또는 Chunk로 이동하는 차이를 눈에 보이게
만드는 학습 도구다.

## 학습 완료 기준

학습자는 코드와 실행 결과를 근거로 다음을 설명할 수 있어야 한다.

- Row와 Column 메모리 배치의 차이
- 여러 Column이 같은 행 범위를 공유하는 Chunk 구조
- Operator가 Row 대신 Chunk를 입출력하는 방식
- Boolean mask가 Filter 결과를 표현하는 방식
- 선택된 값만 batch aggregation에 전달되는 과정
- 연속 typed memory와 batch 실행이 cache, branch, call overhead, SIMD에 유리한 이유
- Python 모델의 입출력 행과 호출 횟수를 StarRocks Profile에 연결하는 방법
- `PushRowNum`, `PullRowNum`, `RawRowsRead`, `RowsRead`, `OperatorTotalTime`의 범위

성공 조건은 특정 속도 배율이 아니다. Row와 Vector 결과가 같고, Chunk 방식의
호출 횟수가 Row 방식보다 작으며, 실제 Profile에서 대응 지표를 찾으면 완료다.

## 범위

포함한다.

- 설명용 12행 CSV
- seed가 고정된 기본 1,000,000행 데이터 생성
- Row와 Column/Chunk 방식의 동일한 Filter + GROUP BY
- Row별 predicate trace와 Chunk별 mask/부분 집계 trace
- 두 Python 실행 방식의 중앙 실행 시간과 호출 횟수
- StarRocks v3.3.22 all-in-one 학습 클러스터
- Primary Key Table, Stream Load, `EXPLAIN VERBOSE`, Query Profile
- Python 단위 검증, CLI smoke test, Compose 정적 검증, 실제 클러스터 검증

포함하지 않는다.

- SQL parser나 범용 expression/operator framework
- StarRocks storage engine, DelVector, Publish, page decoding 재구현
- 실제 StarRocks hash table과 pipeline driver 구현
- SIMD intrinsic 또는 assembly 분석
- Python과 StarRocks의 실행 시간 직접 비교
- 운영 클러스터 연결

## 파일 구조

```text
starrocks/
└── vectorized-execution-engine-lab/
    ├── README.md
    ├── demo.py
    ├── test_demo.py
    ├── requirements.txt
    ├── data/
    │   ├── .gitignore
    │   └── tiny_user_chats.csv
    └── cluster/
        ├── compose.yaml
        ├── load.sh
        ├── query.sql
        └── schema.sql
```

원래 설계의 중첩 `starrocks/` 디렉터리는 최상위 분류와 이름이 겹치므로
`cluster/`로 바꾼다. 모든 파일 경로는 현재 작업 디렉터리가 아니라 파일 자체의
위치를 기준으로 해석한다. 따라서 저장소 루트와 lab 디렉터리 양쪽에서 명령을
실행할 수 있다.

`data/benchmark_user_chats.csv`는 필요할 때 생성하며 커밋하지 않는다.

## 고정 환경

- Python 3.12
- NumPy 2.4.4
- random seed `20260724`
- 기본 데이터 수 `1_000_000`
- 기본 Chunk 크기 `4_096`
- StarRocks `starrocks/allin1-ubuntu:3.3.22`
- MySQL protocol `9030`, FE HTTP `8030`, BE HTTP `8040`

README는 Docker Desktop 또는 호환 Docker Engine, Compose v2, `curl`, Python
3.12를 사전 요구사항으로 안내한다. SQL client는 all-in-one 컨테이너 안의
client를 사용해 호스트 의존성을 줄인다.

## 데이터 계약

작은 CSV는 다음과 같다.

```csv
chat_id,channel_id,status
1,1,OPEN
2,1,CLOSED
3,2,OPEN
4,3,SNOOZED
5,1,OPEN
6,2,CLOSED
7,3,OPEN
8,1,OPEN
9,2,OPEN
10,3,CLOSED
11,2,OPEN
12,3,OPEN
```

논리 쿼리는 하나다.

```sql
SELECT channel_id, COUNT(*) AS open_chat_count
FROM user_chats
WHERE status = 'OPEN'
GROUP BY channel_id
ORDER BY channel_id;
```

기대 결과는 `{1: 3, 2: 3, 3: 2}`다.

대용량 데이터는 `numpy.random.default_rng(20260724)`로 생성한다.

- `chat_id`: 1부터 시작하는 연속 `int64`
- `channel_id`: 1부터 1000까지 균등 분포 `int32`
- `status`: `OPEN` 25%, `CLOSED` 60%, `SNOOZED` 15%인 `int8`
- 내부 상태값: `OPEN=0`, `CLOSED=1`, `SNOOZED=2`

같은 원본 NumPy 배열에서 Row 표현과 Column 표현을 만들고, 자료구조 준비 시간은
benchmark 측정에서 제외한다. CSV export 때만 상태값을 문자열로 복원한다.

## Python 모델 계약

`demo.py`는 다음 최소 자료구조를 제공한다.

```text
Column(name: str, values: numpy.ndarray)
Chunk(columns: dict[str, Column])
ExecutionStats(
    rows_examined,
    selected_rows,
    filter_calls,
    aggregate_calls,
    chunks_processed,
)
```

`Chunk`는 생성 시 모든 Column의 길이가 같은지 확인하고 `row_count`와 이름 기반
Column 접근을 제공한다.

핵심 함수 계약은 다음과 같다.

```text
load_tiny() -> Chunk
generate_chunk(rows: int) -> Chunk
to_rows(chunk: Chunk) -> list[tuple[int, int, int]]
run_row(rows, trace=False) -> tuple[dict[int, int], ExecutionStats]
run_vector(chunk, chunk_size, trace=False) -> tuple[dict[int, int], ExecutionStats]
```

Row 실행은 행마다 predicate를 평가한다. `filter_calls`는 입력 행 수와 같고,
`aggregate_calls`는 `OPEN` 행 수와 같다.

Vector 실행은 Chunk slice마다 `status == OPEN` mask를 만들고 선택된
`channel_id`에 `numpy.unique(..., return_counts=True)`를 적용한다.
`filter_calls`는 처리한 Chunk 수, `aggregate_calls`는 선택된 행이 하나 이상인
Chunk 수다. 빈 선택에는 집계 호출을 기록하지 않는다. 마지막 불완전 Chunk도
동일하게 처리한다.

## CLI 계약

```text
python demo.py trace
python demo.py benchmark [--rows N] [--chunk-size N]
python demo.py export [--rows N] [--output PATH]
```

`trace`는 하나의 명령에서 `ROW TRACE`와 `CHUNK TRACE`를 구분해 출력한다.
Chunk trace 크기는 4로 고정하며 상태값, mask, channel id, selected values,
누적 partial aggregation을 한 묶음으로 보여준다.

`benchmark`는 다음 규칙을 지킨다.

1. Row와 Column 표현을 측정 전에 만든다.
2. 각 실행 함수를 두 번 워밍업한다.
3. 다섯 라운드 동안 Row/Vector 순서를 번갈아 측정한다.
4. 각 timed call 동안 cyclic garbage collector를 끄고 원래 상태로 복원한다.
5. 두 결과가 다르면 시간 결과를 출력하지 않고 실패한다.
6. 중앙값과 Python/NumPy/CPU architecture/행 수/Chunk 크기를 출력한다.

`export`의 기본 출력은 `data/benchmark_user_chats.csv`다. 부모 디렉터리가 없는
사용자 지정 경로는 명시적 오류로 처리한다.

## StarRocks 클러스터와 적재

Compose는 1 FE + 1 BE가 포함된 공식 all-in-one 이미지를 사용한다. 데이터는
named volume에 보존하되 README에 일반 종료와 volume까지 지우는 초기화 명령을
모두 제공한다.

데이터베이스 이름은 `vector_lab`, 테이블은 `user_chats`다.

```sql
CREATE TABLE user_chats (
  chat_id BIGINT NOT NULL,
  channel_id INT NOT NULL,
  status VARCHAR(16) NOT NULL
)
PRIMARY KEY (chat_id)
DISTRIBUTED BY HASH(chat_id) BUCKETS 4
PROPERTIES ("replication_num" = "1");
```

`load.sh tiny|benchmark`는 다음 순서로 동작한다.

1. 인자와 대상 CSV를 검사한다.
2. 최대 120초 동안 FE readiness를 확인한다.
3. `schema.sql`을 실행하고 기존 테이블을 `TRUNCATE`한다.
4. CSV header를 한 줄 건너뛰는 strict Stream Load를 실행한다.
5. HTTP 응답 원문을 보존하면서 성공 상태와 적재 행 수를 검사한다.
6. SQL `COUNT(*)`로 최종 행 수를 다시 확인한다.

매번 `TRUNCATE`하므로 tiny와 benchmark의 겹치는 `chat_id`가 섞이지 않는다.
benchmark CSV가 없으면 정확한 export 명령을 출력하고 실패한다.

## 실행 계획과 Query Profile

`query.sql`은 다음 순서로 구성한다.

1. 현재 StarRocks 버전과 적재 행 수
2. `EXPLAIN VERBOSE`로 Scan predicate와 Aggregate 확인
3. `SET enable_profile = true`
4. 동일한 Filter + GROUP BY 쿼리 실행
5. `SELECT last_query_id()`로 Profile 대상 ID 확인

README는 FE Web UI `http://localhost:8030`의 Query 탭과 다음 SQL 경로를 모두
설명한다.

```sql
SELECT get_query_profile('<query_id>')\G
```

지표는 Operator 범위를 함께 명시한다.

- `PushRowNum`: 해당 Operator가 받은 누적 입력 행
- `PullRowNum`: 해당 Operator가 내보낸 누적 출력 행
- Scan `RawRowsRead`: predicate 적용 전 원본 행
- Scan `RowsRead`: storage predicate 적용 후 읽은 행
- `OperatorTotalTime`: 해당 Operator 실행에 사용된 시간

optimizer가 predicate를 Scan으로 pushdown할 수 있으므로 Python의 selected rows를
항상 특정 Filter Operator의 `PullRowNum`과 같다고 주장하지 않는다. 실행 계획에서
predicate 위치를 먼저 찾고 같은 Operator 범위의 지표만 비교한다.

## 오류 처리

- NumPy가 없으면 `python -m pip install -r requirements.txt`를 안내한다.
- CSV header, 정수 필드, 상태값이 잘못되면 파일과 행 번호를 출력한다.
- 행 수와 Chunk 크기는 양의 정수만 허용한다.
- Column 길이가 다르면 Chunk 생성을 즉시 거부한다.
- Row/Vector 결과가 다르면 양쪽 결과를 출력하고 실패한다.
- Docker/FE가 준비되지 않으면 확인 명령과 마지막 관찰 상태를 출력한다.
- Stream Load 실패 응답은 숨기지 않고 non-zero exit로 종료한다.

자동 복구 framework, logging dependency, 범용 retry library는 추가하지 않는다.
유일한 재시도는 제한 시간이 있는 FE readiness 검사다.

## 검증 전략

`test_demo.py`는 Python 표준 `unittest`만 사용해 다음을 자동 검증한다.

- tiny Row 결과가 `{1: 3, 2: 3, 3: 2}`인지
- tiny Vector 결과와 Row 결과가 같은지
- 같은 seed와 행 수가 같은 데이터를 만드는지
- Column 길이 불일치를 거부하는지
- 마지막 불완전 Chunk를 처리하는지
- 선택 행이 없을 때 빈 결과와 0 aggregate call을 반환하는지
- export CSV의 header, 행 수, 상태 문자열이 올바른지

항상 실행하는 검증은 다음과 같다.

```text
python -m unittest -v test_demo.py
python demo.py trace
python demo.py benchmark --rows 10000 --chunk-size 257
python demo.py export --rows 1000
bash -n cluster/load.sh
docker compose -f cluster/compose.yaml config
```

Docker 사용이 가능하면 추가로 다음을 실제 실행한다.

- 이미지 manifest에서 현재 architecture 지원 확인
- 컨테이너 readiness와 StarRocks 3.3.22 버전 확인
- tiny 12행 Stream Load와 기대 query 결과 확인
- benchmark CSV Stream Load와 행 수 확인
- `EXPLAIN VERBOSE`의 Scan predicate/Aggregate 확인
- Profile 생성과 핵심 지표 존재 확인

현재 머신에서 실행할 수 없는 다른 architecture는 실행 성공을 주장하지 않고
공식 multi-architecture manifest 존재만 확인한다.

## README 학습 순서

README는 정답을 먼저 설명하기보다 관찰 순서를 설계한다.

1. CSV와 SQL을 보고 결과를 직접 예측한다.
2. Row trace에서 행별 predicate와 호출 횟수를 센다.
3. Chunk trace에서 Column, mask, selection, partial aggregation을 찾는다.
4. `Column`, `Chunk`, `run_row`, `run_vector`만 먼저 읽는다.
5. benchmark에서 시간보다 호출 횟수 차이를 먼저 해석한다.
6. 실제 StarRocks에 같은 데이터를 적재하고 SQL 결과를 맞춘다.
7. `EXPLAIN VERBOSE`에서 predicate 위치와 Aggregate를 찾는다.
8. Query Profile에서 같은 Operator 범위의 행 수와 시간을 연결한다.
9. 다섯 개 확인 질문에 자신의 말로 답한다.

확인 질문은 다음과 같다.

1. Chunk는 Row 목록과 어떻게 다른가?
2. 같은 행 수를 조사해도 Operator 호출 횟수가 다른 이유는 무엇인가?
3. Boolean mask는 Filter와 Aggregate 사이에서 무엇을 전달하는가?
4. 연속 typed Column은 cache와 SIMD에 왜 유리한가?
5. Python의 입출력 행 수는 Profile의 어느 Operator 지표와 연결되는가?

## 코드 제약

- 핵심 학습 파일은 `demo.py` 하나로 유지한다.
- `demo.py`는 비주석·비공백 기준 220줄을 목표로 하고, 명확한 오류 처리와
  benchmark 규칙을 유지하기 위한 검토된 상한 260줄을 넘기지 않는다.
- 테스트는 학습 흐름을 가리지 않도록 `test_demo.py`로 분리한다.
- 추상화보다 데이터 이동 순서가 코드에서 직접 보이게 한다.
- Python 결과를 StarRocks 내부 성능 모델로 일반화하지 않는다.
- 생성된 대용량 파일은 Git 상태에 나타나지 않게 한다.
