# StarRocks Vectorized Execution Engine Lab

이 실습은 하나의 `WHERE status = 'OPEN' GROUP BY channel_id` 쿼리를 Row Python,
NumPy Chunk, StarRocks 3.3.22 순서로 따라간다. 속도 경쟁이 아니라 데이터 이동과
Operator 입출력을 이해하는 것이 목표다.

각 단계에서는 먼저 결과나 호출 횟수를 예상하고, 명령을 실행해 관찰한 다음, 안내된
코드만 읽는다. 뒤 단계의 내부 구현을 미리 모두 이해할 필요는 없다.

## 준비

- Python 3.12
- NumPy 2.4.4
- Docker Desktop 또는 Docker Engine + Compose v2
- `curl`

저장소 루트에서 실습 디렉터리로 이동하고 Python 환경을 만든다. 이후 명령은 모두 이
디렉터리에서 실행한다.

```bash
cd starrocks/vectorized-execution-engine-lab
python3.12 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
```

## 1. 먼저 결과를 예측한다

`data/tiny_user_chats.csv`를 읽고 아래 쿼리 결과를 실행 전에 적어 본다.

```sql
SELECT channel_id, COUNT(*) AS open_chat_count
FROM user_chats
WHERE status = 'OPEN'
GROUP BY channel_id
ORDER BY channel_id;
```

예상한 뒤 확인할 정답은 channel 1 → 3, channel 2 → 3, channel 3 → 2다. 이 결과는
뒤의 세 실행 방식이 같은 일을 하는지 판단하는 기준이다.

## 2. Row와 Chunk trace를 관찰한다

```bash
.venv/bin/python demo.py trace
```

Row trace에서는 입력 행마다 predicate가 한 번 호출된다. Chunk trace에서는 네 행의
`status` Column을 한 번에 비교해 Boolean mask를 만들고, 선택된 `channel_id`만
batch aggregation에 전달한다. 마지막 checkpoint는 다음과 같다.

즉 Row 방식은 Python predicate와 그에 따른 control-flow branching을 행마다 수행하는
반면, Chunk 방식은 한 batch에 대해 Boolean mask 하나를 만든 뒤 선택 결과를 다음 단계에
전달한다. 이 차이가 SIMD 사용이나 속도 향상을 보장하지는 않으며, 실제 결과는 데이터와
Python/실행 환경에 따라 측정해서 판단해야 한다.

```text
Result equality: True
Row stats: ExecutionStats(rows_examined=12, selected_rows=8, filter_calls=12, aggregate_calls=8, chunks_processed=0)
Vector stats: ExecutionStats(rows_examined=12, selected_rows=8, filter_calls=3, aggregate_calls=3, chunks_processed=3)
```

먼저 `demo.py`의 `Column`, `Chunk`, `run_row`, `run_vector`만 읽는다. `Column`은 같은
타입의 연속 배열이고, `Chunk`는 길이가 같은 Column들을 이름으로 묶는다. 나머지 CLI
코드는 실행 흐름을 이해한 뒤 읽는다.

## 3. 호출 횟수와 시간을 구분한다

```bash
.venv/bin/python demo.py benchmark
```

기본값은 seed `20260724`, 1,000,000행, Chunk 4,096행이다. `Result equality: True`인지
먼저 확인하고 Row filter calls와 Chunk filter calls를 비교한다. 시간은 현재 Python과
NumPy에서 나온 교육용 microbenchmark일 뿐 StarRocks 성능 예측값이 아니다. Python,
NumPy, CPU와 시스템 부하가 달라지면 시간과 두 방식의 상대적인 순서도 달라질 수 있다.

빠른 smoke run은 다음과 같다.

```bash
.venv/bin/python demo.py benchmark --rows 10000 --chunk-size 257
```

seed가 고정되어 있으므로 이 실행의 안정적인 checkpoint는 다음과 같다. 시간은
checkpoint에 포함하지 않는다.

```text
Rows: 10000
Chunk size: 257
Result equality: True
Rows examined: 10000
Selected rows: 2430
Row filter calls: 10000
Chunks processed: 39
Chunk filter calls: 39
```

연속 typed Column은 같은 타입의 값을 가까이 배치한다. CPU가 cache line으로 여러 값을
가져오고 NumPy 같은 구현이 한 명령 흐름으로 여러 값을 처리하기 쉬워지는 토대지만,
이 Python 측정만으로 StarRocks의 SIMD 사용 여부나 성능을 증명하지는 않는다.

## 4. 실제 StarRocks를 실행한다

컨테이너를 시작하고 작은 CSV를 적재한 뒤 같은 쿼리를 실행한다.

```bash
docker compose -f cluster/compose.yaml up -d
./cluster/load.sh tiny
docker compose -f cluster/compose.yaml exec -T starrocks \
  mysql -h127.0.0.1 -P9030 -uroot < cluster/query.sql
```

`load.sh`는 FE의 bootstrap 응답만 보지 않는다. SQL 연결이 되고 `SHOW BACKENDS`에서
Alive BE를 찾을 때까지 기다린 뒤 schema 생성과 Stream Load를 진행한다. 준비 상태를
수동으로 확인할 때는 다음 명령을 실행해 출력에서 `Alive: true`를 찾는다.

```bash
docker compose -f cluster/compose.yaml exec -T starrocks \
  mysql -h127.0.0.1 -P9030 -uroot -e "SHOW BACKENDS\G"
```

Stream Load가 성공하면 JSON의 `Status`가 `Success`, `NumberLoadedRows`가 `12`이고
마지막에 다음 줄이 보인다.

```text
Loaded 12 rows into vector_lab.user_chats
```

`query.sql`은 적재 행 수, `EXPLAIN VERBOSE`, 실제 결과, Profile ID를 차례로 출력한다.
SQL 결과의 안정적인 부분은 다음과 같으며 `profile_query_id`는 비어 있지 않은 UUID여야
한다.

```text
channel_id  open_chat_count
1           3
2           3
3           2
profile_query_id
<실행마다 달라지는 UUID>
```

`EXPLAIN VERBOSE`에서 `status = 'OPEN'` predicate가 Scan에 있는지 별도 Filter에
있는지 먼저 찾고, Aggregate node를 찾는다. optimizer 선택에 따라 predicate 위치와
plan node 번호는 달라질 수 있다.

`query.sql` 첫 결과인 `VERSION()`은 MySQL 프로토콜 호환을 나타내므로 `5.1.0`을
반환한다. 실제 StarRocks 빌드는 `CURRENT_VERSION()` 또는 FE/BE metadata로 확인한다.

```bash
docker compose -f cluster/compose.yaml exec -T starrocks \
  mysql -h127.0.0.1 -P9030 -uroot -e \
  "SELECT VERSION() AS mysql_compatibility, CURRENT_VERSION() AS starrocks_version"
```

이 실습 이미지에서는 `mysql_compatibility=5.1.0`,
`starrocks_version=3.3.22-753696f`가 나온다. 따라서 `VERSION()`만 보고 StarRocks가
5.1이라고 해석하면 안 된다.

## 5. 대용량 데이터로 Profile을 본다

기본 export는 같은 seed로 1,000,000행 CSV를 만든다.

```bash
.venv/bin/python demo.py export
./cluster/load.sh benchmark
docker compose -f cluster/compose.yaml exec -T starrocks \
  mysql -h127.0.0.1 -P9030 -uroot < cluster/query.sql
```

export는 각 행 끝을 명시적으로 LF(`\n`)로 쓴다. StarRocks 3.3.22의 기본 CSV Stream
Load에서는 CRLF의 마지막 `\r`가 `status` 값에 남아 predicate 결과를 망가뜨릴 수
있기 때문이다.

마지막 `profile_query_id`를 복사해 셸 변수에 넣고 Profile을 읽는다.

```bash
PROFILE_ID='<query_id>'
docker compose -f cluster/compose.yaml exec -T starrocks \
  mysql --raw -h127.0.0.1 -P9030 -uroot \
  -e "SELECT get_query_profile('$PROFILE_ID')\G"
```

Profile publication은 비동기일 수 있다. Query ID가 있지만 Profile이 아직 없으면 잠시
기다린 뒤 `get_query_profile`을 다시 실행한다.

또는 [StarRocks FE](http://localhost:8030)의 Queries 화면에서 같은 Query ID를 연다.

| Python 관찰값 | StarRocks Profile에서 볼 위치 |
|---|---|
| 입력 행 | 해당 Operator의 `PushRowNum` |
| 출력 행 | 같은 Operator의 `PullRowNum` |
| predicate 전 Scan 행 | Scan의 `RawRowsRead` |
| storage predicate 후 행 | Scan의 `RowsRead` |
| Python 함수/단계별 측정 시간(개념 비교) | 해당 Operator의 `OperatorTotalTime` |

서로 다른 Operator의 수치를 직접 등치하지 않는다. 특히 predicate가 Scan으로
pushdown되면 Python의 selected rows는 별도 Filter가 아니라 Scan의 출력과 더 가까울
수 있다. Scan 뒤의 Aggregate, Exchange 같은 Operator에 표시된 Push/Pull 행 수는 각
Operator 자신의 입출력이지 Scan의 다른 이름이 아니다. `OperatorTotalTime`도 Python
함수 시간과 같은 측정값이 아니라 대응하는 실행 단계의 시간이다. Profile은 Chunk 객체
자체나 Python 함수 호출 횟수가 아니라 Operator의 행 수와 시간을 보여준다.

검증에 사용한 10,000행 sample에서는 Python의 selected rows가 2,430이었고 Scan
Profile의 `RawRowsRead=10000`, `RowsRead=2430`, `PullRowNum=2430`을 관찰했다. 이는
이번 seed, 데이터 크기, 쿼리 plan의 관찰 예시일 뿐 모든 실행에서 나와야 하는
보편적인 수치가 아니다. 자신의 Profile에서는 먼저 Operator 이름을 확인한 뒤 그
Operator의 지표끼리 해석한다.

## 검증

Python 동작, readiness regression, shell 문법, Compose 구성을 각각 확인한다.

```bash
.venv/bin/python -m unittest -v test_demo.py
bash cluster/test_load.sh
bash -n cluster/load.sh cluster/test_load.sh
docker compose -f cluster/compose.yaml config --quiet
```

unit test는 고정 결과, 결정적 생성, 불완전 마지막 Chunk, 빈 selection, Column 길이,
CSV export와 LF line ending을 확인한다. readiness regression은 deadline, probe timeout,
timeout diagnostics를 확인한다. 네 명령 모두 exit code 0이어야 하며 현재 Python test
suite는 `Ran 9 tests`와 `OK`를 출력한다.

## 종료와 초기화

컨테이너만 내리면 named volume은 유지된다.

```bash
docker compose -f cluster/compose.yaml down
```

데이터까지 지우고 깨끗하게 다시 시작하려면 다음을 실행한다.

```bash
docker compose -f cluster/compose.yaml down --volumes
```

두 번째 명령은 FE metadata와 BE storage가 든 named volume도 삭제한다. 되돌릴 수
없으므로 실습 데이터를 버려도 될 때만 사용한다.

## 문제 해결

- NumPy import 실패: `.venv/bin/python -m pip install -r requirements.txt`
- BE 준비 상태 확인: 위의 `SHOW BACKENDS\G` 명령에서 `Alive: true`인지 확인. FE
  bootstrap 응답만으로는 BE 준비를 증명하지 못함
- FE 또는 BE 진단 로그: `docker compose -f cluster/compose.yaml logs starrocks`.
  로그는 원인 조사용이며 Alive의 증거는 `SHOW BACKENDS` 출력임
- benchmark CSV 없음: `.venv/bin/python demo.py export`
- 포트 충돌: 8030, 8040, 9030을 사용하는 로컬 프로세스를 종료한 뒤 다시 시작
- Stream Load 실패: `load.sh`가 출력한 JSON의 `Message`와 `ErrorURL` 확인. 마지막
  status가 예상과 다르면 CSV가 LF line ending인지도 확인
- Profile이 비어 있음: `query.sql`이 출력한 마지막 Query ID를 사용했는지, UUID의
  따옴표나 괄호를 함께 복사하지 않았는지 확인

## 확인 질문

1. Chunk는 Row 목록과 어떻게 다른가?
2. 같은 행 수를 조사해도 Operator 호출 횟수가 다른 이유는 무엇인가?
3. Boolean mask는 Filter와 Aggregate 사이에서 무엇을 전달하는가?
4. 연속 typed Column은 CPU cache와 SIMD에 왜 유리한가?
5. Python의 입출력 행 수는 Profile의 어느 Operator 지표와 연결되는가?
