# REFERENCE — 동작 원리와 실측 근거

여기 적힌 내용은 전부 랩(NSX Edge 4.2.4 / ESXi 8.0.3)에서 실제로 실행해
확인한 것이다. 문서에서 옮겨 적은 값은 없다.

---

## 1. 파일 구성

장비에 올릴 파일은 두 개뿐이다.

```
nsx-collector.py      메뉴와 모든 수집 기능 (v4, 기본)
nsx-collector.conf    편집하는 파일 — 같은 파일을 .py 와 .sh 가 함께 읽는다
nsx-collector.sh      같은 기능의 POSIX sh 예비본 (discover 는 없다)
```

**왜 파이썬인가.** 장비에서 값을 찾아오는 기능(discover)은 NSX CLI 출력과
`summarize-dvfilter` 를 파싱해야 한다. 셸로는 정확히 쓰기 어렵고, 두 장비에
이미 파이썬이 있다(ESXi 8.0.3 = 3.11, NSX 4.2 Edge = 3.10). 표준
라이브러리만 쓰므로 설치할 것은 없다. 파이썬은 CRLF 파일도 그대로 실행되므로
현장에서 겪은 줄바꿈 사고에도 강하다. 파이썬을 쓰기 어려운 장비를 위해 셸
예비본을 함께 둔다.

**설정 파일 파싱 규칙**(두 구현이 같은 파일을 읽기 위한 것):
따옴표로 감싼 값은 **닫는 따옴표에서 끝난다.** 그 뒤는 전부 주석이며, 주석
안에 따옴표가 있어도 값에 섞이지 않는다.
```
PROTO=""      # "udp" / "tcp", or several: "udp tcp"    -> 값은 빈 문자열
```
(이 처리를 빼먹어 PROTO 가 주석 전체로 읽히던 버그를 랩에서 잡았다.)

**값 목록과 이름 목록은 파서가 다르다.** IP·포트 같은 값은 공백·쉼표·괄호로
나누지만, VM·NIC **이름**은 공백으로만 나누고 괄호를 지우지 않는다. 랩에
`SupervisorControlPlaneVM_(2)` 같은 VM 이 있어서 필요했다. 이름에 공백이
들어간 VM 은 공백 구분 목록에 담을 수 없으므로 discover 가 목록에서 빼고
이유를 알려 준다.

스크립트가 스스로 어느 장비인지 판단한다.

| 확인 | 판정 |
|---|---|
| `uname -s` 가 `VMkernel` | ESXi |
| `/opt/vmware/nsx-edge` 존재 | NSX Edge |
| 둘 다 아님 | 실행 거부 |

수집기는 `python3 nsx-collector.py <동작>` 형태로 자기 자신을 다시 부르는 구조다.
나중에 "우리가 띄운 프로세스"를 찾을 때도 명령줄에 남은 이 동작 이름으로
식별한다.

**왜 파일 하나인가.** 2026-09-11 현장 실패는 코드 문제가 아니었다. 스크립트가
메신저를 거치며 줄바꿈이 CR로 바뀌었고, 파일 전체가 한 줄로 인식되어 모든
오류가 `line 1`로 찍혔다(라이브러리와 설정을 불러오는 줄까지). 파일을 하나로
줄이면 불러오기 실패가 없어지고 전달 사고도 줄어든다. 스크립트는 시작할 때
자기 자신과 설정 파일에 CR이 있는지 검사하고, 있으면 고치는 방법을 띄우고
멈춘다.

---

## 2. 필터

입구는 둘, 출구는 하나다. 어떤 방식으로 적든 결국 하나의 pcap 표현식이 되고,
캡처를 시작하기 전에 문법 검사를 거친다.

```
FILTER 값이 있으면  -> 그대로 사용 (주소 앞에 host/net 자동 보정)
FILTER 가 비어 있으면 -> HOSTS / PROTO / PORTS 와 구간별 값으로 조립
```

### 이 설계를 만든 실측 사실

* **`host` 없는 맨 IP는 문법 오류다.** `tcpdump '10.1.1.10 and udp'` 는 Edge
  tcpdump 4.99.1/libpcap 1.10.1, ESXi tcpdump-uw 4.99.4/libpcap 1.9.1, 맥
  모두에서 실패한다. 그래서 `bpf_fix()` 가 `host`(대역이면 `net`)를 붙인다.
* **더 위험한 경우가 있다.** `tcpdump 'tcp port 80 and 10.1.1.10'` 은 오류
  없이 통과하지만 아무것도 잡히지 않는다. 뒤의 주소가 앞의 `port` 한정자를
  물려받기 때문이다. 오류도 없고 파일도 비어 있어 창(window)을 통째로 날린다.
* **`and` 와 `or` 는 우선순위가 같고 왼쪽부터 읽는다.** `a or b and c` 는
  `(a or b) and c` 다. 괄호를 쓰는 편이 안전하다.
* **문법 검사 방법.** Edge 는 `tcpdump -d -i lo "<식>"` 으로 컴파일만 해 본다.
  ESXi 의 pktcap-uw 에는 BPF 자체가 없어서, 스크립트가 24바이트짜리 빈 pcap
  파일을 만들어 `tcpdump-uw -r <빈파일> -w /dev/null "<식>"` 로 검사한다.

### ESXi 의 두 가지 캡처 방식

| FILTER | 실행되는 것 | 파일 수 |
|---|---|---|
| 있음 | `pktcap-uw ... -o - \| tcpdump-uw -r - -w <파일> -C -W "<식>"` | vNIC·단계당 1개 |
| 없음 | `pktcap-uw` 의 `--udpport`/`--tcpport`/`--proto`/`--ip` 옵션 | 조합마다 1개 |

pktcap-uw 는 옵션을 "그리고"로만 묶고 "또는"이 없다. 그래서 단일 값 방식은
프로토콜 × 포트 × 주소 × vNIC × (pre+post) 로 곱해진다. 실측: 3 × 2 × VM 2대
× 2단계 = 동시 24개. 전부 정상 기동·자동 종료했지만 파일이 24개가 된다.
파이프 방식 실측: 28개 수집 → 식에 맞는 18개 저장, 어긋난 패킷 0개.

### Edge 의 캡처 방식 — span 미러 + tcpdump

```
set capture session <N> interface <LIF> direction dual   # admin CLI
  -> 리눅스 인터페이스 span-<N> 생성
tcpdump -nei span-<N> -Z root -C <MB> -W <n> -w <파일> <식>
del capture session <N>                                  # admin CLI
```

admin CLI 의 `start capture` 는 깔끔하게 멈출 수 없고 파일도 잃는다. 그래서
쓰지 않는다. `-Z root` 는 필수다. tcpdump 가 권한을 낮추면 링버퍼의 다음
파일을 만들지 못한다.

---

## 3. 시간과 종료

* **pktcap-uw 에는 시간 제한 옵션이 없다.** `-G <초>` 는 "출력 파일 회전
  주기"지 시간 제한이 아니다. `-G 3` 캡처가 2분 뒤에도 돌고 있었다.
* **게다가 `-G` 는 같은 파일 이름을 덮어쓴다.** 10초 동안 "Dumped 48
  packets" 인데 파일에는 마지막 20개만 남았다. `-W 5` 를 같이 줘도 같다.
  그래서 이 툴은 `-G` 를 아예 쓰지 않는다. 시간별로 나누려면 연속 캡처 후
  PC 에서 `editcap -i 60` 으로 자르는 편이 낫다.
* **종료는 `timeout -t <초> -s INT`.** ESXi busybox 1.29.3 은 옛 문법
  `-t SECS` 만 받는다(`timeout -s INT 4 ...` 는 "can't execute '4'"). 신형
  busybox 는 `timeout -s INT <초>` 다. 스크립트가 둘 다 시도해 되는 쪽을 쓴다.
* **시간 지정 캡처는 요청보다 약 2초 더 걸린다**(pktcap-uw 종료 시간). 그래서
  반복문으로 파일을 나누면 파일 사이에 그만큼 공백이 생긴다.
* `echo Y |` 는 pktcap-uw 가 묻는 확인에 답하는 것이다. 없으면 무인 실행이
  그대로 멈춰 선다.

---

## 4. 우리 프로세스 찾기

| 장비 | 방법 |
|---|---|
| Edge (리눅스) | `pgrep -f "<패턴>"`, 자기 자신과 부모 pid 제외 |
| ESXi (busybox) | `ps -c` 로 걸러 2번째 열(cartel id) 사용 |

**ESXi 의 `ps -c` 는 프로세스가 아니라 world(스레드) 단위로 출력한다.** 캡처
4개가 16줄로 보여서 네 배로 읽힌다. 2번째 열의 cartel id 가 프로세스이므로
그것으로 묶는다.

쓰는 패턴은 전부 "이름"이 아니라 "무엇을 쓰고 있는가" 기준이다.

```
nsx-collector.py <동작>                     우리 수집기
tcpdump   ... -w <OUT>/run-*/pcap/1*        Edge 캡처
pktcap-uw ... -o <OUT>/run-*/pcap/2*        ESXi 캡처(옵션 방식)
tcpdump-uw ... -w <OUT>/run-*/pcap/2*       ESXi 캡처(파이프 방식)
pktcap-uw ... --dvfilter <우리 VM 것>        ESXi 캡처(파이프 방식, 표준출력)
```

파일 어디에도 `killall` 은 없다.

---

## 5. 안전한 종료 — 운영 장비 기준

1. 신호를 보내기 **전에** 대상 프로세스를 명령줄과 함께 화면에 출력한다.
2. 캡처에는 먼저 `SIGINT` 를 보낸다(파일을 정상적으로 닫기 위해). 15초 뒤에도
   남아 있으면 `TERM`, 25초 뒤에도 남으면 `KILL` 이고, 대상은 1번에서 출력한
   pid 뿐이다.
3. **span 세션**: `get capture session <N>` 의 PORTS 에 이 설정의 LIF 가
   들어 있을 때만 반납한다. 비어 있으면 그냥 두고, 다른 인터페이스를 미러링
   중이면 "남의 것"으로 보고만 하고 절대 지우지 않는다. 랩에서 남의 세션을
   만들어 두고 실행해 그대로 살아남는 것을 확인했다.
4. 한쪽 Edge 에서 만든 span 세션은 클러스터의 **다른 Edge 에도 존재한다.**
   툴이 다른 노드에 접속할 수는 없으므로 화면으로 알린다.
5. **삭제**는 우리 표식(`00-run-info.txt`)이 있는 폴더만 지운다. `OUT` 이
   `/`, `/tmp`, `/var`, `/var/dump`, 빈 값이면 거부하고, 수집기가 하나라도
   돌고 있으면 아예 지우지 않는다.
6. `--dry-run` 은 위 판단을 전부 보여 주기만 하고 아무것도 바꾸지 않는다.
7. 우리 것이 하나라도 남아 있으면 종료 코드가 0이 아니다.

---

## 6. 용량

| 장비 | 기본 OUT | 랩 여유 | 하한(`MIN_FREE_MB`) |
|---|---|---|---|
| Edge | `/var/dump/nsx-collect` | 53 GB | 1024 MB |
| ESXi | `/tmp/nsx-collect` | 240 MB **램디스크** | 64 MB |

ESXi 의 `df` 는 경로 인자를 무시한다. 그래서 `df -m` 의 마운트 목록에서 가장
긴 접두사를 찾아 계산하고, 그래도 안 되면 `/tmp` 는 `vdf -h` 로 구한다.

캡처 전 조건: `CAP_FILESIZE × CAP_FILECOUNT × 캡처 수` 가
`(여유 - MIN_FREE_MB) / 2` 안에 들어와야 한다(pre·post 가 동시에 도므로 반).
ESXi 는 거부 대신 파일 크기를 자동으로 줄인다. 실측: 24개 × 20MB × 2 =
960MB 요청, 허용 87MB, 파일 크기 3MB 로 조정, 실제 파일은 750KB 이하.

상태 수집 루프도 매 회차 전에 같은 하한을 확인하고, 모자라면 스스로 멈춘다.

---

## 7. 장비별 함정

* **ESXi 에는 `id`, `whoami`, `tr` 이 없다.** root 확인은 `$USER` 로 대체하고
  문자 처리는 `sed`/`awk` 로 한다.
* **보안 설정이 켜진 ESXi 는 `./스크립트` 를 거부한다**(`Operation not
  permitted`, execInstalledOnly = VIB 로 설치된 파일만 직접 실행 허용).
  인터프리터를 통해 실행하면(`python3 스크립트`, `sh 스크립트`) 영향이 없다.
  이 툴킷의 모든 안내가 `python3` / `sh` 로 시작하는 이유다.
* **Edge 캡처 파일의 일부는 802.1Q 태그가 붙어 있다**(주로 되돌아가는 방향,
  실측 930개 중 367개). 캡처 시에는 커널이 태그를 떼고 필터를 적용하므로
  누락이 없다. 하지만 **파일을 읽을 때** 조건을 걸면 태그 붙은 쪽이 조용히
  빠진다. `tcpdump -nr <파일> '(<식>) or (vlan and (<식>))'` 로 읽어야 한다.
* **T1 서비스 라우터는 한쪽 Edge 에서만 Active 다.** Standby 에서 캡처하면
  0건이다. `get logical-router <uuid> high-availability status` 에서 위쪽
  `state` 가 이 노드이고, 아래 `Peer Routers` 블록은 상대편이다.
* **라우터별 CLI 는 느리다.** `interfaces stats` 1.6초,
  `high-availability status` 0.85초 — 라우터 1개당 약 2.5초. T1 이 100개인
  Edge 라면 `INTERVAL=30` 을 맞출 수 없다. 그래서 설정에 적은 라우터만 수집한다.
* **`--capture PreDVFilter --dvfilter <f>` 와 `--stage pre --dvfilter <f>`**
  는 같은 지점이다(`pktcap-uw -A` 목록 12번·13번). 시작 메시지가 각각
  "capture point is PreDVFilter", "The Stage is Pre" 로 다르게 찍힐 뿐이다.
  이 툴은 `--stage` 를 쓴다.

---

## 8. 설정 키

| 키 | 사용처 | 설명 |
|---|---|---|
| `CASE_ID`, `TAG` | 공통 | 화면과 파일 이름. TAG 비우면 호스트 이름 |
| `OUT` | 공통 | 비우면 Edge `/var/dump/nsx-collect`, ESXi `/tmp/nsx-collect` |
| `FILTER` | 공통 | 자유 pcap 표현식. 아래 단일 값들보다 우선한다 |
| `HOSTS`, `PROTO`, `PORTS` | 공통 | 여러 값 가능, 전부 선택 |
| `LIF_LBT1_SVC`, `LIF_VPCT1_UPLINK` | Edge | **필수**(둘 중 최소 1개) |
| `VIP`, `NAT_IP`, `CLIENT_IP`, `SVC_PORT` | Edge | LB 앞단 |
| `LB_SNAT_IP`, `NODE_PORT` | Edge·ESXi | LB 뒷단 |
| `T0_SR_UUID`, `T1_VPC_SR_UUID`, `T1_LB_SR_UUID` | Edge | 상태 수집용 |
| `LB_UUID`, `LB_POOL_UUIDS`, `FP_PORTS` | Edge | 상태 수집용 |
| `CAP_SESSION_VPCT1`, `CAP_SESSION_LBT1` | Edge | span 세션 번호(0~5) |
| `WORKER_VMS` | ESXi | **필수** |
| `WORKER_VNIC`, `UPLINK_NICS` | ESXi | 비우면 모든 vNIC / NIC 카운터 생략 |
| `CAP_SECS`, `CAP_SNAPLEN`, `CAP_FILESIZE`, `CAP_FILECOUNT` | 공통 | 캡처 |
| `INTERVAL`, `DURATION`, `MIN_FREE_MB` | 공통 | 상태 수집과 용량 하한 |

모든 값은 공백으로 구분해 여러 개를 넣을 수 있고, 채우지 않은 `<...>`
자리표시자는 빈 값으로 취급한다.

---

## 9. 결과 파일이 무엇인지

한 번의 수집은 한 폴더에 모인다: `<OUT>/run-<tag>-<날짜>-<시각>/`

| 파일 | 내용 |
|---|---|
| `00-run-info.txt` | 버전·호스트·케이스·사용한 필터·파일 이름 설명 |
| `pcap/10-edge-lbt1svc-*` | Edge, LB T1 서비스 인터페이스 캡처 |
| `pcap/11-edge-vpct1uplink-*` | Edge, VPC T1 업링크 캡처 |
| `pcap/20-dfw-pre-<vm>-<nic>*` | ESXi, 방화벽 적용 **전** |
| `pcap/21-dfw-post-<vm>-<nic>*` | ESXi, 방화벽 적용 **후** |
| `state/30~33-edge-*` | 인터페이스, 인터페이스 통계, 데이터플레인 CPU, fp 포트 |
| `state/34,35-edge-router-*` | 라우터별 인터페이스 통계와 HA 상태 |
| `state/36-edge-system-cpu-memory.txt` | `get system-stats` |
| `state/40-esxi-switchport-list.txt` | `net-stats -l` (우리 VM 만) |
| `state/41-esxi-uplink-*` | 업링크 NIC 카운터 |
| `state/42-esxi-vmport-*` | 스위치 포트별 카운터 |
| `session/50,51-edge-fw-*` | 방화벽 연결 수와 연결 테이블 |
| `session/52~55-edge-lb-*` | LB 상태·통계·가상서버·풀 |
| `session/60-dfw-filter-list.txt` | `summarize-dvfilter` (우리 VM 만) |
| `session/61-dfw-flows-*` | DFW 세션 표, 회차마다 1개 |
| `session/62-dfw-rules-*` | 그 vNIC 에 적용된 규칙 |
| `session/63-dfw-passdrop-*` | `getfilterstat` — v4 통과/차단 카운터 |
| `session/69-dfw-summary.txt` | 회차별 요약(세션 수, 통과/차단) |

이름 끝의 `-HHMMSS` 는 그 회차를 수집한 시각이다. ESXi 옵션 방식에서는
`-u1812` / `-t80` / `-icmp` / `-ip<주소>` 가 그 파일을 어떤 조건으로 잡았는지
알려 준다.

---

## 10. 수집 범위

`net-stats -l` 과 `summarize-dvfilter` 는 원래 호스트 전체를 출력한다. 그대로
담으면 남의 워크로드(다른 테넌트, vCenter, 로그 서버)까지 고객 SR 에 첨부되는
번들에 들어간다. 그래서 둘 다 `WORKER_VMS` 로 잘라낸다(랩 기준 181줄 → 25줄).
원본이 필요하면 `FULL_HOST=1` 로 켠다. 기본값은 언제나 꺼짐이다.


---

## 11. discover 가 읽는 것 (v4)

전부 조회 명령이고, 마지막에 사용자가 y 를 눌러야 설정 파일을 쓴다.
쓸 때는 주석을 그대로 두고 값만 바꾸며, 원본을 `nsx-collector.conf.bak` 으로
남긴다.

| 장비 | 실행하는 명령 | 채우는 키 |
|---|---|---|
| Edge | `get load-balancers` | `LB_UUID`, `T1_LB_SR_UUID` |
| Edge | `get logical-router <SR> interfaces` | `LIF_LBT1_SVC`(service), `LIF_VPCT1_UPLINK`(uplink) |
| Edge | `get load-balancer <LB> virtual-servers` | `VIP`, `SVC_PORT`, `PROTO`, `LB_POOL_UUIDS` |
| Edge | `get load-balancer <LB> pool <POOL>` | `NODE_PORT`(멤버 포트) |
| Edge | `get load-balancer <LB> pool <POOL> snat-pools` | `LB_SNAT_IP` |
| Edge | `get logical-routers` | `T0_SR_UUID`, T1 목록 |
| Edge | `get logical-router <SR> high-availability status` | 화면에 Active/Standby 표시 |
| ESXi | `summarize-dvfilter` | `WORKER_VMS` 후보(DFW 필터가 있는 VM) |
| ESXi | `net-stats -l` | 고른 VM 의 스위치 포트 표시 |
| ESXi | `esxcli network nic list` | `UPLINK_NICS`(Link Up 만) |

T0 SR UUID 는 **노드마다 다르다**(A/A 라 각 Edge 가 자기 SR 을 가진다).
edge01 에서 본 값을 edge02 에 쓰면 맞지 않는다 — 그래서 discover 는 실행한
장비에서 직접 읽는다.
