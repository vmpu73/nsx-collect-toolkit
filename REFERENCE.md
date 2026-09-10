# 온박스 수집 스크립트 — Edge / ESXi 에서 직접 실행

**점프호스트가 아니라 해당 장비에서 직접 돌린다.** 추가 도구 설치가 필요 없다.
모든 명령을 랩(NSX Edge 4.2.4.0.0.25410643 / ESXi 8.0.x)에서 실제로 실행해 확인했다.

```
onbox/
  edge/   ← NSX Edge 에 올린다 (root)     : /root/urd/
  esxi/   ← ESXi 호스트에 올린다 (root)   : /tmp/urd/
```

---

## 어느 파일을 실행하나  ★ 먼저 볼 것

| 파일 | 무엇 |
|---|---|
| **`urd-edge.sh` / `urd-esxi.sh`** | **메뉴.** 장비에서 이것 하나만 기억하면 된다. 나머지 스크립트를 호출만 하고, 실행 직전에 실제 명령어를 화면에 찍는다. `h` 로 사용설명서 |
| `urd-edge.conf` / `urd-esxi.conf` | **편집만 한다.** 실행하지 않는다 |
| `urd-edge-lib.sh` / `urd-esxi-lib.sh` / `_cap-dfw.sh` | **부품.** 실행도 편집도 하지 않는다. 같은 디렉터리에 있기만 하면 된다 |
| 그 외 전부 | **이것만 실행한다** |

실행하는 것은 Edge 5개 · ESXi 4개다.

```
[Edge]  urd-edge-cap-vpct1-uplink.sh    VPC T1 uplink 캡처
        urd-edge-cap-lbt1-svc.sh        LB T1 service 캡처
        urd-edge-stats.sh               상태정보
        urd-edge-sessions.sh            세션/커넥션
        urd-edge-cleanup.sh             뒷정리

[ESXi]  urd-esxi-cap-dfw-pre.sh         DFW pre 캡처
        urd-esxi-cap-dfw-post.sh        DFW post 캡처
        urd-esxi-stats.sh               상태정보
        urd-esxi-dfw-sessions.sh        DFW 커넥션 테이블
```

> 실행 스크립트는 자기 옆의 `*-lib.sh` 와 `*.conf` 를 자동으로 읽는다.
> 그래서 **셋을 같은 폴더에 두는 것**만 지키면 된다.

---

## 왜 장비별로 나뉘어 있나

- **T0 와 T1 은 서로 다른 Edge** 에 있을 수 있다
- **LB T1 과 VPC T1 도 서로 다른 Edge** 에 있을 수 있다
- **DFW 는 하이퍼바이저 커널** 에 있어 ESXi 에서만 볼 수 있다

그래서 Edge 스크립트는 **그 Edge 에 실제로 올라와 있는 논리 라우터만 자동으로 골라서**
수집한다. 같은 스크립트를 어느 Edge 에 올려도 그대로 돈다.
`urd-edge.conf` 에서 그 Edge 에 없는 항목은 **빈 값으로 두면 알아서 건너뛴다.**

---

## Edge (root, bash)

| 파일 | 역할 |
|---|---|
| `urd-edge.conf` | ★ 이 Edge 의 값만 채운다 (알려진 값은 이미 채워져 있다) |
| `urd-edge-lib.sh` | 공통 (직접 실행 안 함) |
| `urd-edge-cap-vpct1-uplink.sh` | **VPC T1 uplink 캡처** — span 세션 **0** |
| `urd-edge-cap-lbt1-svc.sh` | **LB T1 service interface 캡처** — span 세션 **1** |
| `urd-edge-stats.sh` | 상태정보 (이 Edge 의 SR 자동 발견) |
| `urd-edge-sessions.sh` | GFW 커넥션 · LB 세션 테이블 + 집계 |
| `urd-edge-cleanup.sh` | **뒷정리** — 세션 해제·확인 (모든 Edge 에서 실행) |

### 캡처 방식 — span 미러 + 표준 tcpdump

스크립트가 자동으로 하는 일:

```
[admin] set capture session <N> interface <LIF-UUID> direction dual
          → 리눅스 인터페이스 span-<N> 이 생긴다
[root ] timeout -s INT <초> tcpdump -nei span-<N> -Z root \
            -s 256 -C 300 -W 20 -w /var/dump/urd/pcap/<이름>.pcap '<BPF>'
[admin] del capture session <N>          ← 정상 종료·중단 모두에서 자동 정리
```

**span 세션 번호는 캡처마다 다르다** (VPC T1 = 0, LB T1 = 1).
같은 Edge 에서 둘을 동시에 돌려도 서로 간섭하지 않는다 — 랩에서 동시 실행 검증했다.

이 방식을 쓰는 이유:

| | |
|---|---|
| BPF | tcpdump 가 직접 해석한다. CLI 따옴표 문제도, `or`/괄호 제약도 없다 |
| 링버퍼 | `-C`(MB) / `-W`(개수)로 제대로 회전한다 |
| 저장 | `/var/dump` 에 바로 쓴다 (랩 53GB 여유). filestore 개수 제한·`.tgz` 패키징·파일 유실이 없다 |
| 종료 | `timeout -s INT` 로 **시간 기준** 종료. 트래픽이 멎어도 멈추지 않는다 |

> ⚠ **`-Z root` 는 반드시 있어야 한다.** tcpdump 는 기본적으로 권한을 낮추는데,
> `-C/-W` 로 파일을 회전시킬 때 새 파일을 만들지 못해 `Permission denied` 가 난다.
> 랩에서 실제로 겪었다.

> ⚠ `-W` 를 쓰면 파일명 뒤에 **번호가 붙는다** (`....pcap00`). 회수할 때 `*.pcap*` 로 잡는다.

### 실행

```bash
scp edge/* root@<EDGE>:/root/urd/
ssh root@<EDGE>
cd /root/urd && vi urd-edge.conf        # 현장 값 6개만 채운다

bash urd-edge-cap-vpct1-uplink.sh &     # VPC T1 이 있는 Edge 에서
bash urd-edge-cap-lbt1-svc.sh &         # LB  T1 이 있는 Edge 에서
bash urd-edge-stats.sh run &
bash urd-edge-sessions.sh run &
```

결과: 캡처는 `/var/dump/urd/pcap/`, 나머지는 `/var/dump/urd/`

```
회수:  scp root@<EDGE>:/var/dump/urd/pcap/*.pcap* <수집서버>:<경로>/
정리:  rm -rf /var/dump/urd
       su admin -c "del capture session 0"; su admin -c "del capture session 1"
```

> NSX CLI 호출은 **`su admin -c` 로 통일**했다. Edge root 셸에는 `nsxcli` 도 있고
> 둘 다 동작하지만(랩 확인), span 세션 조작이 `su admin` 이라 하나로 맞췄다.

## ESXi (root, busybox sh)

| 파일 | 역할 |
|---|---|
| `urd-esxi.conf` | ★ 이 호스트의 값만 채운다 |
| `urd-esxi-lib.sh` · `_cap-dfw.sh` | 공통 (직접 실행 안 함) |
| `urd-esxi-cap-dfw-pre.sh` | **DFW pre 캡처** |
| `urd-esxi-cap-dfw-post.sh` | **DFW post 캡처** |
| `urd-esxi-stats.sh` | 물리 NIC · VM 포트 통계 |
| `urd-esxi-dfw-sessions.sh` | DFW flow 테이블 · 규칙 · 필터 통계 |
| `urd-esxi-cleanup.sh` | 중단/뒷정리. 우리 프로세스·파일만 정리한다 (`--all` 파일 삭제, `--dry-run` 미리보기) |

```bash
scp esxi/* root@<ESXI>:/tmp/urd/
ssh root@<ESXI>
cd /tmp/urd && vi urd-esxi.conf

sh urd-esxi-dfw-sessions.sh map      # 먼저 매핑 확인
sh urd-esxi-cap-dfw-pre.sh &
sh urd-esxi-cap-dfw-post.sh &
sh urd-esxi-stats.sh run &
sh urd-esxi-dfw-sessions.sh run &
```

결과: `/tmp/urd-out/`.  회수: `scp root@<ESXI>:/tmp/urd-out/* .`

---

## 필터 — 왜 이 값인가

트래픽 경로 (one-arm LB):
```
단말 → NAT(외부IP) → [T0] → [VPC T1] → LB VIP:1812
                                  ↓ one-arm SNAT
                        LB SNAT IP → 워커노드:31820 → 노드 vNIC(DFW) → 파드
```

| 지점 | 필터 | 근거 |
|---|---|---|
| **VPC T1 uplink** | `(host <VIP> or host <NAT_IP>) and (udp port 1812 or icmp)` | 이 지점의 목적지는 **VIP** 다. 다만 NAT 이 T0 위에서 풀렸는지 아래에서 풀리는지 모르니 **둘 다** 건다. ICMP 를 넣는 이유는 백엔드가 없을 때 오는 port-unreachable 이 "조용한 드롭"과 "명시적 거부"를 가르는 결정적 증거이기 때문 |
| **LB T1 service IF** | `(host <VIP> and udp port 1812)`<br>`or (host <SNAT_IP> and udp port 31820)`<br>`or icmp` | one-arm 이라 **두 다리가 같은 인터페이스**를 지난다. SNAT IP 만 걸면 뒷다리만, VIP 만 걸면 앞다리만 보인다. **둘을 함께 떠야** ① 요청 도착 ② 백엔드 전달 ③ 백엔드 응답 ④ 클라이언트 응답이 한 파일에 순서대로 남아 어디서 끊겼는지가 결정된다 |
| **DFW pre / post** | `--udpport 31820`<br>(선택) `--ip <SNAT_IP>` | 이 지점의 패킷은 src=**LB SNAT IP**, dst=**노드 자기 IP**, 포트=**NodePort** 다. 원 클라이언트 IP 는 SNAT 으로 이미 사라졌다. **노드 자기 IP 는 그 vNIC 의 모든 패킷에 있어 변별력이 없다** — 판별자는 NodePort 다. `--udpport` 는 src/dst 양쪽을 보므로 요청·응답이 한 번에 잡힌다 |

> **T0 uplink 는 뺐다.** 그 지점은 NAT 이전일 수 있어 어떤 IP 로 필터를 걸어야 할지가
> 구성에 따라 달라진다. VPC T1 uplink 에서 `VIP or NAT_IP` 로 양쪽을 덮으면 충분하다.

> **DFW 에 `--ip <SNAT_IP>` 를 기본으로 넣지 않는 이유** — LB 가 SNAT 을 하지 않는
> 구성이면 그 순간 0건이 된다. `--udpport` 만으로 충분히 좁고, 어떤 구성에서도 안전하다.
> 볼륨이 문제일 때만 추가한다.

> **pktcap-uw 는 BPF 가 아니다.** `--ip` `--udpport` 같은 옵션형이고 **조건이 AND 로만**
> 묶인다. OR 가 없다. 그래서 ICMP 를 같이 보려면 별도 캡처를 하나 더 띄워야 한다
> (`--proto 0x01`).

---

## 랩에서 확인한 것 (설계 근거)

| # | 확인 사항 |
|---|---|
| 1 | **Edge admin CLI 에는 셸 탈출이 없다.** 스크립트를 돌리려면 **root 셸**이 필요하다. root 에는 bash·awk·sed·timeout·nohup·python3·tcpdump·**nsxcli** 가 다 있다 |
| 2 | **캡처는 span 미러 + tcpdump 가 정답이다.** `set capture session <N> interface <LIF> direction dual` 로 `span-<N>` 을 만들고 거기에 표준 tcpdump 를 붙인다. 랩에서 234·324패킷 캡처 확인 |
| 3 | **`-Z root` 없이 `-C/-W` 를 쓰면 `Permission denied`** 가 난다 (tcpdump 가 권한을 낮춰 새 파일을 못 만든다) |
| 4 | **span 세션 번호는 캡처마다 달라야 한다.** 0/1 로 나눠 동시 실행 검증 완료. `del capture session <N>` 으로 정리되며 `span-<N>` 도 함께 사라진다 |
| 4-1 | **캡처 세션은 Edge 클러스터 전체에 전파된다.** 한 Edge 에서 만들어도 같은 LIF 를 가진 다른 Edge 에 span 이 생긴다(랩 확인). **정리는 모든 Edge 에서** `urd-edge-cleanup.sh` 로 |
| 5 | ESXi 는 **busybox sh** 다. bash 문법을 쓸 수 없고 **`tr` 이 없다**. `command -v` 도 신뢰할 수 없어 **`which`** 를 써야 한다 |
| 6 | `pktcap-uw --uplink` 는 **대화형 확인**을 요구한다 → `echo Y \|` 로 우회 |
| 7 | `pktcap-uw -W`(링버퍼)를 쓰면 파일명에 **숫자가 붙는다** (`....pcap0`) |
| 8 | HA 상태는 **논리 라우터 단위**다. 전역 `get high-availability status` 는 없다 |
| 9 | LB L4 세션 테이블 컬럼: `1=TABLE 2=ID 3=PROTO 4=CADDR 5=CPORT 6=VADDR 7=VPORT 8=SADDR 9=SPORT 10=DADDR 11=DPORT 12=EXP` |

---

## 안전성

- **읽기 전용이다.** 설정을 바꾸는 명령이 없다.
- 쓰기는 Edge `filestore:`/`/var/log/urd` 와 ESXi `/tmp/urd-out` 뿐이다.
- 캡처는 데이터플레인에 부하를 준다. `CAP_SNAPLEN`(기본 256)으로 헤더만 뜬다.
- 시작 전 여유 공간을 확인한다: Edge `nsxcli -c "get filesystem-stats"`, ESXi `df -h /tmp`
