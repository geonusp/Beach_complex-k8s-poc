"""Beach Complex architecture — Kubernetes POC (As-built).

Uses the existing helpers, colours, typography and icon system.
The two Compose EC2 hosts are replaced by the kubeadm 4-node cluster defined in
deploy/k8s (main cbceba45). Components that exist only on unmerged branches or have no install
path in the repository are drawn grey-dashed with a To-be badge.

Routes: service requests stay in the top/right band, Kubernetes control rises from cp-1 into
the worker groups, management flows drop from cp-1 to the AWS services row, and telemetry
crosses the single gutter between obs-1 and the App Worker group.

v2 applies the k8s-reviewer findings 1-6 on top of ../Beach-architecture-k8s-poc (kept as-is).
v3 rebases on main 27e52517: HPA (PR #33) is merged and created only during the HPA experiment.
v4 rebases on main cbceba45 (no structural change since v3), marks instance types/AZs as the
terraform.tfvars.example values, and relabels Ingress as manual-install / controller·DNS unverified.
"""
from pathlib import Path
import base64, html, json

OUT = Path(__file__).resolve().parent
ICONS = OUT / 'icons'
NAME = 'beach-k8s-poc-architecture-v4'
W, H = 2280, 1800

BG = '#f4f7fb'; INK = '#0f2233'; MUTED = '#5f6f82'; LINE = '#334155'; BORDER = '#dfe6ee'
PURPLE = '#7254d0'; TEAL = '#0c9a94'; ORANGE = '#e0892a'; BLUE = '#2f6fd0'; GREEN = '#5f9e3a'
K8S = '#326ce5'; TOBE = '#94a3b8'

svg, checks = [], []

def rect(x, y, w, h, fill='#fff', stroke=BORDER, r=14, dash=None, sw=1.4, shadow=False):
    svg.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r}" fill="{fill}" stroke="{stroke}" '
               f'stroke-width="{sw}"' + (f' stroke-dasharray="{dash}"' if dash else '')
               + (' filter="url(#sh)"' if shadow else '') + '/>')

def text(x, y, s, size=18, color=INK, weight=400, anchor='start', maxw=1000):
    svg.append(f'<text x="{x}" y="{y}" fill="{color}" font-size="{size}" font-weight="{weight}" '
               f'text-anchor="{anchor}">{html.escape(s)}</text>')
    checks.append({'text': s, 'maxWidth': maxw})

def icon(name, x, y, size=48):
    b64 = base64.b64encode((ICONS / f'{name}.svg').read_bytes()).decode()
    svg.append(f'<image x="{x}" y="{y}" width="{size}" height="{size}" href="data:image/svg+xml;base64,{b64}"/>')

def edge(pts, color=LINE, dash=False, end=True, start=False):
    d = ' '.join(f'{x},{y}' for x, y in pts)
    svg.append(f'<polyline points="{d}" fill="none" stroke="{color}" stroke-width="2.4" stroke-linejoin="round" '
               f'stroke-linecap="round"' + (' stroke-dasharray="8 6"' if dash else '')
               + (f' marker-end="url(#m{color[1:]})"' if end else '')
               + (f' marker-start="url(#m{color[1:]})"' if start else '') + '/>')

def label(x, y, s, color=LINE, size=15, plate=True, anchor='middle'):
    if plate:
        w = sum(size * (1 if ord(c) > 255 else .6) for c in s) + 18
        rect(x - w / 2, y - size - 3, w, size + 12, BG if plate == 'bg' else plate if isinstance(plate, str) else '#fff', 'none', 8, sw=0)
    text(x, y + 1, s, size, color, 600, anchor, 400)

def pill_w(s):
    return sum(12.5 if ord(c) > 255 else 8.6 for c in s) + 16

def pill(x, y, s, color=TEAL):
    w = pill_w(s)
    rect(x, y, w, 22, color, 'none', 11, sw=0)
    text(x + w / 2, y + 16, s, 12.5, '#fff', 700, 'middle', w)

def panel(x, y, w, h, title, color, fill='#fff', sub=None, ic=None, dash=None, shadow=True, hx=0):
    rect(x, y, w, h, fill, color if dash else BORDER, 18, dash, 1.6 if dash else 1.2, shadow)
    if not dash:  # coloured accent bar on the left of the header
        rect(x + 22 + hx, y + 24, 5, 26, color, 'none', 2.5, sw=0)
    tx = x + 38 + hx
    if ic:
        icon(ic, x + 36 + hx, y + 20, 32); tx = x + 78 + hx
    text(tx, y + 45, title, 21, color, 700, maxw=w - 60)
    if sub: text(x + w - 22, y + 45, sub, 15, MUTED, 400, 'end', 400)

def vcard(x, y, w, h, ic, title, sub='', isz=52, tsz=19, border=BORDER):
    rect(x, y, w, h, '#fff', border, 12, sw=1.3, shadow=True)
    icon(ic, x + (w - isz) / 2, y + 16, isz)
    ty = y + isz + 44 if sub else y + h - 22
    text(x + w / 2, ty, title, tsz, INK, 700, 'middle', w - 16)
    if sub: text(x + w / 2, ty + 25, sub, 14.5, MUTED, 400, 'middle', w - 16)

def hcard(x, y, w, h, ic, title, sub='', isz=52, tsz=21, border=BORDER, subcolor=MUTED):
    rect(x, y, w, h, '#fff', border, 12, sw=1.3, shadow=True)
    icon(ic, x + 20, y + (h - isz) / 2, isz)
    cy = y + h / 2
    text(x + isz + 38, cy + (-4 if sub else 7), title, tsz, INK, 700, maxw=w - isz - 50)
    if sub: text(x + isz + 38, cy + 21, sub, 14.5, subcolor, 400, maxw=w - isz - 50)

def tobe(x, y, w, h, badge='To-be'):
    """Grey dashed outline + badge on top of a card that is planned or unverified."""
    rect(x, y, w, h, 'none', TOBE, 12, '7 5', 1.8)
    pill(x + w - pill_w(badge) - 14, y - 11, badge, TOBE)

def node(x, y, w, h, title, sub=None):
    """One EC2-backed Kubernetes node."""
    rect(x, y, w, h, EC2FILL, BORDER, 14, sw=1.2)
    icon('ec2', x + 16, y + 14, 28)
    text(x + 52, y + 35, title, 17, ORANGE, 700, maxw=w - 70)
    if sub: text(x + w - 16, y + 35, sub, 14, MUTED, 400, 'end', w - 140)

EC2FILL = '#fff9ef'

# ── canvas + header ─────────────────────────────────────────────
rect(0, 0, W, H, BG, 'none', 0, sw=0)
text(40, 80, 'Beach Complex · Kubernetes POC', 42, INK, 800, maxw=800)
text(42, 118, '시스템 구성도 · As-built 기준 main cbceba45 (2026-10-27) · 저장소 기반 분석 · 인스턴스 유형·AZ는 Terraform 예시값 · rev4', 20, MUTED, maxw=1200)

# ── left column ─────────────────────────────────────────────────
panel(40, 160, 340, 300, 'Client', BLUE)
hcard(60, 285, 300, 110, 'browser', 'Web client', 'React', isz=64, tsz=23)
pill(60, 414, '외부 경로 미검증', TOBE)

panel(40, 500, 340, 560, 'Delivery · CI / CD', PURPLE)
hcard(60, 570, 300, 90, 'github', 'GitHub', 'feature → PR → main', isz=46, tsz=21)
vcard(60, 720, 140, 130, 'actions', 'CI', '빌드 · IaC 검증', isz=44, tsz=20)
vcard(220, 720, 140, 130, 'actions', 'CD', 'amd64 이미지', isz=44, tsz=20)
hcard(60, 920, 300, 90, 'docker', 'GHCR', 'private · latest + SHA', isz=46, tsz=21)
edge([(130, 660), (130, 718)], PURPLE, True)
edge([(290, 660), (290, 718)], PURPLE, True)
label(130, 694, 'PR / push', PURPLE, 13)
label(290, 694, 'main · 경로 조건', PURPLE, 13)
edge([(290, 850), (290, 918)], PURPLE, True)
label(290, 889, '이미지 push', PURPLE, 13)

panel(40, 1100, 340, 440, 'Operator · 로컬 PC', PURPLE)
hcard(60, 1170, 300, 96, 'grafana', 'Grafana 접근', 'SSM 포트 포워딩 :3001', isz=44, tsz=20)
hcard(60, 1295, 300, 96, 'ssm', 'AWS CLI', 'Run Command · S3 회수', isz=44, tsz=20)
hcard(60, 1420, 300, 96, 'terminal', 'Git Bash', 'provision-and-deploy.sh', isz=44, tsz=20)

# ── AWS ─────────────────────────────────────────────────────────
panel(470, 160, 1330, 1280, 'AWS · us-east-1', ORANGE, fill='#fffdf8', sub='beach-vpc 10.0.0.0/16 · public-a / public-b')

# Kubernetes cluster
panel(500, 220, 1270, 1040, 'Kubernetes 클러스터', K8S, fill='#f8fbff', ic='kubernetes', shadow=False,
      sub='kubeadm v1.36 · Cilium 1.20.2 · Pod CIDR 10.244.0.0/16')

# Row A: cluster-level objects in the beach namespace
hcard(540, 300, 260, 80, 'ingress', 'Ingress · nginx', 'beach.example.com', isz=40, tsz=19)
tobe(540, 300, 260, 80, 'controller·DNS 미검증')
hcard(1060, 300, 340, 80, 'service', 'Service beach', 'ClusterIP :80 → 8080', isz=44, tsz=20)
hcard(1440, 300, 300, 80, 'hpa', 'HPA', 'min 2 · max 4 · CPU 60%', isz=40, tsz=19)
pill(1440 + 300 - pill_w('실험 시 생성') - 14, 289, '실험 시 생성', K8S)

# obs-1: observability worker
node(530, 420, 460, 520, 'obs-1', 'observability · t3.medium · 1b')
vcard(550, 490, 190, 120, 'k6', 'k6 Job', '부하 · 장애 실험', isz=44, tsz=18)
vcard(790, 490, 180, 120, 'prometheus', 'Prom. Operator', 'PodMonitor 반영', isz=44, tsz=17)
vcard(550, 640, 190, 120, 'grafana', 'Grafana', 'Beach Overview', isz=44, tsz=18)
vcard(790, 640, 180, 120, 'prometheus', 'Prometheus', '30s · 2d · emptyDir', isz=44, tsz=18)
vcard(550, 790, 190, 120, 'node', 'Metrics Server', 'kubectl top · HPA', isz=44, tsz=17)
vcard(790, 790, 180, 120, 'kubernetes', 'kube-state-metrics', 'API 객체 상태', isz=40, tsz=15)
edge([(742, 700), (788, 700)], TEAL)
text(765, 690, 'PromQL', 12, TEAL, 700, 'middle', 60)

# App worker group
panel(1050, 420, 700, 530, 'App Worker', ORANGE, fill='#fffdf8', dash='9 6', shadow=False)
for x, name in [(1070, 'app-1 · t3.small · 1a'), (1415, 'app-2 · t3.small · 1b')]:
    node(x, 480, 325, 260, name)
    hcard(x + 20, 530, 285, 160, 'spring', 'Beach Pod', ':8080 · :8081 mgmt', isz=48, tsz=20)
    text(x + 106, 653, 'probe 3종 · preStop 10s', 13.5, GREEN, 600, maxw=190)
    text(x + 106, 674, '노드 간 균등 · 필수 분산', 13.5, K8S, 700, maxw=190)
    rect(x + 20, 702, 132, 28, '#fff', BORDER, 8, sw=1.2)
    icon('kubernetes', x + 28, 706, 20)
    text(x + 56, 722, 'CoreDNS', 14, INK, 700, maxw=90)
hcard(1090, 805, 285, 88, 'postgres', 'PostgreSQL', 'postgis 16 · :5432', isz=42, tsz=19)
hcard(1435, 805, 285, 88, 'redis', 'Redis', 'readiness 의존 · :6379', isz=42, tsz=19)
text(1400, 916, 'Beach Pod: maxSkew 1 · DoNotSchedule · Node 장애 시 동작 미검증(#6 후속) · CoreDNS: app 노드 고정', 13.5, MUTED, 400, 'middle', 680)
text(1400, 937, 'PostgreSQL · Redis: app 노드 배치 · 서로 다른 노드 선호 · 영속 볼륨 없음', 13.5, MUTED, 400, 'middle', 680)

# Beach pods -> dependencies (both pods use both Services)
edge([(1232, 692), (1232, 772), (1577, 772), (1577, 803)])
edge([(1577, 692), (1577, 772), (1232, 772), (1232, 803)])
text(1244, 796, 'JDBC', 14, LINE, 600, maxw=60)
text(1589, 796, 'RESP', 14, LINE, 600, maxw=60)

# cp-1: control plane
node(530, 990, 1220, 200, 'cp-1', 'Control Plane · t3.medium · 1a · 단일 CP (etcd 1개)')
for i, (ic, name, sub) in enumerate([('apiserver', 'kube-apiserver', ':6443 · 외부 기본 닫힘'),
                                     ('etcd', 'etcd', '단일 · 스냅샷 없음'),
                                     ('scheduler', 'kube-scheduler', 'nodeSelector · 분산'),
                                     ('controller', 'kube-controller-manager', 'Deployment · Endpoint'),
                                     ('terminal', 'kubectl · helm', 'SSM 실행 지점')]):
    vcard(550 + i * 239, 1048, 224, 124, ic, name, sub, isz=36, tsz=16.5)

# DaemonSets on every node
rect(1080, 1205, 500, 40, '#fff', BORDER, 10, sw=1.2)
icon('daemonset', 1092, 1211, 28)
text(1130, 1231, 'DaemonSet · 모든 노드: cilium-agent · kube-proxy · node-exporter', 14, INK, 600, maxw=440)

# ── service traffic ────────────────────────────────────────────
edge([(360, 340), (538, 340)], TOBE, True)
text(392, 328, 'REST API', 14, TOBE, 700, maxw=76)
edge([(800, 340), (1058, 340)], TOBE, True)
label(930, 340, 'host 라우팅', TOBE, 13)
edge([(710, 488), (710, 400), (1100, 400), (1100, 382)])      # k6 Job -> Service DNS
label(905, 400, 'GET /api/beaches', LINE, 13)
edge([(1360, 382), (1360, 528)])                               # Service -> Ready pods
edge([(1360, 400), (1705, 400), (1705, 528)])
label(1532, 400, 'Ready Endpoint', LINE, 13)

# ── Kubernetes control ─────────────────────────────────────────
edge([(900, 986), (900, 944)], K8S, True, start=True)
label(900, 970, 'kubelet ↔ API', K8S, 13, plate='#f8fbff')
edge([(1400, 988), (1400, 952)], K8S, True)
label(1400, 970, 'Pod 스케줄링 · kubelet', K8S, 13, plate='#f8fbff')
edge([(700, 1046), (700, 912)], K8S, True)
label(700, 970, 'API 집계 · metrics.k8s.io', K8S, 13, plate='#f8fbff')

# ── telemetry ──────────────────────────────────────────────────
rect(1080, 522, 650, 176, 'none', TEAL, 16, '8 6', 1.8)        # PodMonitor target set
pill(1594, 687, 'PodMonitor 대상', TEAL)
edge([(972, 650), (1078, 650)], TEAL, True)                    # PodMonitor scrape
label(1025, 650, 'scrape :8081', TEAL, 13)
text(1020, 678, 'Pod 전체', 12.5, TEAL, 700, 'middle', 56)

# ── delivery & management ──────────────────────────────────────
edge([(360, 965), (498, 965)], PURPLE, True)
text(392, 990, '이미지 pull', 13, PURPLE, 700, maxw=76)
text(392, 1008, 'ghcr-pull', 13, PURPLE, 700, maxw=76)

hcard(530, 1300, 300, 100, 'ssm', 'SSM Run Command', 'SSH 미사용 · 유일한 접근', isz=48, tsz=19)
hcard(860, 1300, 300, 100, 'paramstore', 'Parameter Store', '/beach/dev/ghcr/token', isz=48, tsz=19)
hcard(1460, 1300, 290, 100, 's3', 'S3 결과 버킷', 'SSM 출력 · k6 원본', isz=48, tsz=19)
text(1310, 1345, '운영자 → SSM → cp-1', 15, MUTED, 600, 'middle', 260)
text(1310, 1370, 'kubectl · helm · kustomize', 15, MUTED, 400, 'middle', 260)

edge([(360, 1343), (528, 1343)], PURPLE, True)
text(392, 1331, '명령 전송', 13, PURPLE, 700, maxw=76)
edge([(360, 1372), (450, 1372), (450, 1420), (1605, 1420), (1605, 1402)], PURPLE, True)
label(1310, 1420, '출력 회수 · aws s3 cp', PURPLE, 13, plate='#fffdf8')
edge([(360, 1215), (440, 1215), (440, 1150), (528, 1150)], PURPLE, True)
text(392, 1240, 'SSM 터널', 13, PURPLE, 700, maxw=76)
text(392, 1258, '→ svc', 13, PURPLE, 700, maxw=76)
edge([(680, 1298), (680, 1192)], PURPLE, True)
label(680, 1280, '스크립트 실행', PURPLE, 13, plate='#fffdf8')
edge([(1010, 1192), (1010, 1298)], PURPLE, True)
label(1010, 1280, 'GHCR 토큰 조회', PURPLE, 13, plate='#fffdf8')
edge([(1620, 1192), (1620, 1298)], PURPLE, True)
label(1620, 1280, 'SSM Agent 업로드', PURPLE, 13, plate='#fffdf8')

# ── External integrations (disabled in the POC ConfigMap) ──────
panel(1840, 160, 400, 470, 'External integrations', BLUE)
pill(2116, 184, 'POC 비활성', TOBE)
svg.append('<g opacity=".5">')
for y, ic, name, sub in [(240, 'firebase', 'Firebase FCM', 'FIREBASE_ENABLED=false'),
                         (360, 'gmail', 'Gmail SMTP', 'MAIL_ENABLED=false'),
                         (480, 'lambda', 'AWS Lambda', 'CONGESTION_BASE_URL 미주입')]:
    hcard(1860, y, 360, 104, ic, name, sub, isz=52, tsz=21)
svg.append('</g>')

# ── Legend ─────────────────────────────────────────────────────
panel(1840, 670, 400, 370, '범례', INK)
lg = 740
for kind, color, name in [('line', LINE, '서비스 요청'), ('dash', K8S, 'Kubernetes 제어'),
                          ('dash', PURPLE, '배포 · 관리 · 인프라'), ('dash', TEAL, '관측 데이터 수집'),
                          ('line', TEAL, 'Grafana 조회'), ('dash', TOBE, '예정 · 미검증 (To-be)')]:
    edge([(1870, lg), (1930, lg)], color, kind == 'dash')
    text(1950, lg + 6, name, 17, INK, 500, maxw=260)
    lg += 36
text(1870, lg + 10, '회색 점선 테두리 + 배지 = 설치 자동화·검증이', 14, MUTED, maxw=350)
text(1870, lg + 32, '되지 않았거나 main에 병합되지 않은 구성', 14, MUTED, maxw=350)
pill(1870, lg + 46, '실험 시 생성', K8S)
text(1880 + pill_w('실험 시 생성'), lg + 62, '= 실험 스크립트가 생성 · 삭제', 14, MUTED, maxw=250)

panel(1840, 1070, 400, 370, '미확인 · 범위 밖', MUTED)
for i, s in enumerate(['저장소 기반 분석 · 실클러스터 상태 미확인',
                       'Ingress: ingress-nginx 수동 설치 안내만 존재',
                       '  controller·공인 DNS 미검증 → 외부 경로 미검증',
                       'HPA: run-hpa-experiment.sh 실행 중에만 존재',
                       'NetworkPolicy · Hubble: 이슈 #7 예정',
                       'Traces · Logs: OTLP · Loki 미구성',
                       '기존 Compose EC2 2대: 이 클러스터와 무관',
                       '장애 실험 기록: docs/experiments/issue-6']):
    text(1870, 1152 + i * 34, s, 15, INK if not s.startswith('  ') else MUTED, 400, maxw=350)

# ── Infrastructure band ────────────────────────────────────────
panel(40, 1590, 2200, 170, 'Infrastructure', PURPLE)
text(64, 1680, 'Terraform · deploy/k8s', 16, MUTED, maxw=200)
text(64, 1704, 'environments/dev', 16, MUTED, maxw=200)
for x, ic, name, sub in [(330, 'terraform', 'Terraform', '로컬 state'),
                         (580, 'cloudinit', 'cloud-init', 'containerd · kubeadm'),
                         (840, 'ec2', 'EC2 4대', 't3.medium ×2 · t3.small ×2 (예시)'),
                         (1180, 'security', 'Security Group', '노드 간 self · 6443 닫힘'),
                         (1500, 'iam', 'IAM role', 'SSM · ParamStore · S3')]:
    icon(ic, x - 28, 1612, 56)
    text(x, 1700, name, 20, INK, 700, 'middle', 200)
    text(x, 1728, sub, 14, MUTED, 400, 'middle', 210)
text(2210, 1690, '단명 클러스터 · 검증 후 terraform destroy', 15, MUTED, 400, 'end', 420)
edge([(330, 1518), (330, 1606)], PURPLE, True)
label(330, 1574, 'terraform apply', PURPLE, 13, plate='bg')
edge([(370, 1640), (548, 1640)], PURPLE, True)
label(459, 1640, '초기화 설정', PURPLE, 13)
for x, s in [(840, '프로비저닝'), (1180, '접근 제어'), (1500, '역할 연결')]:
    edge([(x, 1608), (x, 1442)], PURPLE, True)
    label(x, 1515, s, PURPLE, 14, plate='bg')

defs = ('<defs><filter id="sh" x="-10%" y="-10%" width="120%" height="130%">'
        '<feDropShadow dx="0" dy="2" stdDeviation="3" flood-color="#0f2233" flood-opacity=".07"/></filter>'
        + ''.join(f'<marker id="m{c[1:]}" viewBox="0 0 10 10" markerWidth="11" markerHeight="11" refX="8.5" refY="5" '
                  f'orient="auto-start-reverse" markerUnits="userSpaceOnUse"><path d="M0,0 L10,5 L0,10 L2.6,5 Z" fill="{c}"/></marker>'
                  for c in [LINE, PURPLE, TEAL, K8S, TOBE]) + '</defs>')
doc = (f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">'
       '<title>Beach Complex Kubernetes POC architecture</title>'
       f'{defs}<g font-family="Noto Sans CJK KR, Noto Sans KR, sans-serif">' + ''.join(svg) + '</g></svg>')
(OUT / f'{NAME}.svg').write_text(doc, encoding='utf-8')
(OUT / 'text-layout.json').write_text(json.dumps(checks, ensure_ascii=False), encoding='utf-8')
print(f'{len(checks)} labels; {W} x {H}')
