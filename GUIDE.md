# 사용 가이드 (v4, 파이썬)

장비에 올릴 파일은 두 개뿐이다.

```
nsx-collector.py      메뉴와 모든 수집 기능
nsx-collector.conf    편집하는 파일 (직접 안 채워도 된다 → 2번 discover)
```

실행은 항상 이렇게 한다.

```
python3 nsx-collector.py            메뉴
python3 nsx-collector.py <동작>      메뉴 없이 그 동작만
python3 nsx-collector.py help       이 장비에서 무엇을 모으는지
```

> **`./nsx-collector.py` 로 직접 실행하지 말 것.** 보안 설정이 켜진 ESXi는
> `Operation not permitted` 로 거부한다. 항상 `python3` 를 앞에 붙인다.
> 파이썬 위치: ESXi `/bin/python3`(3.11), NSX Edge `/usr/bin/python3`(3.10).

---

## 0. 올리는 방법

**tgz 를 바이너리로 전송해서 장비에서 풀어야 한다.** 메신저나 윈도우 편집기를
거치면 줄바꿈이 깨져서(CR) 스크립트가 통째로 한 줄로 인식된다. 2026-09-11
현장 실패가 이것이었다.

```
scp nsx-collector-<버전>.tgz root@<장비>:/tmp/
ssh root@<장비>
cd /tmp && tar xzf nsx-collector-<버전>.tgz
```

| 장비 | 두는 곳 | 결과 기본 위치 |
|---|---|---|
| NSX Edge | `/root/nsxc` | `/var/dump/nsx-collect` |
| ESXi | `/tmp/nsxc` | `/tmp/nsx-collect` (약 250MB 램디스크 주의) |

---

## 1. 메뉴는 장비에 따라 다르게 나온다

스크립트가 스스로 장비를 판단해서(`uname -s` = VMkernel → ESXi,
`/opt/vmware/nsx-edge` 있으면 Edge) **그 장비에서 되는 것만** 보여 준다.

### NSX Edge 에서
```
+======================================================================+
|  NSX Collector 4.0   (python)                                        |
|  ISCPSR-49099   edge / mb-edge02   2026-09-12 06:54:44               |
+======================================================================+
|    SETUP                          COLLECT                            |
|      1  config                       5  start all                    |
|      2  discover (fill config)       6  status                        |
|      3  check - Active node?         w  watch                        |
|      4  rehearse (no capture)                                        |
|    ONE AT A TIME                  FINISH                             |
|      c  capture LB T1 service       7  stop        keep files        |
|      u  capture VPC T1 uplink       8  stop + delete files           |
|      t  state sample once           d  dry run (show only)           |
|      e  session sample once         9  help    q  quit               |
+======================================================================+
```

### ESXi 에서
```
|    ONE AT A TIME                  FINISH                             |
|      c  capture DFW pre             7  stop        keep files        |
|      u  capture DFW post            8  stop + delete files           |
|      t  state sample once           d  dry run (show only)           |
|      e  DFW sample once             9  help    q  quit               |
```

---

## 2. 메뉴 항목별 설명

| 번호 | 이름 | 무엇을 하나 | 장비를 바꾸나 |
|---|---|---|---|
| **1** | config | 지금 설정값과 **그 설정으로 만들어지는 필터식**을 보여 준다. 필터 문법 검사도 같이 한다 | 아니오 |
| **2** | discover | **장비에서 값을 찾아 설정을 채워 준다.** 아래 3장 참고. 마지막에 y/N 을 묻고, 쓰기 전 원본을 `.bak` 으로 백업한다 | 설정 파일만 |
| **3** | check | Edge: **어느 노드가 Active 인지**, 남은 span, 디스크, 필터. ESXi: VM ↔ DFW 필터 ↔ 스위치 포트 표 | 아니오 |
| **4** | rehearse | 캡처 없이 상태·세션을 **1회** 수집한다. 설정이 맞는지 확인용 | 파일만 생성 |
| **5** | start all | 캡처와 상태 수집을 **모두 백그라운드로** 시작한다. 캡처는 `CAP_SECS`, 수집은 `DURATION` 뒤 스스로 끝난다 | 캡처 시작 |
| **6** | status | 무엇이 돌고 있고 몇 초 남았는지, 결과 폴더에 무엇이 생겼는지 | 아니오 |
| **w** | watch | status 를 10초마다 새로 그린다. Ctrl+C 로 나온다 | 아니오 |
| **c / u** | 캡처 1개만 | Edge: LB T1 / VPC T1 업링크. ESXi: DFW pre / post. 한 개만 따로 뜰 때 | 캡처 시작 |
| **t / e** | 샘플 1회 | t = 상태(카운터), e = 세션(Edge 방화벽·LB / ESXi DFW) | 파일만 생성 |
| **7** | stop | **우리가 띄운 것만** 멈춘다. 파일은 남긴다. 끝나고 남은 것을 보고한다 | 멈춤 |
| **8** | stop + delete | 멈춘 뒤 **우리 폴더만** 지운다 | 멈춤 + 삭제 |
| **d** | dry run | 8번이 무엇을 멈추고 지울지 **보여만 준다.** 아무것도 바꾸지 않는다 | 아니오 |
| **9** | help | 이 장비에서 무엇을 모으는지, 동작 목록 | 아니오 |

---

## 3. 2번 discover — 설정 자동 채우기

값을 몰라도 된다. 장비에 물어서 목록을 보여 주고, 고르면 설정에 넣어 준다.

### NSX Edge 에서 묻는 순서
1. **로드밸런서 목록** (이름 + VIP 몇 개) → 하나 고른다
   - → `LB_UUID`, `T1_LB_SR_UUID`, `LIF_LBT1_SVC`(서비스 인터페이스), 그 SR 의 HA 상태 표시
2. **그 LB 의 가상 서버 목록** (이름, IP, 프로토콜/포트) → 하나 이상 고른다
   - → `VIP`, `SVC_PORT`, `PROTO`, `LB_POOL_UUIDS`
   - → 풀에서 `LB_SNAT_IP`(SNAT 주소)와 `NODE_PORT`(백엔드 포트)까지 찾아 넣는다
3. **다른 T1 서비스 라우터 목록** → LB 앞단(NAT 전 트래픽이 지나가는 곳)을 고른다
   - → `T1_VPC_SR_UUID`, `LIF_VPCT1_UPLINK`(업링크 인터페이스)
4. T0 서비스 라우터는 자동으로 `T0_SR_UUID` 에 넣는다

쓰는 명령은 전부 조회다: `get logical-routers`,
`get logical-router <uuid> interfaces`, `get load-balancers`,
`get load-balancer <uuid> virtual-servers`, `... pool <uuid>`,
`... pool <uuid> snat-pools`, `... high-availability status`.

### ESXi 에서
1. **이 호스트에서 DFW 필터를 가진 VM 목록** → 백엔드 VM 을 고른다(여러 개 가능)
   - → `WORKER_VMS`, 고른 VM 의 vNIC·필터 이름·스위치 포트를 표로 보여 준다
2. **Up 상태 업링크 NIC** → `UPLINK_NICS`

> 이름에 **공백이 들어간 VM** 은 목록에서 제외하고 이유를 알려 준다. 공백으로
> 구분하는 목록에 담을 수 없기 때문이다. 괄호가 들어간 이름
> (`SupervisorControlPlaneVM_(2)`)은 정상 처리한다.

마지막에 이렇게 보여 주고 `y` 를 눌러야 쓴다.
```
  * WORKER_VMS         web01 web02
  * UPLINK_NICS        vmnic0 vmnic1
   * = changed. Nothing else in the file is touched, comments stay.
   write this into nsx-collector.conf? [y/N]
```

---

## 4. 무엇을 잡을지 — 두 가지 방법

### (1) 자유 필터식 — 권장
```
FILTER="host 10.1.1.10 and (udp port 1812 or udp port 1813)"
FILTER="(host 10.1.1.10 or host 10.1.1.11) and not tcp port 22"
FILTER="net 10.1.1.0/28 and udp"
```
- tcpdump 문법 그대로 `and` / `or` / `not` / 괄호를 쓴다.
- **IP 앞의 `host` 는 빠뜨려도 된다.** 자동으로 붙인다. 그냥 두면 문법
  오류이고, `port 80 and 10.1.1.10` 처럼 쓰면 **오류 없이 0건**이 잡힌다.
- `and` 와 `or` 는 **우선순위가 같고 왼쪽부터** 읽는다.
  `a or b and c` = `(a or b) and c`. 괄호를 쓰는 게 안전하다.
- **시작 전에 문법을 검사**하고, 틀리면 캡처를 아예 시작하지 않는다.
- ESXi 에서도 파일이 늘어나지 않는다(vNIC·단계당 1개).

### (2) 값만 넣는 방법
`HOSTS` `PROTO` `PORTS` 와 구간별 값(`VIP` `SVC_PORT` `LB_SNAT_IP`
`NODE_PORT` …). 각각 비워도 되고 여러 개 넣어도 된다.
- 비운 조건은 빠진다. **전부 비우면 전부 잡는다.**
- ESXi 는 이 값들이 pktcap-uw 옵션이 되는데 pktcap-uw 에는 "또는"이 없어서
  **조합마다 파일이 하나씩** 생긴다. config 화면이 몇 개가 될지 미리 알려 준다.

---

## 5. 결과 파일

한 번의 수집 = 폴더 하나. 이름만 봐도 무엇인지 안다.

```
<OUT>/run-<장비>-<날짜>-<시각>/
   00-run-info.txt                    무엇을 어떤 필터로 받았는지 + 이름 설명
   pcap/10-edge-lbt1svc-<시각>.pcap0   Edge, LB T1 서비스 인터페이스
        11-edge-vpct1uplink-*.pcap0   Edge, VPC T1 업링크
        20-dfw-pre-<vm>-<nic>.pcap0   ESXi, 방화벽 전
        21-dfw-post-<vm>-<nic>.pcap0  ESXi, 방화벽 후
   state/   30~39 Edge 카운터    40~49 ESXi 카운터
   session/ 50~59 Edge 방화벽·LB  60~69 ESXi DFW 세션·규칙·통과/차단
```

가져올 때: `scp -r root@<장비>:<위 폴더> .`

**읽을 때 주의.** Edge 캡처 파일의 일부는 802.1Q 태그가 붙어 있다(주로 응답
방향). 파일을 읽으면서 조건을 걸면 태그 붙은 쪽이 조용히 빠진다.
```
tcpdump -nr <파일> '(host 10.1.1.10) or (vlan and (host 10.1.1.10))'
```
조건 없이 `tcpdump -nr <파일>` 로 보면 전부 나온다.

---

## 6. 개별 스크립트(동작)로 돌리기

메뉴와 똑같은 일을 명령 한 줄로 할 수 있다. 메뉴에서 `c`·`t` 같은 항목을
고르면 **화면에 그 명령을 먼저 찍어 주므로** 그대로 따라 쓰면 된다.

### 공통
```
python3 nsx-collector.py config              설정과 필터식 확인
python3 nsx-collector.py discover            설정 자동 채우기
python3 nsx-collector.py selftest            사전 점검 (종료코드 0=정상)
python3 nsx-collector.py check               Edge: Active 노드 / ESXi: VM 표
python3 nsx-collector.py rehearse            캡처 없이 1회 수집
python3 nsx-collector.py start               전부 백그라운드로 시작
python3 nsx-collector.py status              진행 상황
python3 nsx-collector.py watch 5             5초마다 새로 그리기
python3 nsx-collector.py stop                중지 (파일 보존)
python3 nsx-collector.py wipe                중지 + 우리 파일 삭제
python3 nsx-collector.py stop --dry-run      판단만 보여 주기
python3 nsx-collector.py wipe --dry-run      삭제 대상만 보여 주기
python3 nsx-collector.py help                이 장비에서 모으는 것
```

### NSX Edge 전용
```
python3 nsx-collector.py cap-lbt1 [초]        LB T1 서비스 인터페이스 캡처
python3 nsx-collector.py cap-vpct1 [초]       VPC T1 업링크 캡처
python3 nsx-collector.py stats-once           상태 1회
python3 nsx-collector.py stats-run            상태 반복 (DURATION 동안)
python3 nsx-collector.py sess-once            방화벽·LB 세션 1회
python3 nsx-collector.py sess-run             같은 것 반복
```

### ESXi 전용
```
python3 nsx-collector.py map                  VM ↔ DFW 필터 ↔ 포트 표
python3 nsx-collector.py cap-pre [초]         방화벽 전 캡처
python3 nsx-collector.py cap-post [초]        방화벽 후 캡처
python3 nsx-collector.py stats-once | stats-run
python3 nsx-collector.py dfw-once  | dfw-run
```

- 초를 생략하면 설정의 `CAP_SECS` 를 쓴다.
- **캡처는 2~3초 뒤 프롬프트가 돌아오고** 뒤에서 계속 돈다. `*-run` 은
  `DURATION` 동안 화면을 잡는다. 창을 닫아도 되게 하려면 앞에 `nohup`,
  뒤에 `> 로그 2>&1 &` 를 붙이거나 `start` 를 쓰면 된다.
- 따로 시작한 것들도 **이미 열려 있는 실행 폴더에 합쳐진다**(2시간 기준).

---

## 7. 운영 장비에서의 안전 (중지·삭제)

| 원칙 | 실제 동작 |
|---|---|
| 우리 것만 | 이 파일이 띄운 프로세스, 우리 폴더에 쓰는 프로세스만 신호를 보낸다. `killall` 은 파일 어디에도 없다 |
| 파일 보존 | 캡처에 SIGINT 를 먼저 보내 pcap 을 정상 종료시킨다. 15초·25초 뒤에야 단계를 올린다 |
| 남의 캡처 보존 | Edge span 세션은 **설정의 LIF 를 미러링할 때만** 반납한다. 남의 세션은 보고만 한다 |
| 삭제 제한 | `00-run-info.txt` 가 있는 폴더만, 수집기가 돌고 있으면 아예 삭제하지 않는다 |
| 미리보기 | `--dry-run` 은 모든 판단을 보여 주고 아무것도 바꾸지 않는다 |
| 확인 | 끝나면 남은 것을 출력하고, 남았으면 **종료 코드가 0 이 아니다** |

한쪽 Edge 에서 만든 span 세션은 **클러스터의 다른 Edge 에도 존재한다.** 두
노드 모두에서 `stop` 을 돌려야 한다(화면에도 안내가 나온다).

---

## 8. 잘 안 될 때

| 증상 | 원인과 조치 |
|---|---|
| `Operation not permitted` | `./nsx-collector.py` 로 실행함. `python3 nsx-collector.py` 로 |
| `config not found` | conf 가 py 옆에 없음. 같은 폴더에 두거나 `NSXC_CONF=/경로/nsx-collector.conf` |
| `REQUIRED setting is empty` | Edge: `LIF_*` 없음 / ESXi: `WORKER_VMS` 없음 → **2번 discover** |
| 캡처 파일이 0건 | Edge 라면 **Standby 노드**일 수 있다 → 3번 check. 아니면 그 시간대에 트래픽이 없었다 |
| `FILTER is not a valid pcap expression` | 화면에 파서 오류가 그대로 나온다. 괄호와 `host` 를 확인 |
| 파일이 너무 많다(ESXi) | 값만 넣는 방식은 조합마다 1개다. `FILTER` 로 바꾸면 vNIC·단계당 1개 |
| `/tmp` 가 찬다(ESXi) | 램디스크 약 250MB. `OUT="/vmfs/volumes/<데이터스토어>/nsx-collect"` 로 옮긴다 |
| 줄바꿈 깨짐 | 오류가 전부 `line 1` 이면 CR 문제. tgz 바이너리 전송 후 장비에서 압축 해제 |

---

## 9. 셸 버전 (예비)

`nsx-collector.sh` + 같은 `nsx-collector.conf` 로 **파이썬 없이도** 같은 일을
할 수 있다(POSIX sh). 파이썬이 막힌 장비나 최소 환경용 예비다.
동작 이름은 같고 실행만 `sh nsx-collector.sh <동작>` 이다. 다만 `discover`
(설정 자동 채우기)는 파이썬 버전에만 있다.
