# Billage Helm Charts 가이드

---

## 1. 전체 구조 한눈에 보기

```
billage-k8s-manifests/
├── charts/
│   ├── spring-boot/          # Stateless — Deployment
│   ├── nextjs/               # Stateless — Deployment
│   ├── fastapi/              # Stateless — Deployment
│   ├── rabbitmq/             # Stateful  — StatefulSet
│   └── qdrant/               # Stateful  — StatefulSet
├── base/
│   ├── namespaces.yaml       # 네임스페이스 4개 정의
│   └── network-policies/     # Default Deny 정책
├── argocd/                   # ArgoCD Application 정의 (Phase 5)
└── docs/
    └── helm-charts-guide.md  # 이 문서
```

---

## 2. Helm Chart란 — Terraform과 비교

이미 Terraform에서 이 패턴을 쓰고 있다:

```
Terraform                          Helm
─────────────────                  ─────────────────
modules/vpc/main.tf     ←→        templates/deployment.yaml
variables.tf            ←→        values.yaml
dev.tfvars              ←→        values-dev.yaml
prod.tfvars             ←→        values-prod.yaml
terraform apply         ←→        helm install
```

**Terraform**: 인프라(EC2, VPC, RDS)를 코드로 관리
**Helm**: K8s 리소스(Deployment, Service, HPA)를 코드로 관리

---

## 3. 각 Chart의 구성 파일과 역할

모든 Chart는 이 구조를 따른다:

```
charts/spring-boot/
├── Chart.yaml              # 차트 메타데이터 (이름, 버전)
├── values.yaml             # 기본값 (dev/prod 공통)
├── values-dev.yaml         # dev 환경 override 값
├── values-prod.yaml        # prod 환경 override 값
└── templates/
    ├── _helpers.tpl         # 공통 함수 (라벨 생성 등)
    ├── deployment.yaml      # Pod를 어떻게 만들지 (또는 statefulset.yaml)
    ├── service.yaml         # 네트워크 어떻게 노출할지
    ├── hpa.yaml             # 오토스케일링 규칙
    └── pdb.yaml             # 장애 시 최소 유지 Pod 수
```

### 파일별 역할

| 파일 | 하는 일 | Terraform 비유 |
| --- | --- | --- |
| `Chart.yaml` | 차트 이름, 버전 | 없음 (리포 자체가 역할) |
| `values.yaml` | 모든 설정의 기본값 | `variables.tf`의 default |
| `values-dev.yaml` | dev에서만 다른 값 | `dev.tfvars` |
| `values-prod.yaml` | prod에서만 다른 값 | `prod.tfvars` |
| `_helpers.tpl` | 반복되는 라벨/이름 생성 함수 | `locals {}` 블록 |
| `deployment.yaml` | Pod 스펙 템플릿 | `resource "aws_instance"` |
| `service.yaml` | 클러스터 내부 네트워크 | `resource "aws_lb_target_group"` |
| `hpa.yaml` | CPU 기준 자동 스케일링 | ASG의 scaling policy |
| `pdb.yaml` | 유지보수 시 최소 Pod 보장 | 없음 (K8s 고유) |

### 배포 명령어

```bash
# dev 환경 배포
helm install spring-boot ./charts/spring-boot \
  -n village-app \
  -f ./charts/spring-boot/values-dev.yaml

# prod 환경 배포
helm install spring-boot ./charts/spring-boot \
  -n village-app \
  -f ./charts/spring-boot/values-prod.yaml

# 설정 변경 후 업데이트
helm upgrade spring-boot ./charts/spring-boot \
  -n village-app \
  -f ./charts/spring-boot/values-prod.yaml

# 삭제
helm uninstall spring-boot -n village-app
```

---

## 4. Stateless vs Stateful — 핵심 차이

### 왜 구분이 중요한가

```
Stateless (Deployment)              Stateful (StatefulSet)
──────────────────────              ──────────────────────
Pod 이름: spring-boot-7d8f6b-abc   Pod 이름: rabbitmq-0, rabbitmq-1, rabbitmq-2
                                              ↑ 고정된 순번
죽으면? → 아무 노드에 새로 생성     죽으면? → 같은 이름으로 재생성 + 같은 디스크 재연결
디스크: 없음 (없어도 됨)            디스크: PVC로 영구 저장 (Pod가 죽어도 데이터 유지)
순서: 상관없음                      순서: 0번부터 순서대로 기동
스케일: HPA 자동                    스케일: 보통 수동 (데이터 정합성)
```

| | Spring Boot / Next.js / FastAPI | RabbitMQ / Qdrant |
| --- | --- | --- |
| **K8s 리소스** | Deployment | StatefulSet |
| **Pod 이름** | 랜덤 suffix | 고정 순번 (0, 1, 2) |
| **디스크** | 없음 | PVC (EBS gp3) |
| **네트워크** | ClusterIP Service | Headless Service (고정 DNS) |
| **스케일링** | HPA 자동 | 수동 또는 고정 |
| **배포 순서** | 상관없음 | 순서대로 (OrderedReady) |

---

## 5. Stateful 워크로드 상세 설명

### 5.1 RabbitMQ — 3노드 Quorum 클러스터

#### 왜 3개인가

RabbitMQ의 Quorum Queue는 Raft 합의 알고리즘을 사용한다.
과반수(majority)가 동의해야 메시지가 "저장됨"으로 인정된다.

```
3노드일 때:
  과반수 = 2
  → 1대가 죽어도 2대가 합의 가능 → 정상 운영
  → 2대가 죽으면 과반수 불가 → 서비스 중단

2노드일 때:
  과반수 = 2
  → 1대만 죽어도 과반수 불가 → 의미 없음

그래서 Quorum은 무조건 홀수: 3, 5, 7...
우리 규모에서는 3이면 충분하다.
```

#### StatefulSet 동작 방식

```yaml
# statefulset.yaml 핵심 부분 해석

spec:
  serviceName: rabbitmq-headless    # Headless Service와 연결
  replicas: 3                       # 3개 Pod 고정
  podManagementPolicy: OrderedReady # 0 → 1 → 2 순서대로 기동
```

생성되는 Pod:
```
rabbitmq-0  →  rabbitmq-0.rabbitmq-headless.village-data.svc.cluster.local
rabbitmq-1  →  rabbitmq-1.rabbitmq-headless.village-data.svc.cluster.local
rabbitmq-2  →  rabbitmq-2.rabbitmq-headless.village-data.svc.cluster.local
```

각 Pod는 **고정된 DNS 이름**을 갖는다. 이 DNS로 서로를 찾아 클러스터를 구성한다.

#### 디스크 (PVC)

```yaml
volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      storageClassName: gp3    # AWS EBS gp3 볼륨
      resources:
        requests:
          storage: 20Gi        # Pod당 20GB
```

이러면 자동으로 생성되는 것:
```
PVC: data-rabbitmq-0  →  EBS 볼륨 20GB (AZ-a)
PVC: data-rabbitmq-1  →  EBS 볼륨 20GB (AZ-b)
PVC: data-rabbitmq-2  →  EBS 볼륨 20GB (AZ-c)
```

**rabbitmq-1 Pod가 죽으면?**
→ 새 rabbitmq-1 Pod가 생성됨
→ data-rabbitmq-1 PVC가 다시 연결됨
→ 데이터 유지

#### 노드 배치 전략

```yaml
# 1. 반드시 data 노드에만 배치
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
        - matchExpressions:
            - key: node-role
              operator: In
              values: ["data"]

# 2. 3개 Pod를 반드시 3개 다른 노드에 배치
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchLabels:
            app: rabbitmq
        topologyKey: kubernetes.io/hostname

# 3. data 노드의 taint를 견딜 수 있게
tolerations:
  - key: dedicated
    operator: Equal
    value: data
    effect: NoSchedule
```

결과:
```
Data Node 1 (AZ-a)  →  rabbitmq-0
Data Node 2 (AZ-b)  →  rabbitmq-1
Data Node 3 (AZ-c)  →  rabbitmq-2
                         ↑ 같은 노드에 2개가 배치되는 일은 절대 없음
```

#### 두 종류의 Service

```
1. Headless Service (rabbitmq-headless)
   → clusterIP: None
   → Pod끼리 서로 찾을 때 사용 (클러스터 형성용)
   → rabbitmq-0.rabbitmq-headless.village-data.svc.cluster.local

2. Client Service (rabbitmq)
   → clusterIP: 자동 할당
   → 앱(Spring Boot)이 접속할 때 사용
   → rabbitmq.village-data.svc.cluster.local:5672
   → 3개 Pod에 자동 로드밸런싱
```

#### 핵심 설정 (ConfigMap)

```
vm_memory_high_watermark.absolute = 900MiB
```

RabbitMQ는 메모리를 일정 수준 이상 쓰면 **메시지 수신을 거부**한다 (publisher 차단).
컨테이너 limit이 1.5Gi이므로, 그 60%인 900MiB에서 경고를 울린다.
나머지 600MiB는 OS + Erlang VM + 기타 오버헤드를 위한 여유분이다.

```
default_queue_type = quorum
```

모든 큐를 기본적으로 Quorum Queue로 생성한다.
Classic Queue 대비: 메시지 내구성 보장, 노드 장애 시 자동 리더 선출.

---

### 5.2 Qdrant — 벡터 DB

#### 역할

```
사용자가 물품 등록
    ↓
FastAPI가 이미지/텍스트를 임베딩 벡터로 변환
    ↓
Qdrant에 벡터 저장
    ↓
"비슷한 물품 추천" 요청 시
    ↓
Qdrant에서 유사도 검색 (코사인 유사도)
    ↓
가장 비슷한 물품 ID 반환
```

#### 왜 1개인가

RabbitMQ는 quorum 때문에 3개가 필수였다. Qdrant는?

```
10만 벡터 × 768차원 × 4바이트 × 1.5배 ≈ 0.43GB

→ 메모리 2Gi request면 충분히 여유 있음
→ 데이터 유실 시? 원본(물품 텍스트/이미지)에서 재임베딩 가능 (2~3시간)
→ 1 replica로 시작, 70만 벡터 넘으면 분리 검토
```

#### StatefulSet 핵심

```yaml
spec:
  replicas: 1
  # ...
  containers:
    - name: qdrant
      ports:
        - name: rest       # REST API (벡터 CRUD)
          containerPort: 6333
        - name: grpc       # gRPC (고성능 검색)
          containerPort: 6334
      volumeMounts:
        - name: data
          mountPath: /qdrant/storage    # 벡터 데이터 저장 경로
```

#### RabbitMQ와 같은 노드에 안 두려는 이유

```yaml
podAntiAffinity:
  preferredDuringSchedulingIgnoredDuringExecution:   # "가능하면" 피해라 (soft)
    - weight: 50
      podAffinityTerm:
        labelSelector:
          matchLabels:
            app: rabbitmq
        topologyKey: kubernetes.io/hostname
```

RabbitMQ와 같은 노드에 있으면:
- 둘 다 메모리를 많이 쓰는 워크로드
- node memory pressure 발생 시 kubelet이 둘 중 하나를 강제 종료(eviction)
- `preferred`(soft)이므로 "불가능하면 같은 노드도 OK" → 유연성 유지

#### 백업 CronJob

```
매주 일요일 03:00 (0 3 * * 0)
    ↓
CronJob이 Pod 생성
    ↓
Qdrant Snapshot API 호출 → 스냅샷 파일 생성
    ↓
aws s3 cp로 S3에 업로드
    ↓
Pod 종료

장애 시 복구 옵션:
  A) S3에서 스냅샷 다운로드 → Qdrant에 복원 (빠름)
  B) 원본 데이터에서 전체 재임베딩 (2~3시간, 완전 복구)
```

---

## 6. 노드 배치 전략 요약

```
┌─────────────────────────────────────────────────────┐
│                  Kubernetes Cluster                   │
│                                                       │
│  App Nodes (label: node-role=app)                    │
│  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐   │
│  │ Node 1  │ │ Node 2  │ │ Node 3  │ │ Node 4  │   │
│  │ AZ-a    │ │ AZ-b    │ │ AZ-c    │ │ AZ-a    │   │
│  │         │ │         │ │         │ │         │   │
│  │ spring  │ │ spring  │ │ spring  │ │ nextjs  │   │
│  │ nextjs  │ │ fastapi │ │ fastapi │ │         │   │
│  └─────────┘ └─────────┘ └─────────┘ └─────────┘   │
│  ↑ topologySpread로 AZ/노드에 고르게 분산             │
│  ↑ taint 없음 → 일반 Pod 자유롭게 배치               │
│                                                       │
│  Data Nodes (label: node-role=data, taint: dedicated) │
│  ┌─────────┐ ┌─────────┐ ┌─────────┐               │
│  │ Node 1  │ │ Node 2  │ │ Node 3  │               │
│  │ AZ-a    │ │ AZ-b    │ │ AZ-c    │               │
│  │         │ │         │ │         │               │
│  │ rabbit-0│ │ rabbit-1│ │ rabbit-2│               │
│  │         │ │ qdrant-0│ │         │               │
│  └─────────┘ └─────────┘ └─────────┘               │
│  ↑ taint 있음 → toleration 가진 Pod만 배치 가능      │
│  ↑ RabbitMQ는 hard anti-affinity (반드시 분산)       │
│  ↑ Qdrant는 soft anti-affinity (가능하면 분산)       │
└─────────────────────────────────────────────────────┘
```

---

## 7. values 파일 비교 — dev vs prod

### Spring Boot 예시

| 설정 | values.yaml (기본) | values-dev.yaml | values-prod.yaml |
| --- | --- | --- | --- |
| replicas | 3 | **1** | 3 |
| CPU request | 750m | **500m** | 750m |
| Memory request | 1Gi | **512Mi** | 1Gi |
| CPU limit | 2000m | **1000m** | 2000m |
| Memory limit | 2Gi | **1Gi** | 2Gi |
| HPA | enabled | **disabled** | enabled (min:3 max:10) |
| PDB | enabled | **disabled** | enabled (66%) |

**dev는 왜 작게?**
- 비용 절감 (1 replica, 낮은 리소스)
- HPA/PDB 불필요 (트래픽 없음)
- 기능 테스트만 하면 됨

**prod는 왜 크게?**
- HA 보장 (최소 3 replica)
- 피크 트래픽 대응 (HPA 자동 확장)
- 유지보수 시 보호 (PDB)

---

## 8. 로컬 테스트 방법

### 8.1 Helm 템플릿 렌더링 (클러스터 없이도 가능)

```bash
# Helm이 설치되어 있어야 함
brew install helm

# 템플릿이 어떤 YAML로 변환되는지 미리 보기
helm template spring-boot ./charts/spring-boot \
  -f ./charts/spring-boot/values-dev.yaml \
  -n village-app

# prod 값으로 렌더링
helm template spring-boot ./charts/spring-boot \
  -f ./charts/spring-boot/values-prod.yaml \
  -n village-app
```

이 명령은 클러스터 없이 로컬에서 실행 가능하다.
**결과**: Helm 템플릿이 실제 K8s YAML로 변환된 결과를 보여준다.

### 8.2 문법 검증

```bash
# Chart 문법 검사
helm lint ./charts/spring-boot
helm lint ./charts/rabbitmq

# 모든 차트 한번에
for chart in charts/*/; do
  echo "=== Linting $chart ==="
  helm lint "$chart"
done
```

### 8.3 로컬 K8s 클러스터 (선택)

실제 Pod를 띄워보고 싶다면:

```bash
# kind (Kubernetes IN Docker) — 가장 가벼움
brew install kind
kind create cluster --name billage-test

# 또는 minikube
brew install minikube
minikube start --memory 4096 --cpus 2
```

**주의**: 로컬에서는 nodeAffinity(`node-role=app`)가 맞지 않아 Pod가 Pending된다.
dev 테스트 시에는 nodeAffinity를 제거하거나, 노드에 라벨을 붙여야 한다:

```bash
# kind 노드에 라벨 추가
kubectl label nodes billage-test-control-plane node-role=app
kubectl label nodes billage-test-control-plane node-role=data

# taint는 로컬에서는 안 거는 게 편함
```

```bash
# 네임스페이스 생성
kubectl apply -f base/namespaces.yaml

# Spring Boot만 dev로 배포 테스트
helm install spring-boot ./charts/spring-boot \
  -n village-app \
  -f ./charts/spring-boot/values-dev.yaml

# 상태 확인
kubectl get pods -n village-app
kubectl describe pod -n village-app spring-boot-0

# 정리
helm uninstall spring-boot -n village-app
kind delete cluster --name billage-test
```

### 8.4 추천 테스트 순서

```
1. helm lint (문법 검사) — 지금 바로 가능
2. helm template (렌더링 확인) — 지금 바로 가능
3. kind 클러스터에 dev 배포 — 선택 사항
4. 실제 AWS 클러스터에 배포 — A 완료 후
```

---

## 9. TODO 정리

| 항목 | 상태 | 설명 |
| --- | --- | --- |
| ECR 이미지 URL | 미설정 | 각 values 파일의 `image.repository`에 ECR URL 입력 필요 |
| 환경변수 주입 방식 | 미결정 | K8s Secret vs ExternalSecrets Operator |
| Spring Boot startupProbe | 미적용 | JVM 웜업이 60초 넘으면 추가 검토 |
| WebSocket Ingress 설정 | 미작성 | Ingress 리소스는 A(edge) 담당과 협의 필요 |
| Qdrant 백업 IAM 권한 | 미설정 | S3 PutObject 권한 (Node Role 또는 IRSA) |
| RabbitMQ Erlang Cookie | 미생성 | `kubectl create secret`으로 클러스터에서 생성 |
