# 분석기 사용 가이드 — nsx-analyzer.py (v6.2)

수집기(`nsx-collector.py`)는 **모으기만** 하고, 분석은 이 스크립트가 한다.

```
python3 nsx-analyzer.py             메뉴
python3 nsx-analyzer.py <동작>       메뉴 없이 그 동작만
python3 nsx-analyzer.py help        무엇을 알려 주는지
```

**어디서든 돌아간다.** 장비(Edge/ESXi)에서 그대로 돌려도 되고, 결과 폴더를
내 PC로 가져와 돌려도 된다. 표준 라이브러리만 쓰고, 읽기만 한다(보고서 파일을
쓸 때만 파일을 만든다).

```
scp -r root@<장비>:/var/dump/nsx-collect/run-mb-edge02-20260912-073308 .
python3 nsx-analyzer.py --run ./run-mb-edge02-20260912-073308
```

찾는 위치는 `--run` → `/var/dump/nsx-collect` → `/tmp/nsx-collect` → 현재
폴더 순서다. 여러 개면 목록에서 고른다(`l` 또는 `runs`).

---

## 메뉴

```
+======================================================================+
|  NSX Analyzer 6.2                                                    |
|  run: run-mb-edge02-20260912-073308                                  |
+======================================================================+
|    1  overview        what this run contains                         |
|    2  flow            find a flow (5-tuple) and explain it           |
|    3  state           counters, HA state, rising drops               |
|    4  session         firewall connections, LB, DFW                  |
|    5  report          all of it, saved to a file                     |
|    r  pick another run        9  help                                |
|    l  list runs               q  quit                                |
+======================================================================+
```

---

## 1. overview — 이 수집에 무엇이 들어 있나

- 수집 당시의 케이스·장비·**사용한 필터식**(00-run-info.txt 내용)
- pcap / state / session 파일 수와 크기
- **캡처 지점별 패킷 수와 시간 범위**, 그 지점이 무엇을 보는 곳인지 설명
- **명령이 거부되어 오류 메시지만 들어 있는 파일**이 있으면 따로 알려 준다
  (수집기가 NSX 버전에 없는 명령을 쓴 경우. v6에서 Edge 명령 4개를 고쳤다)

## 2. flow — 5튜플로 플로우 찾기

```
python3 nsx-analyzer.py flow --src 10.1.1.5 --dst 10.1.1.50 --dport 8080 --proto tcp
python3 nsx-analyzer.py flow --dst 42.15.249.86 --dport 1813 --proto udp
```
- 값은 전부 선택이고 **응답 방향도 함께** 찾는다.
- 정확한 5튜플로 못 찾으면 `host X and port Y` 방식으로 한 번 더 찾아 알려 준다
  (LB SNAT 처럼 임의 포트를 쓰는 경우).
- pcap 을 직접 해석한다 → **VLAN 태그 패킷이 빠지지 않고**, pktcap-uw 의
  pcapng 도 읽는다.

알려 주는 것:

| 구분 | 내용 |
|---|---|
| 지점별 | 건수·방향·바이트, 첫/마지막 시각, **관찰된 주소 조합(= NAT 지점)** |
| TCP | SYN/SYN-ACK/RST/FIN 수, 핸드셰이크 성공 여부와 RTT, 재전송, 제로 윈도우, 누가 끊었는지 |
| UDP | 요청/응답 수, 응답 시간 중앙값·최대, **30초 초과 시 방화벽 세션 만료 경고**, RADIUS 메시지 종류 |
| ICMP | unreachable 사유, MTU 문제 |
| 지점 비교 | 같은 vNIC 의 pre/post 를 비교해 **통과 / 일부 드롭 / 전량 드롭** 구분 |
| 끝 | 같은 것을 손으로 확인할 tcpdump 명령(Edge용 vlan 분기 포함) |

## 2-1. a — 여러 장비의 결과를 한 번에 (`--all-runs`)

한 건의 조사가 **실행 폴더 여러 개**가 되는 경우가 많다.

- VPC T1 과 LB T1 의 Active 가 **서로 다른 Edge** 인 경우 → Edge 마다 폴더 1개
- 백엔드 VM 이 여러 ESXi 호스트에 흩어져 있는 경우 → 호스트마다 폴더 1개

폴더들을 한 곳에 모아 놓고 이렇게 하면 전부 훑는다.

```
python3 nsx-analyzer.py flow --all-runs --dst 172.16.204.10 --dport 80 --proto tcp --run <모아둔폴더>
```

실측 예(Edge 2대):
```
2 run directory(ies): run-mb-edge01-..., run-mb-edge02-...
  RUN run-mb-edge01-...   NOT FOUND here (0 packet(s) in the file)
  RUN run-mb-edge02-...   292 packet(s) of this flow out of 965 in the file
```

## 3. state — 카운터가 그 시간 동안 어떻게 움직였나

- **라우터별 HA 상태를 샘플마다** 보여 주고, 중간에 바뀌면 `<-- CHANGED` 로 표시한다.
  캡처 도중 Active/Standby 가 바뀌면 "갑자기 끊겼다"의 답이 여기 있다.
- Edge 인터페이스(fp-eth*, eth*)와 논리 라우터 인터페이스의 RX/TX 증감
- ESXi 업링크 NIC, VM 스위치 포트 카운터 증감
- **오류·드롭 카운터는 따로 모아**, 그 시간 동안 늘어난 것만 "먼저 볼 것"으로 표시한다

## 4. session — 세션 테이블과 LB, DFW

**NSX Edge**
- 인터페이스별 방화벽 연결 수를 샘플마다 (`9d7af199 073311=45, 073355=33`)
- 연결 테이블 분석: 프로토콜·상태 분포, **SYN 상태(half-open) 경고**,
  그리고 **NAT 매핑**을 그대로 보여 준다
  `172.20.10.254:61496 -> 172.16.204.10:80 (as 172.20.31.110:80)`
- 로드밸런서: 샘플마다 상태와 **가상 서버·풀 업 개수**(다운이면 경고),
  L4/L7 현재·최대·누적 세션과 초당 세션 수
- 풀 멤버: 멤버별 IP·포트·상태와 헬스 모니터 상태

**ESXi**
- DFW **pass/drop 카운터(패킷 기준)** 와 그 시간 동안의 증감
  → 드롭이 늘면 경고하고, **왜 떨어졌는지**(icmp error, state-mismatch,
  seqno outside window 등)까지 보여 준다
- DFW 세션 표 건수 추이, 적용된 규칙 수와 drop/reject 규칙 수

연결 테이블과 DFW 세션 표는 **인터페이스·vNIC 마다 가장 최근 샘플을 전부**
읽는다(파일 하나만 보면 한쪽만 보인다 — 실측으로 잡은 문제다).

5튜플을 함께 주면 연결 테이블과 DFW 세션 표에서 그 플로우만 찾아 준다.
```
python3 nsx-analyzer.py session --dst 172.16.201.11 --dport 80 --proto tcp
```

## 5. report — 한꺼번에 파일로

```
python3 nsx-analyzer.py report 분석결과.txt
python3 nsx-analyzer.py report 분석결과.txt --dst 10.1.1.50 --dport 8080 --proto tcp
```
overview + state + session (+ 5튜플을 주면 flow 까지) 를 한 파일에 담는다.
메뉴 `5` 번은 실행 폴더 안에 `99-analysis-<시각>.txt` 로 저장한다.

---

## 수집기와의 관계

| 하는 일 | 스크립트 | 어디서 |
|---|---|---|
| 캡처·상태·세션 모으기 | `nsx-collector.py` | 조사 대상 장비(Edge/ESXi) |
| 모은 것 해석하기 | `nsx-analyzer.py` | 아무 데서나(장비, 내 PC) |

수집기에서 `analyze` 를 치면 분석기로 가라고 안내한다. 두 스크립트는 같은
폴더 구조(`run-<장비>-<날짜>-<시각>/`)만 공유하고, 서로를 부르지 않는다.

손으로 tcpdump 를 쓰는 방법은 **ANALYSIS.md**, 수집기 사용법은 **GUIDE.md**.
