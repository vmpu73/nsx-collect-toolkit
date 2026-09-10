# 현장 실행 순서 (<CASE_ID>)

금요일 23:30 시작 → 토요일 03:00 종료 기준.
**따라만 하면 된다.** 값을 찾는 명령까지 다 적어 두었다.

---

## 메뉴로 하면 이것 하나만 기억하면 된다  ★ 처음이면 여기부터

```bash
[Edge] cd /root/urd && bash urd-edge.sh
[ESXi] cd /tmp/urd  && sh   urd-esxi.sh
```

```
+======================================================================+
|  URD  Collection Toolkit                                             |
|  <CASE_ID>   NSX Edge / <edge01>   2026-09-10 09:00:00           |
+======================================================================+
|                                                                      |
|    SETUP                        RUN                                  |
|      1  config                    4  start all                       |
|      2  check                     5  start one                       |
|      3  rehearse   (once)                                            |
|                                                                      |
|    MONITOR                      FINISH                               |
|      6  status                    7  stop            keep files      |
|      w  watch      (auto)         8  stop + delete   remove files    |
|                                                                      |
|      9  help                      q  quit                            |
|                                                                      |
+======================================================================+
   0 running    span 0    53G free
```

**ESXi는 `map` 이 하나 더 있어 번호가 한 칸씩 밀립니다** (map 2 · check 3 ·
rehearse 4 · start 5 · start one 6 · status 7 · stop 8 · wipe 9 · help h).

### 순서

| | Edge | ESXi | 무엇 |
|---|---|---|---|
| ① | 1 | 1 | conf 값 확인 (편집은 에디터로) |
| ② | 2 | 2 → 3 | ESXi는 map 먼저, Edge는 Active 확인 |
| ③ | 3 | 4 | `once` 리허설 — 설정이 맞는지 증명 |
| ④ | 8 | 9 | 리허설 결과 버리기 |
| ⑤ | 4 | 5 | 본 수집 시작 |
| ⑥ | 6 / w | 7 / w | 상태 확인, `w` 는 10초마다 자동 갱신 |
| ⑦ | 7 | 8 | 정지 (**파일 보존**) |
| ⑧ | | | 파일 회수 — 화면이 scp 명령을 찍어줍니다 |
| ⑨ | 8 | 9 | 회수 확인 후 삭제 |

### status 화면

```
+======================================================================+
|  COLLECTORS                                                          |
+======================================================================+
   LB T1 capture    [####----------------]  22%   running   3m53s left
   VPC T1 capture   [####----------------]  21%   running   3m55s left
   counters         [###-----------------]  15%   running   5m56s left
   sessions         [###-----------------]  15%   running   5m56s left

+======================================================================+
|  PRODUCED                                                            |
+======================================================================+
   stats-<edge-tag>/                             18 files     96.0 KB
   sessions-<edge-tag>/                          21 files    108.0 KB
   pcap/urd-<edge-tag>-lbt1-svc-162430.pcap0             4.0 MB
```

상태는 `running` / `finished` / `idle` 셋뿐입니다. **`finished` 는 돌고 끝난
것, `idle` 은 한 번도 안 돈 것**으로 구분됩니다.

`WARNINGS` 칸은 조치가 필요할 때만 내용이 찹니다 — 링버퍼 회전으로 창 앞부분이
날아갔거나, 디스크가 정지 기준에 근접했거나, 캡처가 없는데 span 이 남아 있는 경우.

### 화면에 명령어가 찍힙니다

무엇을 고르든 실행 직전에 실제 명령을 보여줍니다.

```
   $ nohup bash urd-edge-cap-lbt1-svc.sh  > /tmp/lbt1.log 2>&1 </dev/null &
```

운영 장비에서 뭐가 도는지 보이고, 나중에 메뉴 없이 손으로 돌릴 때 그대로 쓰면
됩니다. 스크립트로도 부를 수 있습니다:

```bash
bash urd-edge.sh config|check|rehearse|start|status|watch|stop|wipe|help
sh   urd-esxi.sh config|map|check|rehearse|start|status|watch|stop|wipe|help
```

**conf 편집은 메뉴에 없습니다.** 값이 틀어지면 수집 자체가 무의미해지므로
에디터로 직접 고칩니다. 메뉴 1번은 현재 값을 보여주기만 합니다.

### 화면 이식성

순수 ASCII(`+ = | # -`)에 **72칸 고정폭**입니다. UTF-8 박스문자와 색상은 쓰지
않습니다 — ESXi 콘솔에서 깨집니다. `tput` 이 ESXi에 없어 터미널 폭을 조회하지
않으며, 호스트명이 길어도 프레임이 깨지지 않게 잘라냅니다.
Edge(bash)와 ESXi(busybox sh) 양쪽에서 실제로 렌더 확인했습니다.

---

## 어느 파일을 실행하나  ★ 손으로 돌릴 때

| 파일 | 무엇 |
|---|---|
| `urd-edge.conf` / `urd-esxi.conf` | **편집만 한다.** 실행하지 않는다 |
| `urd-edge-lib.sh` / `urd-esxi-lib.sh` / `_cap-dfw.sh` | **부품.** 실행도 편집도 하지 않는다. 같은 디렉터리에 있기만 하면 된다 |
| 그 외 전부 | **이것만 실행한다** |

실행하는 것은 Edge 5개 · ESXi 5개다.

```
[Edge]  urd-edge-cap-vpct1-uplink.sh    VPC T1 uplink 캡처
        urd-edge-cap-lbt1-svc.sh        LB T1 service 캡처
        urd-edge-stats.sh               상태정보
        urd-edge-sessions.sh            세션/커넥션
        urd-edge-cleanup.sh             중단 / 뒷정리

[ESXi]  urd-esxi-cap-dfw-pre.sh         DFW pre 캡처
        urd-esxi-cap-dfw-post.sh        DFW post 캡처
        urd-esxi-stats.sh               상태정보
        urd-esxi-dfw-sessions.sh        DFW 커넥션 테이블
        urd-esxi-cleanup.sh             중단 / 뒷정리
```

`*-cleanup.sh` 는 **두 용도가 하나**다. 수집이 끝난 뒤 정리할 때도, 중간에
"아 잠깐 다시 할게요" 하고 **중단할 때도 같은 스크립트**를 쓴다. 차이는 `--all`
을 붙이느냐뿐이다 (아래 "중단하고 다시 시작하기" 참고).

> 실행 스크립트는 자기 옆의 `*-lib.sh` 와 `*.conf` 를 자동으로 읽는다.
> 그래서 **셋을 같은 폴더에 두는 것**만 지키면 된다.

---

## 0. 압축 풀기 (내 노트북에서)

두 가지 방법 중 아무거나.

**(A) 통째로 올려서 장비에서 푼다** — Edge·ESXi 모두 `tar` 가 있다.

```bash
scp urd-onbox.tgz root@<EDGE>:/root/
ssh root@<EDGE> "cd /root && tar xzf urd-onbox.tgz && cd onbox/edge && ls"

scp urd-onbox.tgz root@<ESXI>:/tmp/
ssh root@<ESXI> "cd /tmp && tar xzf urd-onbox.tgz && cd onbox/esxi && ls"
```

**(B) 로컬에서 풀고 파일만 보낸다**

```bash
tar xzf urd-onbox.tgz && cd onbox
scp edge/* root@<EDGE>:/root/urd/
scp esxi/* root@<ESXI>:/tmp/urd/
```

> 어느 쪽이든 **스크립트·conf 가 같은 디렉터리에 있으면** 된다.
> 스크립트가 자기 위치를 기준으로 `urd-edge-lib.sh` / `urd-esxi-lib.sh` 와 conf 를 찾는다.
> `onbox/edge/` · `onbox/esxi/` 안에서 그대로 실행해도 정상 동작한다 (랩 확인).

---

## 1. 어느 Edge 에 무엇이 있는지 먼저 확인

Edge 마다 붙어서(admin) 확인한다.

```bash
ssh admin@<EDGE-IP>
get logical-routers
```

출력에서 이 두 줄을 찾는다.

```
UUID                                  VRF LR-ID Name           Type
xxxxxxxx-....                          2   11   SR-<LB T1이름>   SERVICE_ROUTER_TIER1   ← LB T1
yyyyyyyy-....                          1    7   SR-<VPC T1이름>  SERVICE_ROUTER_TIER1   ← VPC T1
```

**둘이 다른 Edge 에 있을 수 있다.** 각각 어느 Edge 에 있는지 적어 둔다.

### ACTIVE 인지 반드시 확인

```bash
get logical-router <SR-UUID> high-availability status
```

**출력에 상태가 두 개 나온다. 위엣것만 봐야 한다.**

```
state                 : Active     ← ★ 지금 접속해 있는 이 노드 자신
mode                  : A/S
failover mode         : Non-preemptive
HA ports state
    UUID        : <서비스 LIF>
    op_state    : Up               ← Active 쪽만 Up (보조 지표)
Peer Routers
    Node UUID   : <상대 노드 UUID>
    HA state    : Standby          ← ✗ 이건 상대편 얘기다. 마지막 줄이라
                                     요약처럼 보이지만 아니다
```

아래 `Peer Routers` 블록을 읽고 Active/Standby 를 **정반대로 판단하기 쉽다**
(2026-09-09 랩에서 실제로 겪음). 확실히 하려면 셋 중 하나로 교차 확인한다:

1. 양쪽 Edge 에서 각각 돌려 `state` 가 서로 반대로 나오는지 본다
2. 서비스 LIF 의 `op_state` — Active 쪽만 `Up`
3. `Node UUID` 를 이름과 대조:
   `GET /api/v1/transport-nodes?node_types=EdgeNode` -> `node_id` / `display_name`

> `Standby` 면 **캡처가 0건**이다. Active 쪽 Edge 에서 돌려야 한다.
> 전역 `get high-availability status` 명령은 없다. **논리 라우터 단위**다.

---

## 2. Edge — 값 3개 찾기

### ① LIF UUID

```bash
get logical-router <SR-UUID> interfaces
```

`Port-type` 을 보고 고른다.

| 어느 Edge | 찾을 것 | conf 항목 |
|---|---|---|
| VPC T1 이 있는 Edge | `Port-type : uplink` (IP 가 100.64.x.x) | `LIF_VPCT1_UPLINK` |
| LB T1 이 있는 Edge | `Port-type : service` | `LIF_LBT1_SVC` |

```
Interface     : <LIF_LBT1_SVC_UUID>   ← 이 값
Name          : t1-...-svc-if-svclrp
Port-type     : service
IP/Mask       : 192.168.13.2/24
```

### ② LB UUID / Pool UUID  (LB T1 Edge 에서만)

```bash
get load-balancers
#   Display Name : <LB_NAME>
#   UUID         : <LB_UUID>          ← 이 값

get load-balancer <LB_UUID> pools status
#   UUID : <POOL_UUID>                ← 이 값 (<VIRTUAL_SERVER_NAME> 의 풀)
```

### ③ LB SNAT IP  ★ 캡처 필터의 핵심

```bash
get load-balancer <LB_UUID> pool <POOL_UUID> snat-pools
```

```
SNAT     : nat_..._1
Min Port : 4096      Max Port : 65535     Port Overload Factor : 32
Snat IP  : 192.168.13.2        ← 이 값을 LB_SNAT_IP 에 넣는다
```

> one-arm LB 면 보통 **T1 service 인터페이스 IP 와 같다.**
> SNAT 이 IP 풀이면 conf 에 `LB_SNAT_IP="net 192.168.13.0/28"` 처럼 대역으로 넣는다.

---

## 3. Edge — 파일 올리고 conf 편집

```bash
# 내 노트북에서
scp onbox/edge/* root@<EDGE-IP>:/root/urd/     # 디렉터리가 없으면 먼저 mkdir

ssh root@<EDGE-IP>
mkdir -p /root/urd    # (필요 시)
cd /root/urd
vi urd-edge.conf
```

**고칠 곳은 이것뿐이다.** 나머지(VIP·NAT·CLIENT·포트·노드명)는 이미 채워져 있다.

```bash
EDGE_TAG="edge01"            # 이 Edge 이름. 파일명에 들어간다. 아무 문자열

# VPC T1 이 있는 Edge 라면
LIF_VPCT1_UPLINK="yyyy-..."

# LB T1 이 있는 Edge 라면
LIF_LBT1_SVC="9d7af199-..."
LB_SNAT_IP="192.168.13.2"
LB_UUID="2d4b10d1-..."       # 세션 수집을 할 거면
LB_POOL_UUIDS="775cf60c-..."  # 세션 수집을 할 거면
```

> **이 Edge 에 없는 항목은 빈 값 그대로 둔다.** 스크립트가 알아서 건너뛴다.

---

## 4. Edge — 실행 (금요일 23:30)

### 먼저 `once` 로 리허설  ★ 90분 걸기 전에

`stats` 와 `sessions` 에는 **1회만 수집하고 끝나는 `once` 모드**가 있다.
conf 에 적은 UUID 가 맞는지, 명령이 먹는지 몇 초 만에 확인할 수 있다.
(ESXi 의 `map` 에 해당하는, Edge 쪽 사전 점검이다.)

```bash
cd /root/urd
bash urd-edge-stats.sh    once
bash urd-edge-sessions.sh once
ls -l /var/dump/urd/
```

무엇을 보나:

| 확인할 것 | 틀렸다면 |
|---|---|
| LB / Pool 통계가 값과 함께 찍히는가 | `LB_UUID` / `LB_POOL_UUIDS` 가 틀렸다 |
| 인터페이스 카운터가 나오는가 | `LIF_*` / `T*_SR_UUID` 가 틀렸다 |
| `not found`, `Invalid`, 빈 출력 | 그 항목의 conf 값을 다시 찾는다 |

여기서 값이 제대로 나와야 본 수집을 건다. 캡처 스크립트는 초를 주면 짧게 돌 수 있다:

```bash
bash urd-edge-cap-lbt1-svc.sh 30      # 30초만 떠보고 파일이 생기는지 확인
ls -l /var/dump/urd/pcap/
rm -f /var/dump/urd/pcap/*            # 리허설 파일은 지우고 본 수집 시작
```

### 본 수집

```bash
cd /root/urd

# VPC T1 이 있는 Edge 에서
nohup bash urd-edge-cap-vpct1-uplink.sh > cap-vpct1.log 2>&1 &

# LB T1 이 있는 Edge 에서
nohup bash urd-edge-cap-lbt1-svc.sh > cap-lbt1.log 2>&1 &

# 두 Edge 모두에서 (상태·세션)
nohup bash urd-edge-stats.sh run    > stats.log 2>&1 &
nohup bash urd-edge-sessions.sh run > sess.log  2>&1 &
```

기본값: 캡처 90분(`CAP_SECS=5400`), 상태·세션 3시간 30분(`DURATION=12600`).
창을 바꾸려면 conf 를 고치거나 `bash urd-edge-cap-lbt1-svc.sh 7200` 처럼 초를 준다.

### 5분 뒤 잘 돌고 있는지 확인

```bash
jobs                             # 띄운 개수만큼 Running 이어야 한다
tail -20 cap-lbt1.log            # 필터와 파일 경로가 찍혀 있어야 한다
ip -br link | grep span          # span-0 / span-1 이 보여야 한다
ls -l /var/dump/urd/pcap/        # 파일이 커지고 있어야 한다
df -h /var/dump                  # 여유 확인
```

### `nohup` 과 `&` 는 각각 뭘 하나 (랩 실측 결과 포함)

- `&`      = 백그라운드로 돌린다. 프롬프트가 바로 돌아와서 다음 명령을 칠 수 있다.
             4개를 동시에 돌리려면 필수다.
- `nohup`  = "no hangup". 접속이 끊길 때 오는 **HUP 신호를 무시**하게 만든다.

**<edge01>(NSX 4.2.4) 과 <esxi02> 에서 실측한 결과 (2026-09-09):**

| 상황 | `&` 만 | `nohup ... &` |
|---|---|---|
| 접속 유지 | 계속 돈다 | 계속 돈다 |
| `exit` 로 정상 로그아웃 | **계속 돈다** | 계속 돈다 |
| 창 닫기 / VPN 끊김 (세션 강제종료) | **계속 돈다** | 계속 돈다 |

이 장비들의 bash 는 `huponexit` 가 `off` 라 로그아웃해도 백그라운드 작업에
HUP 을 보내지 않는다. ESXi(busybox) 도 같았다. 즉 **`nohup` 이 없어도 죽지 않는다.**

그래도 이 문서가 `nohup` 을 붙여 쓰는 이유: 고객 장비의 셸 설정까지는 확인할 수
없고, 붙여서 손해가 없다. **90분짜리 캡처를 걸어놓고 세션이 끊기는 상황**이므로
보험으로 붙인다. 출력은 이미 `> 파일 2>&1` 로 돌리고 있어 `nohup.out` 도 안 생긴다.

### 노트북에서 ssh 한 줄로 던질 때만 — `</dev/null` 필요

Edge 에 **접속해서 프롬프트에서 치는 경우엔 해당 없다.** 아래처럼 원격에서
한 줄로 던질 때만 문제가 된다:

```bash
ssh root@edge 'nohup bash urd-edge-cap-lbt1-svc.sh > /tmp/lbt1.log 2>&1 &'
```

ssh 는 "명령이 끝나면" 이 아니라 **"통로가 닫히면"** 돌아온다. 백그라운드로 넘어간
tcpdump 가 ssh 의 입력(stdin)을 계속 물고 있어서, 명령은 끝났는데 ssh 가 캡처
시간만큼 대기한다. 그러면 그 다음 ssh 명령이 시작을 못 해 **캡처들이 직렬로 돈다**
(랩에서 4개가 60초씩 순차 실행돼 부하와 안 겹친 적 있음). 입력까지 돌려주면 된다:

```bash
ssh root@edge 'nohup bash urd-edge-cap-lbt1-svc.sh > /tmp/lbt1.log 2>&1 </dev/null &'
```

---

## 5. ESXi — 값 2개 찾고 실행

```bash
# 내 노트북에서
scp onbox/esxi/* root@<ESXI-IP>:/tmp/urd/

ssh root@<ESXI-IP>
mkdir -p /tmp/urd    # (필요 시)
cd /tmp/urd

# 업링크 NIC 확인 (Link status 가 Up 인 것)
esxcli network nic list

vi urd-esxi.conf
#   HOST_TAG="esx01"
#   UPLINK_NICS="vmnic0 vmnic1"
```

### 워커 노드가 이 호스트에 있는지 먼저 확인

```bash
sh urd-esxi-dfw-sessions.sh map
```

```
VM                                     vNIC   DFW filter                       port
<WORKER_VM_1>        eth0   nic-2104709-eth0-vmware-sfw.2    67108900
<WORKER_VM_2>        (not on this host)
```

- **vNIC 이 여러 줄** 나오면 그 VM 은 vNIC 이 여러 개다. 전부 캡처된다(권장).
  하나만 뜨고 싶을 때만 conf 의 `WORKER_VNIC` 을 쓴다.
- **`(not on this host)`** -> 그 VM 은 다른 호스트에 있다. 그 호스트에서도 같은 절차를 밟는다.
- **`(here, but no vNIC matches '...'; has: ethN)`** -> VM 은 여기 있는데 `WORKER_VNIC`
  값이 안 맞아서 걸러진 것이다. 비우거나 `has:` 에 나온 이름으로 고친다.

캡처를 걸기 전에 **반드시 이 map 을 먼저 돌려** 대상이 다 나오는지 확인한다.

### `once` 로 리허설 (map 다음, 본 수집 전)

ESXi 쪽도 `once` 모드가 있다. `map` 이 "대상이 있느냐"를 본다면
`once` 는 "명령이 실제로 값을 뱉느냐"를 본다.

```bash
sh urd-esxi-stats.sh        once
sh urd-esxi-dfw-sessions.sh once
ls -l /tmp/urd-out/
```

`vsipioctl getflows / getrules / getfilterstat` 결과가 채워져 있어야 한다.
캡처도 짧게 한 번 떠본다:

```bash
sh urd-esxi-cap-dfw-pre.sh 30
sleep 35; ls -l /tmp/urd-out/
rm -f /tmp/urd-out/*.pcap*            # 리허설 파일은 지운다
```

### 본 수집

```bash
nohup sh urd-esxi-cap-dfw-pre.sh  > /tmp/pre.log  2>&1 &
nohup sh urd-esxi-cap-dfw-post.sh > /tmp/post.log 2>&1 &
nohup sh urd-esxi-stats.sh run        > /tmp/stats.log 2>&1 &
nohup sh urd-esxi-dfw-sessions.sh run > /tmp/dfw.log   2>&1 &
```

`nohup` / `&` 의 의미는 위 **4장**의 설명과 같다. ESXi(busybox) 도 실측 결과가 동일해
`nohup` 없이도 죽지 않지만, 같은 이유로 붙여 쓴다.

확인:
```bash
ls -l /tmp/urd-out/
df -h /tmp                       # ESXi /tmp 는 램디스크다. 최대 256MB
```

> `/tmp` 가 램디스크라 용량이 작다. `CAP_SECS` 를 길게 잡거나 트래픽이 많으면
> conf 의 `OUT` 을 데이터스토어로 바꾼다: `OUT="/vmfs/volumes/<datastore>/urd-out"`

---

## 5-0. 수집 범위는 conf 가 정한다  ★ 운영 환경에서 중요

**이건 트러블슈팅 도구지 환경 전수조사 도구가 아니다.** conf 에 적은 대상만
수집한다. 비워두면 그 항목을 건너뛰고 안내를 찍을 뿐, **절대 "전체"로 대체하지
않는다.**

| 무엇 | 범위를 정하는 값 | 비우면 |
|---|---|---|
| Edge 논리 라우터 통계 (A3/A5) | `T0_SR_UUID` `T1_VPC_SR_UUID` `T1_LB_SR_UUID` | 수집 안 함 + 안내 |
| Edge LIF 드롭 카운터 (A4) | `LIF_*` 4개 | 해당 항목만 건너뜀 |
| Edge 캡처 | `LIF_VPCT1_UPLINK` / `LIF_LBT1_SVC` | 실행 거부 |
| ESXi 전부 (캡처·플로우·포트통계) | `WORKER_VMS` | 수집 안 함 + 안내 |
| ESXi vNIC 선택 | `WORKER_VNIC` | 그 VM의 모든 vNIC |

### 왜 이렇게까지 하나 — 실측 근거

**Edge: 논리 라우터 하나당 약 2.5초.**

| 명령 | 실측 |
|---|---|
| `get logical-router <uuid> interfaces stats` | 1,633 ms |
| `get logical-router <uuid> high-availability status` | 847 ms |

운영 Edge 는 T1 을 수백 개 물고 있다. 100개를 쓸면 샘플 1회에 250초라
`INTERVAL=30` 은 지켜질 수가 없고 컨트롤 플레인을 몇 시간 두들기게 된다.
그래서 conf 에 적힌 라우터만 조회한다. 랩 실측: 3개 지정 21초 / 1개 지정 17초.

**ESXi: 속도가 아니라 범위가 문제.**
`net-stats -l` 과 `summarize-dvfilter` 는 **호스트의 모든 VM** 을 뱉는다.
랩 호스트 실측 — 전원 켜진 VM 14대 중 **11대가 이 건과 무관**
(`mb-vcsa`, `mb-vrli`, `db01`, Avi SE …). 그대로 두면 **고객 SR 에 첨부되는
번들에 관계없는 워크로드 목록이 통째로 들어간다.** 그래서 `WORKER_VMS` 로
잘라낸다. 랩 실측: `A1-dvfilter-list.txt` **181줄 -> 25줄**.

### 정말 전체가 필요하면 (명시적 옵트인)

```bash
SR_AUTO=1   bash urd-edge-stats.sh once        # Edge: 이 Edge 의 SR 전부
                                               #   그래도 SR_MAX(기본 10) 넘으면 거부
FULL_HOST=1 sh urd-esxi-dfw-sessions.sh once   # ESXi: 호스트 전체 덤프
```

기본값으로는 절대 일어나지 않는다.

---

## 5-1. 파일이 어디에 떨어지나  ★ 실측 기준

`OUT` 은 conf 에서 정한다. 기본값은 Edge `/var/dump/urd`, ESXi `/tmp/urd-out`.
`<TAG>` 는 conf 의 `EDGE_TAG` / `HOST_TAG` 다.

### Edge — `/var/dump/urd/`

| 경로 | 내용 | 만드는 스크립트 |
|---|---|---|
| `pcap/urd-<TAG>-lbt1-svc-<HHMMSS>.pcap0..4` | LB T1 service 캡처 | `urd-edge-cap-lbt1-svc.sh` |
| `pcap/urd-<TAG>-vpct1-uplink-<HHMMSS>.pcap0..4` | VPC T1 uplink 캡처 | `urd-edge-cap-vpct1-uplink.sh` |
| `stats-<TAG>/A1-interface.txt` | 인터페이스 카운터 | `urd-edge-stats.sh` |
| `stats-<TAG>/A2-physport-<fp-ethN>.txt` | 물리 포트 통계 | 〃 |
| `stats-<TAG>/A3-lr-<SR>-ifstats.txt` | 논리 라우터 인터페이스 통계 | 〃 |
| `stats-<TAG>/A4-fwstats-<지점>.txt` | 방화벽 통계 | 〃 |
| `stats-<TAG>/A5-lr-<SR>-ha.txt` | HA 상태 | 〃 |
| `stats-<TAG>/B1-cpu.txt` `B2-cpu-verbose.txt` | DPDK 코어 사용률 | 〃 |
| `stats-<TAG>/C2-dp-memory.txt` `D1-throughput.txt` `E1-flowcache.txt` | 메모리·처리량·플로우캐시 | 〃 |
| `sessions-<TAG>/A1-conncount-<지점>.txt` | 커넥션 수 추이 | `urd-edge-sessions.sh` |
| `sessions-<TAG>/A2-conn-<지점>-<HHMMSS>.txt` | 커넥션 테이블 스냅샷 | 〃 |
| `sessions-<TAG>/B1-l4-*.txt` `B2-l7-*.txt` | LB L4/L7 세션 | 〃 |
| `sessions-<TAG>/C1-pools-stats.txt` ~ `C6-poolstat-<POOL>.txt` | 풀 통계·상태·헬스체크·SNAT·퍼시스턴스 | 〃 |
| `sessions-<TAG>/D1-diagnosis.txt` `E1-l4-summary.txt` | 요약 | 〃 |

랩 실측: `once` 1회 실행에 **38개 파일**.

### ESXi — `/tmp/urd-out/`

| 경로 | 내용 | 만드는 스크립트 |
|---|---|---|
| `urd-<TAG>-dfw-pre-<VM>-<vNIC>.pcap0..4` | DFW **적용 전** 캡처 | `urd-esxi-cap-dfw-pre.sh` |
| `urd-<TAG>-dfw-post-<VM>-<vNIC>.pcap0..4` | DFW **적용 후** 캡처 | `urd-esxi-cap-dfw-post.sh` |
| `stats-<TAG>/A0-niclist.txt` `A1-nic-<vmnicN>.txt` | 업링크 NIC 통계 | `urd-esxi-stats.sh` |
| `stats-<TAG>/A2-portlist.txt` `A3-port-<VM>-<vNIC>.txt` | 스위치 포트 통계 | 〃 |
| `dfw-<TAG>/A0-mapping.txt` `A1-dvfilter-list.txt` | VM↔필터 매핑 | `urd-esxi-dfw-sessions.sh` |
| `dfw-<TAG>/B1-flows-<VM>-<vNIC>-<HHMMSS>.txt` | 전체 플로우 | 〃 |
| `dfw-<TAG>/B2-flows-<proto>-<VM>-<vNIC>-<HHMMSS>.txt` | 해당 프로토콜만 | 〃 |
| `dfw-<TAG>/C1-rules-<VM>-<vNIC>.txt` | 적용 규칙 | 〃 |
| `dfw-<TAG>/D1-filterstat-<VM>-<vNIC>.txt` | pass/drop 카운터 | 〃 |
| `dfw-<TAG>/F1-summary.txt` | 요약 | 〃 |

랩 실측(VM 2대 기준): 40초 만에 **25개 파일**.

> pcap 은 `.pcap0` 부터 시작해 링버퍼로 `.pcap1`, `.pcap2` … 로 늘어난다.
> **`.pcap0` 하나뿐이면 회전이 안 일어난 것 = 창 전체가 온전히 들어있다.**
> 3개 이상이면 앞부분이 덮여 사라졌을 가능성이 있다.

---

## 5-2. 중단하고 다시 시작하기  ★ "아 잠깐, 3분 뒤에 다시 할게요"

수집 도중에 설정을 잘못 넣은 걸 발견했을 때. **각 장비에서 한 줄이면 된다.**

```bash
# Edge (모든 Edge 에서)
bash /root/urd/urd-edge-cleanup.sh --all

# ESXi (수집한 모든 호스트에서)
sh /tmp/urd/urd-esxi-cleanup.sh --all
```

`--all` 은 **중간까지 받은 파일도 버린다.** 다시 시작할 거니까 섞이면 안 된다.
파일을 남기고 프로세스만 멈추려면 `--all` 을 뺀다.

랩 실측 소요시간: **Edge 약 20초 · ESXi 약 10초.** 끝나면 그대로 conf 를 고치고
다시 띄우면 된다.

무엇을 멈추는가:

| | 멈추는 것 |
|---|---|
| Edge | 우리 tcpdump, span 세션(우리 id만), `urd-edge-stats.sh`/`-sessions.sh`/캡처 스크립트 |
| ESXi | 우리 pktcap-uw, `urd-esxi-stats.sh`, `urd-esxi-dfw-sessions.sh` |

> **왜 한 번에 안 죽을 때가 있나:** 폴링 루프가 `sleep INTERVAL` 안에 있으면
> SIGTERM 이 그 sleep 이 끝날 때까지(최대 30초) 대기한다. 그래서 스크립트가
> TERM 을 보낸 뒤 3초 기다렸다가 안 죽었으면 KILL 을 보낸다. 실측으로 확인함.

### 안전장치 — 이 스크립트가 남의 것을 건드리지 않는 근거

운영 장비에서 도는 정리 스크립트다. 다음이 코드에 박혀 있고 **랩에서 미끼를
띄워 검증했다** (2026-09-09).

| 위험 | 어떻게 막았나 | 검증 결과 |
|---|---|---|
| 남의 캡처를 죽임 | `tcpdump` / `pktcap-uw` 라는 이름이 아니라 **출력 경로가 `$OUT` 안인 것만** 죽인다. 절대 `pkill tcpdump` 를 하지 않는다 | 다른 경로에 쓰던 tcpdump·pktcap-uw 를 띄워두고 실행 → **살아남음**. "N other process(es) ... NOT touched" 로 알려준다 |
| 남의 span 세션을 끊음 | conf 의 `CAP_SESSION_*` **두 개만** 해제한다. 0~7 전체는 `--all-sessions` 를 명시해야 한다 | 기본 실행에서 우리 id 만 해제됨 |
| 지우면 안 되는 파일 삭제 | `$OUT` 을 통째로 `rm -rf` 하지 않는다. **우리 하위 경로만** 지우고, `$OUT` 은 비었을 때만 `rmdir` | `$OUT` 안에 남의 파일을 두고 실행 → **남고**, `$OUT` 도 안 지워짐 |
| conf 를 잘못 고쳐 `OUT` 이 이상해짐 | 실행 전 경로 검증: 절대경로 아님 / `..` 포함 / 2단계 미만 / 이름에 `urd` 없음 → **즉시 거부** | `/`, `/var`, `/var/log`, `relative/path`, `/var/dump/../..` 전부 거부 확인 |
| 실수로 지움 | `--all` 없이는 **아무 파일도 안 지운다**. `--dry-run` 으로 미리 볼 수 있다 | dry-run 후 프로세스·파일 전부 그대로 |

```bash
# 겁나면 먼저 이걸로 본다 - 아무것도 안 건드린다
bash /root/urd/urd-edge-cleanup.sh --all --dry-run
sh   /tmp/urd/urd-esxi-cleanup.sh --all --dry-run
```

---

## 6. 토요일 03:00 — 회수

캡처는 시간이 되면 **스스로 끝난다.** 남은 건 파일을 가져오는 것뿐이다.

### Edge

```bash
# 내 노트북에서
scp root@<EDGE-IP>:/var/dump/urd/pcap/*.pcap* ./수집/
scp -r root@<EDGE-IP>:/var/dump/urd/stats-*    ./수집/
scp -r root@<EDGE-IP>:/var/dump/urd/sessions-* ./수집/
```

> 파일명 뒤에 번호가 붙는다 (`....pcap00`). 그래서 `*.pcap*` 로 잡는다.

### ESXi

```bash
scp root@<ESXI-IP>:/tmp/urd-out/*.pcap*    ./수집/
scp -r root@<ESXI-IP>:/tmp/urd-out/stats-* ./수집/
scp -r root@<ESXI-IP>:/tmp/urd-out/dfw-*   ./수집/
```

---

## 7. 정리 (회수 확인 후)  ★ 빠뜨리기 쉬움

> ### ⚠ 캡처 세션은 Edge 클러스터 전체에 생긴다
>
> `set capture session` 을 **한 Edge 에서만** 실행해도, 같은 LIF 를 가진
> **다른 Edge 에도 span 인터페이스가 생긴다.**
> (랩 확인: <edge01> 에서만 만들었는데 <edge02> 에 `span-1` 이 생겼다)
>
> **그러므로 정리는 클러스터의 모든 Edge 에서 해야 한다.**
> 한 대만 지우고 끝내면 나머지 Edge 에서 미러링이 계속 돌아
> 데이터플레인에 부담이 남는다.

### 정리 스크립트 (모든 Edge 에서)

```bash
scp onbox/edge/urd-edge-cleanup.sh root@<EDGE>:/root/urd/    # 이미 올렸으면 생략

# ── Edge 마다 ──
ssh root@<EDGE-1>
cd /root/urd && bash urd-edge-cleanup.sh          # 세션만 해제 (파일은 남김)
# 회수까지 끝났으면
bash urd-edge-cleanup.sh --all                    # 수집 파일까지 삭제

ssh root@<EDGE-2>
cd /root/urd && bash urd-edge-cleanup.sh --all    # ★ 여기도 반드시
```

정상이면 이렇게 나온다.

```
  span 인터페이스   : 0 개   (정상)
  포트 붙은 세션    : 0 개   (정상)
  실행 중 tcpdump   : 0 개   (정상)
<edge01> 정리 완료
```

### 손으로 할 때

```bash
ssh root@<EDGE>
for i in 0 1 2 3 4 5 6 7; do su admin -c "del capture session $i"; done
ip -br link | grep span || echo "span 없음 - 정상"
su admin -c "get capture sessions" | grep PORTS      # 전부 [] 여야 한다
rm -rf /var/dump/urd /root/urd
```

### 전체 Edge 확인 (한 줄)

```bash
for E in <EDGE-1> <EDGE-2>; do
  echo -n "$E : "; ssh root@$E "ip -br link | grep -c span"
done
# 전부 0 이어야 한다
```

### ESXi

```bash
ssh root@<ESXI>
pkill -f pktcap-uw
rm -rf /tmp/urd /tmp/urd-out
```

## 각 스크립트의 실행 모드 (요약)

| 스크립트 | 인자 없음 | `once` | `map` | 초(숫자) |
|---|---|---|---|---|
| `urd-edge-cap-lbt1-svc.sh` | conf 의 `CAP_SECS` | - | - | 그 초만큼 캡처 |
| `urd-edge-cap-vpct1-uplink.sh` | conf 의 `CAP_SECS` | - | - | 그 초만큼 캡처 |
| `urd-edge-stats.sh` | `run` 과 같음 | **1회 수집 후 종료** | - | - |
| `urd-edge-sessions.sh` | `run` 과 같음 | **1회 수집 후 종료** | - | - |
| `urd-esxi-cap-dfw-pre.sh` / `-post.sh` | conf 의 `CAP_SECS` | - | - | 그 초만큼 캡처 |
| `urd-esxi-stats.sh` | `run` 과 같음 | **1회 수집 후 종료** | - | - |
| `urd-esxi-dfw-sessions.sh` | `run` 과 같음 | **1회 수집 후 종료** | **대상 조회만** | - |
| `urd-edge-cleanup.sh` | 우리 것만 정지, 파일 보존 | - | - | `--all` 파일도 삭제 / `--dry-run` / `--all-sessions` |
| `urd-esxi-cleanup.sh` | 우리 것만 정지, 파일 보존 | - | - | `--all` 파일도 삭제 / `--dry-run` |

`run` 은 conf 의 `INTERVAL` 간격으로 `DURATION` 동안 반복한다.
**본 수집 전에는 항상 `map`(ESXi) 과 `once`(양쪽) 로 리허설한다.**

---

## 8. 문제가 생기면

| 증상 | 원인 · 조치 |
|---|---|
| `설정이 비어 있다 — LIF_...` | 그 Edge 용 항목을 conf 에 안 넣었다. §2 로 |
| span-N 생성 실패 | LIF UUID 가 틀렸다. **논리 라우터 UUID 를 넣지 않았는지** 확인 (LIF UUID 여야 한다) |
| 캡처 파일이 24바이트 | 헤더만 있는 빈 pcap. **필터에 맞는 트래픽이 없다는 뜻** — 정상일 수도 있고 Standby Edge 일 수도 있다. §1 의 HA 확인 |
| `Permission denied` (pcap) | tcpdump `-Z root` 누락. 스크립트엔 들어 있으니 직접 명령을 칠 때만 주의 |
| ESXi 에서 `pktcap-uw 가 없다` | ESXi 가 아니거나 PATH 문제. `which pktcap-uw` 로 확인 |
| DFW 필터가 안 잡힘 | 그 VM 이 이 호스트에 없거나 DFW 제외 대상. `sh urd-esxi-dfw-sessions.sh map` 으로 확인 |
| 다른 Edge 에 span 이 남아 있다 | 정상이다 — 세션이 클러스터 전체에 전파된다. **모든 Edge 에서** `urd-edge-cleanup.sh` 실행 |
| 디스크 부족 | Edge `df -h /var/dump`, ESXi `df -h /tmp`. `CAP_FILESIZE` × `CAP_FILECOUNT` 를 줄인다 |

---

## 한 장 요약

| 언제 | 어디서 | 무엇 |
|---|---|---|
| 미리 | admin | `get logical-routers` → SR 찾기 → HA **Active** 확인 |
| 미리 | admin | `get logical-router <SR> interfaces` → **LIF UUID** |
| 미리 | admin | `get load-balancer <LB> pool <POOL> snat-pools` → **Snat IP** |
| 23:30 | Edge root | conf 편집 → **`once` 리허설** → 캡처·상태·세션 4개 `nohup ... &` |
| 23:30 | ESXi root | **`map` → `once` 리허설** → 캡처·상태·세션 4개 `nohup ... &` |
| 03:00 | 노트북 | `scp` 로 회수 |
| 회수 후 | **모든 Edge** | `bash urd-edge-cleanup.sh --all` ← 한 대만 하면 안 된다 |
| 회수 후 | ESXi | `pkill -f pktcap-uw` + 디렉터리 삭제 |
