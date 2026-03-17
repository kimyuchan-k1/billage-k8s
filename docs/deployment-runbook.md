# Billage K8s Deployment Runbook

> 클러스터가 준비된 후, Helm Chart를 이용해 Billage 서비스를 배포하는 전체 절차.
> 환경: Dev / Prod 공통 (차이점은 각 Step에서 명시)

---

## 목차

- [Phase 0: 사전 준비](#phase-0-사전-준비)
- [Phase 1: 클러스터 상태 확인](#phase-1-클러스터-상태-확인)
- [Phase 2: Helm Chart를 클러스터에서 사용할 수 있게 만들기](#phase-2-helm-chart를-클러스터에서-사용할-수-있게-만들기)
- [Phase 3: 네임스페이스 및 기반 리소스 생성](#phase-3-네임스페이스-및-기반-리소스-생성)
- [Phase 4: Secret 생성](#phase-4-secret-생성)
- [Phase 5: StorageClass 확인](#phase-5-storageclass-확인)
- [Phase 6: Stateful 서비스 배포 (RabbitMQ, Qdrant)](#phase-6-stateful-서비스-배포-rabbitmq-qdrant)
- [Phase 7: Stateless 서비스 배포 (Spring Boot, FastAPI, Next.js)](#phase-7-stateless-서비스-배포-spring-boot-fastapi-nextjs)
- [Phase 8: Ingress 배포](#phase-8-ingress-배포)
- [Phase 9: 전체 검증](#phase-9-전체-검증)
- [Phase 10: 트러블슈팅 가이드](#phase-10-트러블슈팅-가이드)
- [Phase 11: 이미지 태깅 전략](#phase-11-이미지-태깅-전략)
- [Phase 12: GitHub Actions CI 파이프라인](#phase-12-github-actions-ci-파이프라인)
- [Phase 13: ArgoCD 구축 (GitOps)](#phase-13-argocd-구축-gitops)
- [Phase 14: CI/CD 전체 검증](#phase-14-cicd-전체-검증)
- [부록: 주요 리소스 레퍼런스](#부록-주요-리소스-레퍼런스)

---

## Phase 0: 사전 준비

### 0-0. 클러스터 구축 전 준비 체크리스트

> 클러스터가 없어도 미리 준비할 수 있는 항목들

| 완료 | 항목 | 설명 |
|:---:|------|------|
| ✅ | ECR 이미지 URL 설정 | `charts/*/values.yaml`에 ECR 주소 반영 |
| ✅ | CI 템플릿 작성 | `ci-templates/`에 frontend, backend, ai용 GitHub Actions 작성 |
| ✅ | ArgoCD Application manifest | `argocd/`에 AppProject, ApplicationSet 작성 |
| ✅ | manifest 레포 GitHub push | https://github.com/kimyuchan-k1/billage-k8s |
| ✅ | ArgoCD repoURL 수정 | `argocd/apps/*.yaml`의 `repoURL` 반영 완료 |
| ⬜ | 소스 레포에 CI workflow 복사 | `ci-templates/*/`를 각 소스 레포의 `.github/workflows/`에 복사 |
| ⬜ | GitHub Secrets 설정 | 각 소스 레포에 `MANIFEST_REPO_PAT`, `AWS_OIDC_ROLE_ARN`, `DISCORD_WEBHOOK` 등록 |
| ⬜ | PAT 생성 | manifest 레포에 push 권한 있는 Fine-grained PAT 생성 |

### 0-1. 로컬 도구 설치 확인

작업할 머신(로컬 또는 Bastion)에 아래 도구가 설치되어 있어야 한다.

```bash
# 버전 확인
kubectl version --client
helm version
aws --version
```

| 도구 | 최소 버전 | 용도 |
|------|----------|------|
| kubectl | 1.28+ | 클러스터 조작 |
| helm | 3.12+ | Chart 배포 |
| aws-cli | 2.x | ECR 로그인, S3 |

### 0-2. kubeconfig 설정

A팀에게 kubeconfig 파일을 받아서 설정한다.

```bash
# 방법 1: 파일 직접 지정
export KUBECONFIG=/path/to/kubeconfig.yaml

# 방법 2: 기본 위치에 복사
cp /path/to/kubeconfig.yaml ~/.kube/config

# 연결 확인
kubectl cluster-info
```

### 0-3. ECR 이미지 URL 확정

values 파일에 `<AWS_ACCOUNT_ID>` 플레이스홀더가 있다. 배포 전에 실제 값으로 교체한다.

```bash
# 현재 AWS 계정 ID 확인
aws sts get-caller-identity --query Account --output text
# 예: 123456789012
```

교체 대상 파일 및 위치:

| 파일 | image.repository 값 |
|------|---------------------|
| `charts/spring-boot/values-dev.yaml` | `<AWS_ACCOUNT_ID>.dkr.ecr.ap-northeast-2.amazonaws.com/billage-be` |
| `charts/spring-boot/values-prod.yaml` | 동일 |
| `charts/nextjs/values-dev.yaml` | `...amazonaws.com/billage-fe` |
| `charts/nextjs/values-prod.yaml` | 동일 |
| `charts/fastapi/values-dev.yaml` | `...amazonaws.com/billage-ai` |
| `charts/fastapi/values-prod.yaml` | 동일 |

```bash
# 일괄 치환 (리포 루트에서 실행)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

find charts/ -name "values-*.yaml" -exec \
  sed -i '' "s/<AWS_ACCOUNT_ID>/$ACCOUNT_ID/g" {} \;

# 치환 결과 확인
grep -r "dkr.ecr" charts/ --include="values-*.yaml"
```

### 0-4. ECR 이미지 존재 여부 확인

```bash
# ECR 로그인
aws ecr get-login-password --region ap-northeast-2 | \
  docker login --username AWS --password-stdin \
  ${ACCOUNT_ID}.dkr.ecr.ap-northeast-2.amazonaws.com

# 이미지 확인
aws ecr describe-images --repository-name billage-be --query 'imageDetails[*].imageTags' --output table
aws ecr describe-images --repository-name billage-fe --query 'imageDetails[*].imageTags' --output table
aws ecr describe-images --repository-name billage-ai --query 'imageDetails[*].imageTags' --output table
```

세 리포지토리 모두에 `latest` 태그 이미지가 존재해야 한다.

---

## Phase 1: 클러스터 상태 확인

배포를 시작하기 전에 클러스터가 올바르게 구성되었는지 확인한다.

### 1-1. 노드 상태 확인

```bash
kubectl get nodes -o wide
```

**기대 결과:**
- 모든 노드가 `Ready` 상태
- Control Plane 노드 1개 이상
- Worker 노드: App 노드 + Data 노드

```
NAME           STATUS   ROLES           VERSION   OS-IMAGE       ...
cp-1           Ready    control-plane   v1.28.x   Ubuntu 22.04   ...
app-worker-1   Ready    <none>          v1.28.x   Ubuntu 22.04   ...
app-worker-2   Ready    <none>          v1.28.x   Ubuntu 22.04   ...
data-worker-1  Ready    <none>          v1.28.x   Ubuntu 22.04   ...
data-worker-2  Ready    <none>          v1.28.x   Ubuntu 22.04   ...
data-worker-3  Ready    <none>          v1.28.x   Ubuntu 22.04   ...
```

### 1-2. 노드 라벨 확인 (중요)

Helm Chart의 nodeAffinity가 이 라벨에 의존한다. **라벨이 없으면 Pod이 Pending 상태로 멈춘다.**

```bash
# 전체 노드 라벨 확인
kubectl get nodes --show-labels

# node-role 라벨만 필터링
kubectl get nodes -L node-role
```

**기대 결과:**

| 노드 | node-role 값 |
|------|-------------|
| app-worker-* | `app` |
| data-worker-* | `data` |

**라벨이 없는 경우 설정:**

```bash
# App 노드 라벨링
kubectl label nodes app-worker-1 node-role=app
kubectl label nodes app-worker-2 node-role=app

# Data 노드 라벨링
kubectl label nodes data-worker-1 node-role=data
kubectl label nodes data-worker-2 node-role=data
kubectl label nodes data-worker-3 node-role=data
```

### 1-3. 노드 Taint 확인 (중요)

Data 노드에는 taint가 걸려있어야 일반 Pod이 올라가지 않는다.

```bash
# Taint 확인
kubectl describe nodes data-worker-1 | grep -A5 Taints
kubectl describe nodes data-worker-2 | grep -A5 Taints
kubectl describe nodes data-worker-3 | grep -A5 Taints
```

**기대 결과:**
```
Taints: dedicated=data:NoSchedule
```

**Taint가 없는 경우 설정:**
```bash
kubectl taint nodes data-worker-1 dedicated=data:NoSchedule
kubectl taint nodes data-worker-2 dedicated=data:NoSchedule
kubectl taint nodes data-worker-3 dedicated=data:NoSchedule
```

### 1-4. CNI (Calico) 동작 확인

```bash
# Calico Pod 상태
kubectl get pods -n kube-system -l k8s-app=calico-node

# 또는 kube-system 전체 확인
kubectl get pods -n kube-system
```

모든 calico-node Pod이 `Running` 이어야 한다.

### 1-5. CoreDNS 동작 확인

```bash
kubectl get pods -n kube-system -l k8s-app=kube-dns
```

CoreDNS가 `Running`이어야 서비스 간 DNS 이름 해석이 된다.

### 1-6. AZ(가용 영역) 분포 확인

RabbitMQ Pod이 AZ별로 분산되려면 노드가 여러 AZ에 걸쳐있어야 한다.

```bash
kubectl get nodes -L topology.kubernetes.io/zone
```

**기대 결과 (Prod):**
```
NAME           ZONE
data-worker-1  ap-northeast-2a
data-worker-2  ap-northeast-2b
data-worker-3  ap-northeast-2c
```

---

## Phase 2: Helm Chart를 클러스터에서 사용할 수 있게 만들기

`helm install ./charts/spring-boot` 명령은 **Chart 파일이 로컬에 있어야** 동작한다.
즉, kubectl/helm을 실행하는 머신에 이 리포가 있어야 한다.

### 방법 A: Bastion(Jump Host)에서 git clone (권장)

클러스터에 접근 가능한 Bastion 서버에서 직접 작업한다.

```bash
# Bastion에 SSH 접속
ssh ubuntu@<bastion-ip>

# 리포 클론
git clone <billage-k8s-manifests 리포 URL>
cd billage-k8s-manifests

# helm, kubectl이 Bastion에 설치되어 있어야 함
helm version
kubectl get nodes
```

### 방법 B: 로컬에서 직접 실행

kubeconfig로 원격 클러스터에 접근할 수 있다면 로컬에서도 가능하다.

```bash
# kubeconfig 설정 후
export KUBECONFIG=/path/to/kubeconfig.yaml

# 로컬 리포 디렉토리에서 바로 실행
cd /Users/kim-yuchan/Downloads/billage-k8s-manifests
helm install spring-boot ./charts/spring-boot -n village-app -f ./charts/spring-boot/values-dev.yaml
```

> 단, 클러스터 API 서버가 퍼블릭 접근을 허용하거나 VPN이 연결되어 있어야 한다.

### 방법 C: OCI Registry(ECR)에 Helm Chart 푸시 (CI/CD용)

나중에 ArgoCD나 자동화 파이프라인에서 사용하려면 ECR에 Chart를 OCI artifact로 올린다.

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION=ap-northeast-2
ECR_URL="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

# 1. ECR에 Helm Chart용 리포지토리 생성 (서비스당 1개, 최초 1회)
aws ecr create-repository --repository-name helm-charts/spring-boot --region $REGION
aws ecr create-repository --repository-name helm-charts/nextjs --region $REGION
aws ecr create-repository --repository-name helm-charts/fastapi --region $REGION
aws ecr create-repository --repository-name helm-charts/rabbitmq --region $REGION
aws ecr create-repository --repository-name helm-charts/qdrant --region $REGION

# 2. ECR OCI 로그인
aws ecr get-login-password --region $REGION | \
  helm registry login --username AWS --password-stdin $ECR_URL

# 3. Chart 패키징 & 푸시
for chart in spring-boot nextjs fastapi rabbitmq qdrant; do
  helm package ./charts/$chart
  helm push ${chart}-0.1.0.tgz oci://${ECR_URL}/helm-charts
done

# 4. 이후 설치 시 (ECR에서 직접)
helm install spring-boot oci://${ECR_URL}/helm-charts/spring-boot \
  --version 0.1.0 \
  -n village-app \
  -f ./charts/spring-boot/values-prod.yaml
```

> 지금 단계에서는 **방법 A 또는 B**로 충분하다. 방법 C는 ArgoCD 도입 시 적용한다.

---

## Phase 3: 네임스페이스 및 기반 리소스 생성

### 3-1. 네임스페이스 생성

```bash
kubectl apply -f base/namespaces.yaml
```

**검증:**
```bash
kubectl get namespaces
```

기대 결과:
```
NAME           STATUS   AGE
village-app    Active   ...
village-data   Active   ...
village-edge   Active   ...
village-ops    Active   ...
```

### 3-2. Network Policy 적용

```bash
kubectl apply -f base/network-policies/default-deny.yaml
```

**검증:**
```bash
kubectl get networkpolicy -n village-app
kubectl get networkpolicy -n village-data
```

> 이 정책은 기본적으로 모든 트래픽을 차단한다. 서비스 간 통신은 별도 allow 규칙이 필요할 수 있다.
> 초기 배포 시 통신 문제가 발생하면 이 정책을 일시적으로 삭제하고, 이후 세부 규칙을 추가하는 방식도 가능하다.

---

## Phase 4: Secret 생성

**Secret은 반드시 helm install 전에 생성해야 한다.**

### 4-1. RabbitMQ Erlang Cookie

```bash
# Erlang Cookie 생성 (64자 hex)
ERLANG_COOKIE=$(openssl rand -hex 32)
echo "Erlang Cookie: $ERLANG_COOKIE"   # 따로 기록해둘 것

kubectl create secret generic rabbitmq-secret \
  --from-literal=erlang-cookie="$ERLANG_COOKIE" \
  -n village-data
```

### 4-2. Spring Boot Secret

```bash
kubectl create secret generic spring-boot-secret \
  --from-literal=db-url='jdbc:mysql://<RDS_ENDPOINT>:3306/billage' \
  --from-literal=db-username='<DB_USERNAME>' \
  --from-literal=db-password='<DB_PASSWORD>' \
  --from-literal=jwt-secret='<JWT_SECRET>' \
  --from-literal=cors-allowed='https://billages.com' \
  --from-literal=ai-base-url='http://fastapi.village-app.svc.cluster.local:5000' \
  -n village-app
```

> Dev 환경은 cors-allowed를 `https://dev.billages.com`으로,
> ai-base-url은 동일하게 클러스터 내부 DNS를 사용한다.

### 4-3. FastAPI Secret

```bash
kubectl create secret generic fastapi-secret \
  --from-literal=qdrant-url='http://qdrant.village-data.svc.cluster.local:6333' \
  --from-literal=db-url='mysql://<RDS_ENDPOINT>:3306/billage' \
  -n village-app
```

### 4-4. Secret 생성 확인

```bash
kubectl get secrets -n village-app
kubectl get secrets -n village-data
```

기대 결과:
```
# village-app
NAME                  TYPE     DATA   AGE
spring-boot-secret    Opaque   6      ...
fastapi-secret        Opaque   2      ...

# village-data
NAME                  TYPE     DATA   AGE
rabbitmq-secret       Opaque   1      ...
```

---

## Phase 5: StorageClass 확인

StatefulSet(RabbitMQ, Qdrant)이 PVC를 생성할 때 `gp3` StorageClass를 사용한다.

```bash
kubectl get storageclass
```

**기대 결과:**
```
NAME   PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE
gp3    ebs.csi.aws.com         Delete          WaitForFirstConsumer
```

**gp3가 없는 경우:**

EBS CSI Driver와 StorageClass를 설치해야 한다.

```bash
# 1. EBS CSI Driver 설치 여부 확인
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-ebs-csi-driver

# 2. 없으면 Helm으로 설치
helm repo add aws-ebs-csi-driver https://kubernetes-sigs.github.io/aws-ebs-csi-driver
helm install aws-ebs-csi-driver aws-ebs-csi-driver/aws-ebs-csi-driver \
  -n kube-system

# 3. StorageClass 생성
cat <<'EOF' | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  fsType: ext4
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
EOF
```

> kubeadm 클러스터에서는 EBS CSI Driver가 기본 설치되지 않는다.
> A팀에게 EBS CSI Driver 설치 및 IAM 권한(EC2 EBS 관련)을 요청해야 할 수 있다.

---

## Phase 6: Stateful 서비스 배포 (RabbitMQ, Qdrant)

Stateful 서비스를 먼저 배포한다. Spring Boot가 RabbitMQ에 연결하고, FastAPI가 Qdrant에 연결하기 때문이다.

### 6-1. Helm Chart 문법 검증 (Dry Run)

실제 배포 전에 문법 오류를 확인한다.

```bash
ENV=dev  # 또는 prod

# lint: Chart 구조/문법 검사
helm lint ./charts/rabbitmq -f ./charts/rabbitmq/values-${ENV}.yaml
helm lint ./charts/qdrant -f ./charts/qdrant/values-${ENV}.yaml

# template: 렌더링된 YAML 미리보기 (실제 설치 안 함)
helm template rabbitmq ./charts/rabbitmq \
  -n village-data \
  -f ./charts/rabbitmq/values-${ENV}.yaml

helm template qdrant ./charts/qdrant \
  -n village-data \
  -f ./charts/qdrant/values-${ENV}.yaml
```

렌더링된 YAML에서 확인할 것:
- `nodeAffinity`에 `node-role: data`가 있는지
- `tolerations`에 `dedicated=data:NoSchedule`이 있는지
- `image.repository`에 올바른 이미지 경로가 있는지
- Secret 이름이 Phase 4에서 만든 것과 일치하는지

### 6-2. RabbitMQ 배포

```bash
ENV=dev  # 또는 prod

helm install rabbitmq ./charts/rabbitmq \
  -n village-data \
  -f ./charts/rabbitmq/values-${ENV}.yaml
```

**배포 추적:**

```bash
# Pod 상태 확인 (OrderedReady라서 0 → 1 → 2 순서로 뜬다)
kubectl get pods -n village-data -l app=rabbitmq -w

# 기대 결과 (Prod):
# rabbitmq-0   1/1   Running   ...
# rabbitmq-1   1/1   Running   ...
# rabbitmq-2   1/1   Running   ...
```

**RabbitMQ 상세 검증:**

```bash
# PVC가 Bound 되었는지
kubectl get pvc -n village-data
# 기대: data-rabbitmq-0, data-rabbitmq-1, data-rabbitmq-2 → Bound

# 클러스터 상태 확인 (Pod 안에서 실행)
kubectl exec -n village-data rabbitmq-0 -- rabbitmqctl cluster_status

# 기대 결과에서 확인:
# - Running Nodes: rabbit@rabbitmq-0, rabbit@rabbitmq-1, rabbit@rabbitmq-2
# - Quorum: 과반수 이상 alive
```

**Pod이 Pending에 걸리면:**
```bash
kubectl describe pod rabbitmq-0 -n village-data
# Events 섹션에서 원인 확인:
# - "node(s) didn't match Pod's node affinity" → 라벨 확인 (Phase 1-2)
# - "node(s) had untolerated taint" → tolerations 확인
# - "no persistent volumes available" → StorageClass/EBS CSI 확인 (Phase 5)
```

### 6-3. Qdrant 배포

```bash
helm install qdrant ./charts/qdrant \
  -n village-data \
  -f ./charts/qdrant/values-${ENV}.yaml
```

**배포 추적:**

```bash
kubectl get pods -n village-data -l app=qdrant -w

# 기대 결과:
# qdrant-0   1/1   Running   ...
```

**Qdrant 상세 검증:**

```bash
# PVC 확인
kubectl get pvc -n village-data -l app=qdrant
# 기대: data-qdrant-0 → Bound

# Health 확인 (REST API)
kubectl exec -n village-data qdrant-0 -- \
  wget -qO- http://localhost:6333/readyz
# 기대: 200 OK 또는 빈 응답 (정상)

# 또는 port-forward로 로컬에서 확인
kubectl port-forward -n village-data svc/qdrant 6333:6333 &
curl http://localhost:6333/readyz
```

### 6-4. Stateful 서비스 전체 상태 확인

```bash
kubectl get all -n village-data
```

기대 결과:
```
NAME              READY   STATUS    RESTARTS   AGE
pod/rabbitmq-0    1/1     Running   0          ...
pod/rabbitmq-1    1/1     Running   0          ...   (prod only)
pod/rabbitmq-2    1/1     Running   0          ...   (prod only)
pod/qdrant-0      1/1     Running   0          ...

NAME                        TYPE        CLUSTER-IP   EXTERNAL-IP   PORT(S)
service/rabbitmq            ClusterIP   10.x.x.x     <none>        5672/TCP,15672/TCP
service/rabbitmq-headless   ClusterIP   None          <none>        5672/TCP,4369/TCP,25672/TCP
service/qdrant              ClusterIP   10.x.x.x     <none>        6333/TCP,6334/TCP
service/qdrant-headless     ClusterIP   None          <none>        6333/TCP,6334/TCP

NAME                        READY   AGE
statefulset.apps/rabbitmq   3/3     ...
statefulset.apps/qdrant     1/1     ...
```

---

## Phase 7: Stateless 서비스 배포 (Spring Boot, FastAPI, Next.js)

### 배포 순서

1. **FastAPI** — Qdrant에 연결 필요 (Phase 6에서 배포됨)
2. **Spring Boot** — RabbitMQ + FastAPI에 연결 필요
3. **Next.js** — Spring Boot API에 연결 필요

> 엄밀히 말하면 K8s는 서비스 디스커버리로 연결하므로 순서가 강제는 아니다.
> 하지만 헬스체크가 의존 서비스 연결까지 포함할 수 있으므로, 이 순서가 안전하다.

### 7-1. Dry Run

```bash
ENV=dev  # 또는 prod

for chart in fastapi spring-boot nextjs; do
  echo "=== $chart ==="
  helm lint ./charts/$chart -f ./charts/$chart/values-${ENV}.yaml
done
```

### 7-2. FastAPI 배포

```bash
helm install fastapi ./charts/fastapi \
  -n village-app \
  -f ./charts/fastapi/values-${ENV}.yaml
```

**검증:**
```bash
kubectl get pods -n village-app -l app=fastapi -w

# Running 확인 후 헬스체크
kubectl exec -n village-app deploy/fastapi -- \
  wget -qO- http://localhost:5000/ai/health
```

### 7-3. Spring Boot 배포

```bash
helm install spring-boot ./charts/spring-boot \
  -n village-app \
  -f ./charts/spring-boot/values-${ENV}.yaml
```

**검증:**
```bash
kubectl get pods -n village-app -l app=spring-boot -w

# Spring Boot는 JVM 시작이 느리다. startupProbe가 최대 160초까지 기다린다.
# STATUS가 Running이지만 READY가 0/1이면 아직 startupProbe 진행 중이다.

# Running + Ready 확인 후:
kubectl exec -n village-app deploy/spring-boot -- \
  wget -qO- http://localhost:8080/actuator/health
# 기대: {"status":"UP"}
```

### 7-4. Next.js 배포

```bash
helm install nextjs ./charts/nextjs \
  -n village-app \
  -f ./charts/nextjs/values-${ENV}.yaml
```

**검증:**
```bash
kubectl get pods -n village-app -l app=nextjs -w

kubectl exec -n village-app deploy/nextjs -- \
  wget -qO- http://localhost:3000/
# HTML 응답이 오면 정상
```

### 7-5. Stateless 서비스 전체 상태 확인

```bash
kubectl get all -n village-app
```

기대 결과 (Prod):
```
NAME                               READY   STATUS    RESTARTS   AGE
pod/fastapi-xxx-yyy                1/1     Running   0          ...
pod/fastapi-xxx-zzz                1/1     Running   0          ...
pod/spring-boot-xxx-yyy            1/1     Running   0          ...
pod/spring-boot-xxx-zzz            1/1     Running   0          ...
pod/spring-boot-xxx-www            1/1     Running   0          ...
pod/nextjs-xxx-yyy                 1/1     Running   0          ...
pod/nextjs-xxx-zzz                 1/1     Running   0          ...

NAME                  TYPE        CLUSTER-IP   PORT(S)
service/spring-boot   ClusterIP   10.x.x.x     8080/TCP
service/fastapi       ClusterIP   10.x.x.x     5000/TCP
service/nextjs        ClusterIP   10.x.x.x     3000/TCP

NAME                          READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/spring-boot   3/3     3            3           ...
deployment.apps/fastapi       2/2     2            2           ...
deployment.apps/nextjs        2/2     2            2           ...
```

### 7-6. HPA 확인 (Prod만)

```bash
kubectl get hpa -n village-app
```

기대 결과:
```
NAME          REFERENCE                TARGETS   MINPODS   MAXPODS   REPLICAS   AGE
spring-boot   Deployment/spring-boot   25%/70%   3         10        3          ...
fastapi       Deployment/fastapi       15%/50%   2         5         2          ...
nextjs        Deployment/nextjs        20%/70%   2         6         2          ...
```

> TARGETS에 `<unknown>/70%`이 표시되면 Metrics Server가 설치되지 않은 것이다.
> A팀에게 Metrics Server 설치를 요청해야 한다.

```bash
# Metrics Server 확인
kubectl get pods -n kube-system -l k8s-app=metrics-server
```

### 7-7. PDB 확인 (Prod만)

```bash
kubectl get pdb -n village-app
kubectl get pdb -n village-data
```

---

## Phase 8: Ingress 배포

### 8-1. Ingress Controller 존재 확인

Ingress 리소스만 만들면 안 되고, Ingress Controller(nginx)가 클러스터에 설치되어 있어야 한다.

```bash
# nginx ingress controller 확인
kubectl get pods -n ingress-nginx
# 또는
kubectl get pods --all-namespaces -l app.kubernetes.io/name=ingress-nginx
```

**설치되어 있지 않으면:**
```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm install ingress-nginx ingress-nginx/ingress-nginx \
  -n ingress-nginx \
  --create-namespace \
  --set controller.service.type=LoadBalancer
```

> A팀이 Ingress Controller를 미리 설치해두었을 수도 있다. 먼저 확인 후 진행한다.

### 8-2. TLS 인증서 Secret 생성

```bash
# cert-manager 사용 시 자동 관리되지만, 수동으로 하는 경우:
kubectl create secret tls billage-tls \
  --cert=/path/to/fullchain.pem \
  --key=/path/to/privkey.pem \
  -n village-app
```

### 8-3. Ingress 리소스 배포

```bash
kubectl apply -f base/ingress.yaml
```

**검증:**
```bash
kubectl get ingress -n village-app
```

기대 결과:
```
NAME              CLASS   HOSTS                              ADDRESS        PORTS     AGE
billage-ingress   nginx   billages.com,api.billages.com      <EXTERNAL-IP>  80, 443   ...
```

### 8-4. Ingress 라우팅 테스트

```bash
INGRESS_IP=$(kubectl get ingress billage-ingress -n village-app -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# 또는 hostname인 경우
INGRESS_HOST=$(kubectl get ingress billage-ingress -n village-app -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

# 프론트엔드
curl -H "Host: billages.com" http://$INGRESS_IP/

# REST API
curl -H "Host: api.billages.com" http://$INGRESS_IP/api/health

# AI API
curl -H "Host: api.billages.com" http://$INGRESS_IP/ai/health
```

> DNS가 아직 안 걸려있으면 Host 헤더로 테스트한다.
> 이후 Route53에서 billages.com, api.billages.com → INGRESS_IP(또는 hostname) A/CNAME 레코드를 추가한다.

---

## Phase 9: 전체 검증

모든 배포가 완료되었으면 전체 시스템이 정상 동작하는지 검증한다.

### 9-1. 전체 리소스 한눈에 보기

```bash
echo "=== village-app ==="
kubectl get all -n village-app

echo ""
echo "=== village-data ==="
kubectl get all -n village-data

echo ""
echo "=== PVC ==="
kubectl get pvc -A

echo ""
echo "=== Ingress ==="
kubectl get ingress -n village-app

echo ""
echo "=== HPA ==="
kubectl get hpa -n village-app

echo ""
echo "=== PDB ==="
kubectl get pdb -n village-app -n village-data
```

### 9-2. 서비스 간 연결 테스트

```bash
# Spring Boot → RabbitMQ 연결
kubectl exec -n village-app deploy/spring-boot -- \
  wget -qO- --timeout=5 http://rabbitmq.village-data.svc.cluster.local:15672
# RabbitMQ Management UI HTML이 오면 정상

# FastAPI → Qdrant 연결
kubectl exec -n village-app deploy/fastapi -- \
  wget -qO- --timeout=5 http://qdrant.village-data.svc.cluster.local:6333/readyz
# 200 OK면 정상

# Spring Boot → FastAPI 연결
kubectl exec -n village-app deploy/spring-boot -- \
  wget -qO- --timeout=5 http://fastapi.village-app.svc.cluster.local:5000/ai/health

# Next.js → Spring Boot 연결
kubectl exec -n village-app deploy/nextjs -- \
  wget -qO- --timeout=5 http://spring-boot.village-app.svc.cluster.local:8080/actuator/health
```

> 연결이 안 되면 **Network Policy** 때문일 수 있다.
> Phase 3-2에서 적용한 default-deny 정책이 트래픽을 막고 있을 수 있다.
>
> 임시 해제:
> ```bash
> kubectl delete networkpolicy default-deny-village-app -n village-app
> kubectl delete networkpolicy default-deny-village-data -n village-data
> ```
> 이후 세부 allow 규칙을 작성하여 다시 적용한다.

### 9-3. 로그 확인

```bash
# 서비스별 최근 로그
kubectl logs -n village-app deploy/spring-boot --tail=50
kubectl logs -n village-app deploy/fastapi --tail=50
kubectl logs -n village-app deploy/nextjs --tail=50
kubectl logs -n village-data rabbitmq-0 --tail=50
kubectl logs -n village-data qdrant-0 --tail=50
```

### 9-4. DNS 테스트 (클러스터 내부)

```bash
# 임시 Pod으로 DNS 해석 확인
kubectl run dns-test --rm -it --image=busybox --restart=Never -- nslookup spring-boot.village-app.svc.cluster.local

kubectl run dns-test2 --rm -it --image=busybox --restart=Never -- nslookup rabbitmq-headless.village-data.svc.cluster.local
```

### 9-5. 최종 체크리스트

| 항목 | 확인 명령어 | 기대 결과 |
|------|-----------|----------|
| 모든 Pod Running | `kubectl get pods -A -l 'app in (spring-boot,nextjs,fastapi,rabbitmq,qdrant)'` | 전부 `1/1 Running` |
| PVC Bound | `kubectl get pvc -n village-data` | 전부 `Bound` |
| RabbitMQ Cluster | `kubectl exec -n village-data rabbitmq-0 -- rabbitmqctl cluster_status` | 3노드 연결 (prod) |
| Qdrant Health | `kubectl exec -n village-data qdrant-0 -- wget -qO- http://localhost:6333/readyz` | 정상 응답 |
| Spring Boot Health | `kubectl exec -n village-app deploy/spring-boot -- wget -qO- http://localhost:8080/actuator/health` | `{"status":"UP"}` |
| Ingress 접근 | `curl -H "Host: billages.com" http://<INGRESS_IP>/` | HTML 응답 |
| HPA 동작 (prod) | `kubectl get hpa -n village-app` | TARGETS에 % 표시 |
| 서비스 간 통신 | 9-2 항목 전체 | 전부 응답 |

---

## Phase 10: 트러블슈팅 가이드

### Pod이 Pending 상태

```bash
kubectl describe pod <pod-name> -n <namespace>
```

| Events 메시지 | 원인 | 해결 |
|--------------|------|------|
| `node(s) didn't match Pod's node affinity/selector` | 노드에 `node-role` 라벨 없음 | Phase 1-2 라벨 설정 |
| `node(s) had untolerated taint {dedicated: data}` | App Pod이 data 노드에 스케줄링 시도 | 라벨 확인, app 노드가 부족한지 확인 |
| `no persistent volumes available` | StorageClass 없거나 EBS CSI 미설치 | Phase 5 참조 |
| `insufficient cpu/memory` | 노드 리소스 부족 | `kubectl describe node <name>`으로 Allocatable 확인 |
| `didn't match pod anti-affinity rules` | 같은 노드에 이미 해당 Pod 존재 | Data 노드가 3개 이상인지 확인 (RabbitMQ) |

### Pod이 CrashLoopBackOff 상태

```bash
# 최근 로그 확인
kubectl logs <pod-name> -n <namespace> --previous

# 자주 발생하는 원인:
# - Secret이 없거나 키 이름이 다름
# - DB 연결 실패 (RDS 보안그룹이 클러스터 CIDR 허용하는지)
# - RabbitMQ Erlang Cookie 불일치
```

### Pod이 Running이지만 Ready가 0/1

```bash
kubectl describe pod <pod-name> -n <namespace>
# Events에서 readiness probe 실패 원인 확인

# 흔한 원인:
# - Spring Boot: JVM 시작 중 (startupProbe 기다려야 함, 최대 160초)
# - 의존 서비스 미연결 (RabbitMQ/Qdrant가 아직 안 뜸)
# - 포트 불일치
```

### Service 연결 안 됨

```bash
# 엔드포인트 확인 (Pod과 Service가 연결되어 있는지)
kubectl get endpoints <service-name> -n <namespace>

# 빈 값이면 selector 라벨이 Pod과 불일치
# Pod 라벨 확인:
kubectl get pods -n <namespace> --show-labels
```

### Ingress로 접근 안 됨

```bash
# Ingress Controller 로그
kubectl logs -n ingress-nginx deploy/ingress-nginx-controller --tail=100

# Ingress 상태
kubectl describe ingress billage-ingress -n village-app

# 흔한 원인:
# - Ingress Controller 미설치
# - Service 이름/포트 불일치
# - TLS Secret 미생성
# - Network Policy가 ingress 트래픽 차단
```

### ECR 이미지 Pull 실패

```bash
kubectl describe pod <pod-name> -n <namespace>
# "ImagePullBackOff" 또는 "ErrImagePull"

# 해결:
# 1. Worker 노드에서 ECR 접근 가능한지 (IAM 역할에 ecr:GetDownloadUrlForLayer 등)
# 2. 이미지 URL/태그가 정확한지
# 3. ECR 리포지토리에 이미지가 존재하는지
```

---

## Phase 11: 이미지 태깅 전략

> Phase 0~10까지 수동 배포로 서비스가 정상 동작하는 것을 확인한 후, CI/CD 자동화를 구축한다.

### 11-1. 태그 컨벤션

`latest` 태그는 사용하지 않는다. 어떤 코드가 배포되었는지 추적할 수 없고, K8s가 변경을 감지하지 못한다.

| 환경 | 태그 형식 | 예시 |
|------|----------|------|
| Dev | `dev-{git-short-sha}` | `dev-a1b2c3d` |
| Prod | `prod-{git-short-sha}` | `prod-e4f5g6h` |

### 11-2. ECR 리포지토리당 이미지 흐름

```
billage-be 리포지토리:
  dev-a1b2c3d   ← dev 브랜치 push 시
  dev-b2c3d4e   ← dev 브랜치 다음 push 시
  prod-x9y8z7w  ← main 브랜치 push/merge 시
```

하나의 ECR 리포지토리에 dev/prod 이미지가 공존한다. 태그 prefix로 구분.

### 11-3. values 파일 변경

기존 `latest` 태그를 git sha 기반으로 변경한다. 이 값은 CI가 자동으로 업데이트한다.

```yaml
# charts/spring-boot/values-dev.yaml
image:
  repository: "<AWS_ACCOUNT_ID>.dkr.ecr.ap-northeast-2.amazonaws.com/billage-be"
  tag: "dev-a1b2c3d"  # ← CI가 자동 갱신

# charts/spring-boot/values-prod.yaml
image:
  tag: "prod-e4f5g6h"  # ← CI가 자동 갱신
```

### 11-4. ECR Lifecycle Policy (선택)

오래된 이미지가 쌓이지 않도록 정리 정책을 설정한다.

```bash
aws ecr put-lifecycle-policy --repository-name billage-be --lifecycle-policy-text '{
  "rules": [
    {
      "rulePriority": 1,
      "description": "Keep last 20 dev images",
      "selection": {
        "tagStatus": "tagged",
        "tagPrefixList": ["dev-"],
        "countType": "imageCountMoreThan",
        "countNumber": 20
      },
      "action": { "type": "expire" }
    },
    {
      "rulePriority": 2,
      "description": "Keep last 10 prod images",
      "selection": {
        "tagStatus": "tagged",
        "tagPrefixList": ["prod-"],
        "countType": "imageCountMoreThan",
        "countNumber": 10
      },
      "action": { "type": "expire" }
    }
  ]
}'
```

---

## Phase 12: GitHub Actions CI 파이프라인

### 12-0. 레포 구조 전제

```
billage-be               ← Spring Boot 소스코드 + CI workflow
billage-fe               ← Next.js 소스코드 + CI workflow
billage-ai               ← FastAPI 소스코드 + CI workflow
billage-k8s-manifests    ← Helm Chart + values (이 레포)
```

각 앱 레포의 CI가 빌드/푸시 후, **이 레포(billage-k8s-manifests)의 values 파일을 자동으로 수정**한다.

### 12-1. 사전 준비: GitHub PAT 등록

앱 레포에서 manifests 레포에 push하려면 Personal Access Token이 필요하다.

1. GitHub → Settings → Developer Settings → Personal Access Tokens → Fine-grained tokens
2. 토큰 생성:
   - Repository access: `billage-k8s-manifests` 선택
   - Permissions: Contents → Read and write
3. 각 앱 레포(billage-be, billage-fe, billage-ai)에 Secret 등록:
   - Settings → Secrets → Actions → `MANIFEST_REPO_PAT`

### 12-2. 앱 레포 CI Workflow (Spring Boot 예시)

`billage-be/.github/workflows/ci-cd.yml`:

```yaml
name: CI/CD

on:
  push:
    branches: [dev, main]

env:
  AWS_REGION: ap-northeast-2
  ECR_REPOSITORY: billage-be
  MANIFEST_REPO: your-org/billage-k8s-manifests  # ← 실제 org/repo로 변경

jobs:
  build-and-push:
    runs-on: ubuntu-latest
    outputs:
      image-tag: ${{ steps.meta.outputs.image-tag }}

    steps:
      - uses: actions/checkout@v4

      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          aws-region: ${{ env.AWS_REGION }}

      - name: Login to ECR
        id: ecr-login
        uses: aws-actions/amazon-ecr-login@v2

      - name: Set image tag
        id: meta
        run: |
          SHORT_SHA=$(echo "${{ github.sha }}" | cut -c1-7)
          if [ "${{ github.ref }}" = "refs/heads/main" ]; then
            echo "image-tag=prod-${SHORT_SHA}" >> $GITHUB_OUTPUT
            echo "env=prod" >> $GITHUB_OUTPUT
          else
            echo "image-tag=dev-${SHORT_SHA}" >> $GITHUB_OUTPUT
            echo "env=dev" >> $GITHUB_OUTPUT
          fi

      - name: Build & Push Docker image
        env:
          ECR_REGISTRY: ${{ steps.ecr-login.outputs.registry }}
          IMAGE_TAG: ${{ steps.meta.outputs.image-tag }}
        run: |
          docker build -t $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG .
          docker push $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG

  update-manifests:
    needs: build-and-push
    runs-on: ubuntu-latest

    steps:
      - name: Checkout manifests repo
        uses: actions/checkout@v4
        with:
          repository: ${{ env.MANIFEST_REPO }}
          token: ${{ secrets.MANIFEST_REPO_PAT }}

      - name: Update image tag
        run: |
          IMAGE_TAG="${{ needs.build-and-push.outputs.image-tag }}"

          # dev- 또는 prod- prefix로 환경 판별
          if [[ "$IMAGE_TAG" == prod-* ]]; then
            VALUES_FILE="charts/spring-boot/values-prod.yaml"
          else
            VALUES_FILE="charts/spring-boot/values-dev.yaml"
          fi

          # tag 값 교체
          sed -i "s|tag:.*|tag: \"${IMAGE_TAG}\"|" $VALUES_FILE

          echo "Updated $VALUES_FILE with tag: $IMAGE_TAG"
          cat $VALUES_FILE

      - name: Commit & Push
        run: |
          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git add .
          git commit -m "chore(spring-boot): update image tag to ${{ needs.build-and-push.outputs.image-tag }}"
          git push
```

### 12-3. FE, AI 레포 적용

위 workflow를 복사하여 다음만 변경한다:

| 레포 | `ECR_REPOSITORY` | `VALUES_FILE` 경로 |
|------|------------------|-------------------|
| billage-be | `billage-be` | `charts/spring-boot/values-{env}.yaml` |
| billage-fe | `billage-fe` | `charts/nextjs/values-{env}.yaml` |
| billage-ai | `billage-ai` | `charts/fastapi/values-{env}.yaml` |

### 12-4. CI 동작 검증

앱 레포에 push 후 확인할 것:

```bash
# 1. GitHub Actions 탭에서 workflow 성공 확인

# 2. ECR에 이미지가 올라갔는지
aws ecr describe-images --repository-name billage-be \
  --query 'imageDetails[*].imageTags' --output table

# 3. manifests 레포에 커밋이 생겼는지
cd billage-k8s-manifests
git pull
git log --oneline -5
# 기대: "chore(spring-boot): update image tag to dev-a1b2c3d"

# 4. values 파일의 tag가 변경되었는지
grep "tag:" charts/spring-boot/values-dev.yaml
```

---

## Phase 13: ArgoCD 구축 (GitOps)

### 13-1. ArgoCD 설치

```bash
# 네임스페이스 생성 (이미 namespaces.yaml에 village-ops가 있다면 스킵)
kubectl create namespace village-ops

# ArgoCD 설치
kubectl apply -n village-ops \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Pod 상태 확인 (모두 Running까지 1~2분)
kubectl get pods -n village-ops -w
```

### 13-2. ArgoCD CLI 설치 & 로그인

```bash
# CLI 설치 (macOS)
brew install argocd

# 초기 admin 비밀번호 확인
ARGO_PW=$(kubectl get secret argocd-initial-admin-secret -n village-ops \
  -o jsonpath='{.data.password}' | base64 -d)
echo $ARGO_PW

# 포트포워딩으로 접근
kubectl port-forward svc/argocd-server -n village-ops 8443:443 &

# 로그인
argocd login localhost:8443 --username admin --password $ARGO_PW --insecure

# 비밀번호 변경 (권장)
argocd account update-password
```

### 13-3. Git 리포지토리 연결

```bash
# 이 manifests 레포를 ArgoCD에 등록
argocd repo add https://github.com/your-org/billage-k8s-manifests.git \
  --username <github-username> \
  --password <github-pat>
```

### 13-4. ArgoCD Application 생성

서비스당 1개의 Application을 만든다. Dev/Prod를 분리한다.

**Dev 환경:**

```bash
# Spring Boot - Dev
argocd app create spring-boot-dev \
  --repo https://github.com/your-org/billage-k8s-manifests.git \
  --path charts/spring-boot \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace village-app \
  --helm-values values-dev.yaml \
  --sync-policy automated \
  --auto-prune \
  --self-heal

# FastAPI - Dev
argocd app create fastapi-dev \
  --repo https://github.com/your-org/billage-k8s-manifests.git \
  --path charts/fastapi \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace village-app \
  --helm-values values-dev.yaml \
  --sync-policy automated \
  --auto-prune \
  --self-heal

# Next.js - Dev
argocd app create nextjs-dev \
  --repo https://github.com/your-org/billage-k8s-manifests.git \
  --path charts/nextjs \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace village-app \
  --helm-values values-dev.yaml \
  --sync-policy automated \
  --auto-prune \
  --self-heal

# RabbitMQ - Dev
argocd app create rabbitmq-dev \
  --repo https://github.com/your-org/billage-k8s-manifests.git \
  --path charts/rabbitmq \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace village-data \
  --helm-values values-dev.yaml \
  --sync-policy automated \
  --auto-prune \
  --self-heal

# Qdrant - Dev
argocd app create qdrant-dev \
  --repo https://github.com/your-org/billage-k8s-manifests.git \
  --path charts/qdrant \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace village-data \
  --helm-values values-dev.yaml \
  --sync-policy automated \
  --auto-prune \
  --self-heal
```

**Prod 환경 (수동 Sync 권장):**

```bash
# Spring Boot - Prod (automated 대신 수동)
argocd app create spring-boot-prod \
  --repo https://github.com/your-org/billage-k8s-manifests.git \
  --path charts/spring-boot \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace village-app \
  --helm-values values-prod.yaml
  # sync-policy 미지정 → 수동 Sync

# 나머지 Prod 앱도 동일하게 (fastapi-prod, nextjs-prod, rabbitmq-prod, qdrant-prod)
```

> **Dev는 자동 배포(`--sync-policy automated`)**, **Prod는 수동 Sync**가 안전하다.
> Prod는 ArgoCD UI에서 확인 후 "Sync" 버튼을 누르거나 `argocd app sync spring-boot-prod` 실행.

### 13-5. Sync 옵션 설명

| 옵션 | 의미 |
|------|------|
| `--sync-policy automated` | Git 변경 감지 시 자동 배포 (Dev용) |
| `--auto-prune` | Git에서 삭제된 리소스는 클러스터에서도 삭제 |
| `--self-heal` | 누군가 kubectl로 직접 수정해도 Git 상태로 자동 복구 |
| (미지정) | 수동 Sync — UI/CLI에서 직접 트리거 (Prod용) |

### 13-6. ArgoCD 상태 확인

```bash
# 전체 Application 목록
argocd app list

# 기대 결과:
# NAME               CLUSTER                         NAMESPACE    STATUS  HEALTH   SYNCPOLICY
# spring-boot-dev    https://kubernetes.default.svc  village-app  Synced  Healthy  Auto
# fastapi-dev        https://kubernetes.default.svc  village-app  Synced  Healthy  Auto
# nextjs-dev         https://kubernetes.default.svc  village-app  Synced  Healthy  Auto
# rabbitmq-dev       https://kubernetes.default.svc  village-data Synced  Healthy  Auto
# qdrant-dev         https://kubernetes.default.svc  village-data Synced  Healthy  Auto
# spring-boot-prod   https://kubernetes.default.svc  village-app  Synced  Healthy  <none>

# 특정 앱 상세
argocd app get spring-boot-dev

# ArgoCD UI 접속 (포트포워딩)
kubectl port-forward svc/argocd-server -n village-ops 8443:443
# 브라우저에서 https://localhost:8443 접속
```

---

## Phase 14: CI/CD 전체 검증

### 14-1. End-to-End 테스트 (Dev)

전체 파이프라인이 동작하는지 확인한다.

```bash
# 1. 앱 레포에 사소한 변경 push
cd ~/billage-be
echo "// test" >> src/main/resources/application.yml
git add . && git commit -m "test: ci/cd pipeline" && git push origin dev

# 2. GitHub Actions 확인
# billage-be 레포 → Actions 탭 → workflow 성공 확인

# 3. manifests 레포 커밋 확인
cd ~/billage-k8s-manifests
git pull
git log --oneline -1
# 기대: "chore(spring-boot): update image tag to dev-xxxxxxx"

# 4. ArgoCD 상태 확인
argocd app get spring-boot-dev
# STATUS: Synced, HEALTH: Healthy

# 5. 실제 Pod이 새 이미지로 교체되었는지
kubectl get pods -n village-app -l app=spring-boot -o jsonpath='{.items[*].spec.containers[*].image}'
# 기대: ...billage-be:dev-xxxxxxx (새 태그)
```

### 14-2. 전체 CI/CD 흐름 요약

```
개발자가 앱 레포(billage-be)에 push
          │
          ▼
┌─────────────────────────────┐
│  GitHub Actions (앱 레포)    │
│  1. 코드 checkout            │
│  2. 테스트 실행              │
│  3. Docker build             │
│  4. ECR push (dev-a1b2c3d)   │
│  5. manifests 레포 checkout  │
│  6. values tag 변경 & push   │
└──────────┬──────────────────┘
           │
           ▼
┌─────────────────────────────┐
│  billage-k8s-manifests      │
│  values-dev.yaml 변경됨      │
│    tag: "dev-a1b2c3d"       │
└──────────┬──────────────────┘
           │
           ▼  (3분 이내 자동 감지)
┌─────────────────────────────┐
│  ArgoCD                      │
│  1. Git diff 감지            │
│  2. helm upgrade 실행        │
│  3. Sync 완료                │
└──────────┬──────────────────┘
           │
           ▼
┌─────────────────────────────┐
│  K8s 클러스터                │
│  1. 새 Pod 생성 (새 이미지)   │
│  2. 헬스체크 통과             │
│  3. 구 Pod 종료              │
│  4. 롤링 업데이트 완료        │
└─────────────────────────────┘
```

### 14-3. Prod 배포 절차

Prod는 자동 배포하지 않는다. 수동 승인 후 배포한다.

```bash
# 1. main 브랜치에 merge (또는 push)
#    → CI가 ECR push + manifests values-prod.yaml 업데이트

# 2. ArgoCD에서 OutOfSync 상태 확인
argocd app get spring-boot-prod
# STATUS: OutOfSync ← Git과 클러스터가 다르다는 의미

# 3. 변경 내용 미리보기
argocd app diff spring-boot-prod

# 4. 배포 승인
argocd app sync spring-boot-prod

# 5. 배포 상태 확인
argocd app get spring-boot-prod
# STATUS: Synced, HEALTH: Healthy
```

### 14-4. 롤백 (문제 발생 시)

```bash
# 방법 1: ArgoCD에서 이전 버전으로 롤백
argocd app history spring-boot-prod
# ID  DATE                 REVISION
# 1   2026-03-17 10:00:00  abc1234
# 2   2026-03-17 14:00:00  def5678  ← 현재 (문제 발생)

argocd app rollback spring-boot-prod 1

# 방법 2: Git revert (권장 — GitOps 원칙 유지)
cd billage-k8s-manifests
git revert HEAD
git push
# → ArgoCD가 자동으로 이전 이미지 태그로 재배포
```

### 14-5. CI/CD 최종 체크리스트

| 항목 | 확인 방법 | 기대 결과 |
|------|----------|----------|
| PAT 등록 | 앱 레포 Settings → Secrets | `MANIFEST_REPO_PAT` 존재 |
| ECR 이미지 태그 | `aws ecr describe-images` | `dev-{sha}` 또는 `prod-{sha}` |
| Manifests 자동 커밋 | `git log` | CI bot 커밋 존재 |
| ArgoCD App 등록 | `argocd app list` | 모든 앱 Synced |
| Dev 자동 배포 | 앱 push → Pod 이미지 확인 | 새 태그로 교체됨 |
| Prod 수동 Sync | `argocd app get *-prod` | OutOfSync 대기 → Sync 후 Healthy |
| 롤백 | `argocd app rollback` 또는 `git revert` | 이전 버전 복구 |

---

## 부록: 주요 리소스 레퍼런스

### 네임스페이스 매핑

| 네임스페이스 | 서비스 |
|-------------|--------|
| `village-app` | spring-boot, nextjs, fastapi |
| `village-data` | rabbitmq, qdrant |
| `village-edge` | ingress controller (예정) |
| `village-ops` | ArgoCD, Prometheus, Grafana (예정) |

### 서비스 포트 & DNS

| 서비스 | 포트 | 클러스터 내부 DNS |
|--------|------|------------------|
| Spring Boot | 8080 | `spring-boot.village-app.svc.cluster.local` |
| Next.js | 3000 | `nextjs.village-app.svc.cluster.local` |
| FastAPI | 5000 | `fastapi.village-app.svc.cluster.local` |
| RabbitMQ (AMQP) | 5672 | `rabbitmq.village-data.svc.cluster.local` |
| RabbitMQ (Mgmt) | 15672 | 동일 |
| Qdrant (REST) | 6333 | `qdrant.village-data.svc.cluster.local` |
| Qdrant (gRPC) | 6334 | 동일 |

### 필수 노드 라벨 & Taint

| 노드 유형 | 라벨 | Taint |
|-----------|------|-------|
| App Worker | `node-role=app` | 없음 |
| Data Worker | `node-role=data` | `dedicated=data:NoSchedule` |

### Secret 이름 & 키

| Secret 이름 | 네임스페이스 | 키 목록 |
|-------------|-------------|--------|
| `spring-boot-secret` | village-app | db-url, db-username, db-password, jwt-secret, cors-allowed, ai-base-url |
| `fastapi-secret` | village-app | qdrant-url, db-url |
| `rabbitmq-secret` | village-data | erlang-cookie |

### Helm 릴리스 관리 명령어

```bash
# 설치된 릴리스 목록
helm list -A

# 릴리스 상태 확인
helm status spring-boot -n village-app

# 업그레이드 (values 변경 후)
helm upgrade spring-boot ./charts/spring-boot \
  -n village-app \
  -f ./charts/spring-boot/values-${ENV}.yaml

# 롤백 (이전 버전으로)
helm rollback spring-boot 1 -n village-app

# 삭제
helm uninstall spring-boot -n village-app

# 삭제 시 PVC는 자동 삭제되지 않는다 (데이터 보호)
# 수동 삭제 필요 시:
kubectl delete pvc data-rabbitmq-0 data-rabbitmq-1 data-rabbitmq-2 -n village-data
```
