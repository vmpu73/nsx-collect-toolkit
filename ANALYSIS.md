# 패킷 분석 가이드 — 케이스별 tcpdump / tcpdump-uw

수집한 pcap 을 **무엇을 확인하려는가** 기준으로 정리했다. 명령은 전부 랩
(NSX Edge 4.2.4 tcpdump 4.99.1 / ESXi 8.0.3 tcpdump-uw 4.99.4)에서 실제로
실행해 확인했다.

| 장비 | 읽는 명령 | 비고 |
|---|---|---|
| NSX Edge | `tcpdump` | 파일 형식은 고전 pcap |
| ESXi | `tcpdump-uw` | **pktcap-uw 가 만든 파일은 pcapng** 이다. tcpdump-uw 는 둘 다 읽는다 |
| 내 PC | `tcpdump` / Wireshark | `scp -r` 로 실행 폴더째 가져오면 편하다 |

> **도구 없이 한 번에 보려면** 수집기에 들어 있는 분석 기능을 쓰면 된다.
> `python3 nsx-collector.py analyze --dst 10.1.1.10 --dport 1812 --proto udp`
> 는 아래 케이스 대부분을 한 번에 판정해 준다(0장 참고).

---

## 0. 먼저 알아야 할 두 가지 함정

### (1) Edge 파일에는 VLAN 태그가 섞여 있다
Edge 캡처의 일부(주로 응답 방향)에는 802.1Q 태그가 붙는다. 실측: 930개 중
367개, 다른 실행에서 1,576개 중 314개.

**캡처할 때는 문제가 없다**(커널이 태그를 떼고 필터를 적용한다). 하지만
**파일을 읽으면서 조건을 걸면 태그 붙은 쪽이 조용히 빠진다.**

```bash
# 나쁨 - 태그 붙은 절반이 사라진다
tcpdump -nr edge.pcap0 'tcp[tcpflags] & tcp-syn != 0'

# 좋음 - 태그 분기를 함께 준다
E='tcp[tcpflags] & tcp-syn != 0'
tcpdump -nr edge.pcap0 "($E) or (vlan and ($E))"
```

조건 없이 `tcpdump -nr 파일` 로 보면 전부 나온다. 그리고 수집기의 `analyze`
는 pcap 을 직접 해석하므로 이 함정이 없다.

### (2) `host X and port 80` 은 5튜플이 아니다
`tcpdump 'host 172.16.204.2 and tcp port 80'` 은 "주소가 어느 쪽에든 있고,
포트도 어느 쪽에든 있으면" 잡는다. LB SNAT 주소는 임의 포트로 나가므로
`172.16.204.2:80` 같은 조합은 실제로 존재하지 않는다. 방향을 정확히 지정하려면
`src`/`dst` 를 쓴다.

```bash
tcpdump -nr f.pcap0 'src host 172.16.204.2 and dst port 80'   # LB -> 백엔드
tcpdump -nr f.pcap0 'dst host 172.16.204.10 and dst port 80'  # 클라이언트 -> VIP
```

---

## 1. 기본 — 무엇이 들어 있는지 훑기

```bash
tcpdump -nr f.pcap0 | head -20            # 앞부분
tcpdump -nr f.pcap0 | wc -l               # 전체 건수
tcpdump -nr f.pcap0 -c 5 -v               # 자세히 (TTL, IP ID, 길이)
tcpdump -nr f.pcap0 -tttt | head          # 절대 시각으로
tcpdump -ner f.pcap0 | head               # MAC 주소까지
```

대화 상대를 빠르게 세어 보기:
```bash
tcpdump -nr f.pcap0 | awk '{print $3, $5}' | sed 's/:$//' | sort | uniq -c | sort -rn | head
```

초당 패킷 수(트래픽이 끊긴 시점 찾기):
```bash
tcpdump -nr f.pcap0 -tt | awk '{print int($1)}' | uniq -c | head -60
```

---

## 2. 특정 플로우만 꺼내기

```bash
# 5튜플 그대로
tcpdump -nr f.pcap0 'tcp and host 10.1.1.5 and host 10.1.1.50 and port 51000 and port 8080'

# 한쪽 방향만
tcpdump -nr f.pcap0 'src host 10.1.1.5 and dst host 10.1.1.50 and dst port 8080'

# 별도 파일로 저장해서 Wireshark 로 보기
tcpdump -nr f.pcap0 -w flow.pcap 'host 10.1.1.5 and port 8080'
```

Edge 파일이면 태그 분기를 붙인다(0장). 여러 파일을 한 번에 보려면 PC 에서
`mergecap -w all.pcap f.pcap0 f.pcap1` 로 합친 뒤 본다.

---

## 3. TCP — 연결이 되는가

```bash
S='tcp[tcpflags] & (tcp-syn|tcp-ack) == tcp-syn'      # 최초 SYN 만
tcpdump -nr f.pcap0 "($S) or (vlan and ($S))" | wc -l

A='tcp[tcpflags] & (tcp-syn|tcp-ack) == (tcp-syn|tcp-ack)'   # SYN-ACK
tcpdump -nr f.pcap0 "($A) or (vlan and ($A))" | wc -l
```

| 보이는 것 | 뜻 |
|---|---|
| SYN 만 있고 SYN-ACK 없음 | 상대가 응답하지 않았다. 경로 차단이거나 서비스가 죽었다 |
| SYN 이 1초 간격으로 3~6회 | 클라이언트 재시도. 응답이 아예 없다는 뜻 |
| SYN-ACK 는 오는데 이후 RST | 포트는 열렸지만 애플리케이션이 끊었다 |
| 즉시 RST | 포트가 닫혀 있거나 방화벽이 리셋으로 거절 |

리셋과 재전송:
```bash
R='tcp[tcpflags] & tcp-rst != 0'
tcpdump -nr f.pcap0 "($R) or (vlan and ($R))"
tcpdump -nr f.pcap0 'tcp' | awk '{print $2,$4,$6}' | sort | uniq -d | head   # 같은 seq 중복 = 재전송
```

비트값: FIN 0x01 · SYN 0x02 · RST 0x04 · PSH 0x08 · ACK 0x10.
`& 마스크 != 0` 은 "하나라도", `& 마스크 == 값` 은 "정확히 그것만".

---

## 4. UDP — 요청은 갔는데 응답이 오는가

RADIUS(1812 인증 / 1813 과금), DNS, SNMP 처럼 요청-응답 구조에 쓴다.

```bash
tcpdump -nr f.pcap0 'udp port 1812' | wc -l
tcpdump -nr f.pcap0 'src host 10.81.1.112 and dst port 1813' | wc -l   # 요청
tcpdump -nr f.pcap0 'src port 1813 and dst host 10.81.1.112' | wc -l   # 응답
```

**응답 지연 시간 재기** (요청·응답 시각을 나란히 찍어 눈으로 확인):
```bash
tcpdump -nr f.pcap0 -tttt 'host 10.81.1.112 and port 1813' | head -20
```
응답이 30초를 넘기면 **스테이트풀 방화벽의 UDP 세션이 이미 만료**되어 응답이
클라이언트에 도달하지 못한다. NSX Edge GFW 의 UDP 타이머는 기본 30초다.

RADIUS 메시지 종류는 페이로드 첫 바이트다(1=Access-Request, 2=Accept,
3=Reject, 4=Accounting-Request, 5=Accounting-Response, 11=Challenge).
```bash
tcpdump -nr f.pcap0 -X 'udp port 1813' | head -6     # 첫 바이트가 04 / 05 인지
```

---

## 5. ICMP — 경로가 무엇을 돌려주는가

```bash
tcpdump -nr f.pcap0 'icmp'
tcpdump -nr f.pcap0 'icmp[icmptype] == icmp-unreach'
tcpdump -nr f.pcap0 'icmp[icmptype] == icmp-unreach and icmp[icmpcode] == 4'   # MTU 문제
```

| 메시지 | 뜻 |
|---|---|
| destination unreachable / port | 그 포트에서 듣고 있는 것이 없다 |
| destination unreachable / admin prohibited | 방화벽이 거절했다 |
| fragmentation needed (code 4) | 경로 MTU 문제. 큰 패킷만 실패한다 |
| time exceeded | TTL 소진. 라우팅 루프 의심 |

---

## 6. NAT / LB — 주소가 어디서 바뀌는가

같은 트래픽을 지점별로 비교한다.

```bash
# Edge VPC T1 업링크 (NAT 전) — 공인/NAT 주소가 보인다
tcpdump -nr 11-edge-vpct1uplink-*.pcap0 'host 172.20.31.112' | head

# Edge LB T1 서비스 인터페이스 (NAT 후) — VIP 와 LB SNAT 가 보인다
tcpdump -nr 10-edge-lbt1svc-*.pcap0 'host 172.16.204.12' | head
tcpdump -nr 10-edge-lbt1svc-*.pcap0 'src host 172.16.204.2' | head

# ESXi 백엔드 vNIC — 출발지가 LB SNAT 로 바뀐 것이 보인다
tcpdump-uw -nr 20-dfw-pre-web01-eth0.pcap0 'dst port 80' | head
```

한 지점에는 있고 다음 지점에 없으면 그 사이에서 사라진 것이다. 지점 이름
규칙은 `00-run-info.txt` 에 적혀 있다.

---

## 7. DFW — 방화벽이 막았는가

같은 vNIC 의 **pre**(적용 전)와 **post**(적용 후)를 비교한다.

```bash
E='host 10.1.1.50 and tcp port 8080'
echo "pre  : $(tcpdump-uw -nr 20-dfw-pre-web01-eth0.pcap0  "$E" | wc -l)"
echo "post : $(tcpdump-uw -nr 21-dfw-post-web01-eth0.pcap0 "$E" | wc -l)"
```

| pre | post | 판정 |
|---|---|---|
| 있음 | 없음 | DFW 가 막았다 |
| 있음 | 더 적음 | 일부만 막혔다(예: 응답 방향만) |
| 있음 | 같음 | DFW 는 통과시켰다. 문제는 다른 곳 |
| 없음 | 없음 | 이 호스트·이 vNIC 에 애초에 오지 않았다 |

막혔다면 규칙과 카운터를 같이 본다(수집기가 함께 저장한다).
```
session/62-dfw-rules-web01-eth0.txt       적용된 규칙
session/63-dfw-passdrop-web01-eth0.txt    v4 pass / v4 drop 카운터
session/61-dfw-flows-web01-eth0-*.txt     세션 표
```
**드롭 카운터는 "늘어나는지"로 판단한다.** 값이 있어도 그대로면 예전 것이다.

---

## 8. 성능·손실 — 느린가, 빠졌는가

```bash
# 재전송이 많은 구간
tcpdump -nr f.pcap0 -tt 'tcp' | awk '{print int($1)}' | uniq -c | sort -rn | head

# 큰 패킷만 (MTU 확인)
tcpdump -nr f.pcap0 'ip[2:2] > 1400'

# 제로 윈도우 (받는 쪽이 못 읽고 있다)
tcpdump -nr f.pcap0 'tcp[14:2] == 0 and tcp[tcpflags] & tcp-rst == 0'

# 조각난 패킷
tcpdump -nr f.pcap0 'ip[6] & 0x20 != 0 or ip[6:2] & 0x1fff != 0'
```

PC 로 가져왔다면 Wireshark 의 Statistics → Conversations / IO Graph 가 빠르다.
`editcap -i 60 in.pcap out.pcap` 으로 60초 단위로 잘라 볼 수도 있다.

---

## 9. 수집기의 analyze 로 한 번에 보기

위 케이스 대부분을 자동으로 판정한다. pcap 을 직접 해석하므로 VLAN 함정이
없고, pktcap-uw 의 pcapng 도 읽는다.

```bash
python3 nsx-collector.py analyze --dst 172.16.204.10 --dport 80 --proto tcp
python3 nsx-collector.py analyze --src 10.81.1.112 --dport 1813 --proto udp
python3 nsx-collector.py analyze --dst 10.1.1.50 --dport 8080 --proto tcp --run /tmp/nsx-collect/run-...
```
- 값은 전부 선택이고 **응답 방향도 함께** 찾는다.
- 정확한 5튜플로 못 찾으면 `host X and port Y` 식으로 한 번 더 찾아 알려 준다.
- 메뉴에서는 `f` 를 누르면 항목을 하나씩 물어본다.

무엇을 판정해 주는가:

| 종류 | 알려 주는 것 |
|---|---|
| 공통 | 지점별 건수·방향·바이트, 첫/마지막 시각, 관찰된 주소 조합(= NAT 지점) |
| TCP | SYN/SYN-ACK/RST/FIN 수, 핸드셰이크 성공 여부와 RTT, 재전송, 제로 윈도우, 리셋 주체 |
| UDP | 요청/응답 수, 응답 시간 중앙값·최대, **30초 넘으면 방화벽 만료 경고**, RADIUS 메시지 종류 |
| ICMP | 종류·코드 해석(unreachable/MTU 등) |
| 지점 비교 | 같은 vNIC 의 pre/post 비교로 **DFW 통과·일부 드롭·전량 드롭** 구분, Edge 에는 있고 호스트에는 없음 |
| 마지막 | 같은 것을 손으로 확인할 tcpdump 명령(태그 분기 포함)을 그대로 출력 |

---

## 10. 빠른 참조

```bash
tcpdump -nr f.pcap0                                   전체
tcpdump -nr f.pcap0 -tttt                             절대 시각
tcpdump -nr f.pcap0 'host A and host B'               두 주소 사이
tcpdump -nr f.pcap0 'src host A and dst port 443'     방향 지정
tcpdump -nr f.pcap0 "($E) or (vlan and ($E))"         Edge 파일은 이렇게
tcpdump -nr f.pcap0 -w out.pcap '<식>'                 골라서 저장
tcpdump-uw -nr f.pcap0 ...                            ESXi (pcapng 도 읽음)
mergecap -w all.pcap f.pcap0 f.pcap1                  링버퍼 합치기 (PC)
editcap -i 60 in.pcap out.pcap                        60초 단위로 자르기 (PC)
```
