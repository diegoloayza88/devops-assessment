# AI Q&A Platform on AWS EKS

A cloud-native AI question-answering service running on AWS EKS, built as a complete DevOps assessment. FastAPI proxies user questions to a HuggingFace inference server running `SmolLM2-135M-Instruct`, all deployed via Terraform + Helm

---

## Architecture

```
User → [SSM Tunnel] → FastAPI Service → HF Inference Server (SmolLM2-135M-Instruct)
                           ↑                        ↑
                      ECR (qa-service)       ECR (vllm-cpu)
                           ↑
                    EKS (ai-qa-dev)
                    Private VPC / 3 AZs
```

See `architecture/diagram.svg` for the full diagram.

---

## Repository Structure

```
assessment/
├── app/
│   ├── main.py                    # FastAPI app: POST /ask, GET /health
│   ├── requirements.txt
│   ├── Dockerfile                 # multi-stage, non-root, port 8080, linux/amd64
│   ├── .env.example
│   ├── tests/test_main.py         # 13 unit tests, inference server mocked
│   └── vllm-cpu/                  # Custom CPU inference server
│       ├── app.py                 # HuggingFace transformers, OpenAI-compatible API
│       ├── requirements.txt
│       └── Dockerfile
├── helm/
│   ├── fastapi-service/           # Deployment, Service, Ingress, HPA, ConfigMap, SA
│   └── vllm-service/              # Deployment, Service, PVC, PDB, SA
├── terraform/
│   ├── modules/
│   │   ├── vpc/                   # VPC, 3-AZ subnets, NAT GW, flow logs
│   │   ├── eks/                   # EKS cluster, node groups, OIDC, launch template
│   │   ├── ecr/                   # ECR repos (qa-service, vllm-cpu), lifecycle policies
│   │   ├── iam/                   # IRSA roles, GitHub OIDC
│   │   └── ssm-bastion/           # Private EC2, zero inbound SG, SSM only to be able to test and valida the eks cluster
│   └── environments/dev/          # main.tf, variables.tf, outputs.tf
├── architecture/diagram.svg
└── README.md
```

---

## Infrastructure

### Networking
- VPC `10.0.0.0/16` across 3 AZs
- Private subnets for EKS nodes and bastion
- Public subnets for NAT Gateway
- VPC flow logs enabled

### EKS Cluster (`ai-qa-dev`)
- Kubernetes 1.34
- Private endpoint only (`endpoint_public_access = false`)
- Authentication mode: `API_AND_CONFIG_MAP`
- Node group: `m6i.xlarge`
- Node OS: `AL2023_x86_64_STANDARD`
- EBS root volume: 50GB gp3 (via launch template)
- EBS CSI driver addon with IRSA role
- AWS Load Balancer Controller with IRSA role

### ECR Repositories
| Repository | Purpose |
|---|---|
| `qa-service` | FastAPI application |
| `vllm-cpu` | Custom HuggingFace CPU inference server |

### SSM Bastion
- `t3.micro` in private subnet
- Zero inbound security group rules
- SSM-only access (no SSH, no key pair)
- IMDSv2 enforced
- Encrypted root volume

---

## Services

### FastAPI Service (`qa-service`)
- **Port:** 8080
- **Endpoints:**
  - `GET /health` — liveness check, also pings inference server
  - `POST /ask` — accepts `{"question": "..."}`, returns answer + latency
- **Replicas:** 2
- **Image:** built `linux/amd64` (required for EKS x86 nodes)

### HuggingFace Inference Server (`vllm-cpu`)
- **Model:** `HuggingFaceTB/SmolLM2-135M-Instruct`
- **Port:** 8000
- **Endpoints:**
  - `GET /health`
  - `POST /v1/completions`
- **Runtime:** PyTorch CPU (`torch.float32`)
- **Model cache:** persisted via PVC (gp2-csi, 10Gi)
- **Resources:** 500m CPU request / 2000m limit, 2Gi–4Gi memory

> **Note:** vLLM (`vllm/vllm-openai`) was evaluated but has unstable CPU support across versions tested (v0.4.3–v0.6.3) due to CUDA initialization issues on non-GPU nodes. A lightweight custom server using HuggingFace `transformers` was used instead, exposing the same OpenAI-compatible `/v1/completions` API.

---

## Deployment

### Prerequisites
- AWS CLI configured with appropriate permissions
- `kubectl`, `helm`, `terraform`, `docker` installed
- Terraform Cloud workspace configured

### 1. Provision Infrastructure

```bash
cd terraform/environments/dev

# Set admin IAM ARN
export TF_VAR_eks_admin_arns='["arn:aws:iam::ACCOUNT_ID:user/YOUR_USER"]'

terraform init
terraform apply
```

### 2. Connect to EKS (SSM Tunnel)

```bash
BASTION_ID=$(terraform output -raw ssm_bastion_instance_id)
EKS_HOST=$(terraform output -raw cluster_endpoint | sed 's|https://||')

# Tab 1 — open tunnel
aws ssm start-session \
  --target "$BASTION_ID" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "{\"host\":[\"$EKS_HOST\"],\"portNumber\":[\"443\"],\"localPortNumber\":[\"8443\"]}"

# Tab 2 — redirect kubectl
kubectl config set-cluster "$(kubectl config current-context)" \
  --server=https://127.0.0.1:8443 \
  --insecure-skip-tls-verify=true

kubectl get nodes
```

### 3. Install Cluster Add-ons

```bash
export CLUSTER_NAME="ai-qa-dev"
export VPC_ID=$(aws eks describe-cluster --name "$CLUSTER_NAME" \
  --query "cluster.resourcesVpcConfig.vpcId" --output text)
export LBC_ROLE_ARN=$(terraform output -raw lbc_irsa_role_arn)

# AWS Load Balancer Controller
helm repo add eks https://aws.github.io/eks-charts && helm repo update

helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName="$CLUSTER_NAME" \
  --set serviceAccount.create=true \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="$LBC_ROLE_ARN" \
  --set vpcId="$VPC_ID" \
  --set region="us-east-1"

# EBS CSI Driver
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
OIDC_ID=$(aws eks describe-cluster --name "$CLUSTER_NAME" \
  --query "cluster.identity.oidc.issuer" --output text | cut -d'/' -f5)

aws iam create-role \
  --role-name AmazonEKS_EBS_CSI_DriverRole \
  --assume-role-policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Effect\": \"Allow\",
      \"Principal\": {\"Federated\": \"arn:aws:iam::${ACCOUNT_ID}:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/${OIDC_ID}\"},
      \"Action\": \"sts:AssumeRoleWithWebIdentity\",
      \"Condition\": {\"StringEquals\": {\"oidc.eks.us-east-1.amazonaws.com/id/${OIDC_ID}:sub\": \"system:serviceaccount:kube-system:ebs-csi-controller-sa\"}}
    }]
  }"

aws iam attach-role-policy \
  --role-name AmazonEKS_EBS_CSI_DriverRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy

aws eks create-addon \
  --cluster-name "$CLUSTER_NAME" \
  --addon-name aws-ebs-csi-driver \
  --service-account-role-arn "arn:aws:iam::${ACCOUNT_ID}:role/AmazonEKS_EBS_CSI_DriverRole"

# gp2 CSI StorageClass
kubectl apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp2-csi
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
parameters:
  type: gp2
  encrypted: "true"
EOF
```

### 4. Build & Push Images

```bash
export ECR_URL=$(terraform output -raw qa_service_ecr_url)
export VLLM_ECR_URL="$(echo $ECR_URL | cut -d'/' -f1)/vllm-cpu"

# FastAPI
aws ecr get-login-password --region us-east-1 \
  | docker login --username AWS --password-stdin "$ECR_URL"

docker build --platform linux/amd64 -t qa-service:latest app/
docker tag qa-service:latest "${ECR_URL}:latest"
docker push "${ECR_URL}:latest"

# Inference server
docker build --platform linux/amd64 -t vllm-cpu:latest app/vllm-cpu/
docker tag vllm-cpu:latest "${VLLM_ECR_URL}:latest"
docker push "${VLLM_ECR_URL}:latest"
```

### 5. Deploy Services

```bash
# Inference server
helm install vllm-service ./helm/vllm-service \
  --namespace ai-platform \
  --create-namespace \
  --set image.repository="$VLLM_ECR_URL" \
  --set image.tag="latest" \
  --set resources.requests.cpu="500m" \
  --set resources.requests.memory="2Gi" \
  --set resources.limits.cpu="2000m" \
  --set resources.limits.memory="4Gi" \
  --set "extraEnv[0].name=MODEL_NAME" \
  --set "extraEnv[0].value=HuggingFaceTB/SmolLM2-135M-Instruct" \
  --wait --timeout=10m

# FastAPI
helm install fastapi-service ./helm/fastapi-service \
  --namespace ai-platform \
  --set image.repository="$ECR_URL" \
  --set image.tag="latest" \
  --set ingress.enabled=false \
  --wait
```

### 6. Test

```bash
# Port-forward
kubectl port-forward svc/fastapi-service-fastapi-service 8080:80 -n ai-platform

# Health check
curl http://localhost:8080/health

# Ask a question
curl -X POST http://localhost:8080/ask \
  -H "Content-Type: application/json" \
  -d '{"question": "What is the capital of France?"}'
```

Expected response:
```json
{
  "question": "What is the capital of France?",
  "answer": "The capital of France is Paris.",
  "model": "HuggingFaceTB/SmolLM2-135M-Instruct",
  "latency_ms": 352.38
}
```

---

## Security

| Control | Implementation |
|---|---|
| Private EKS endpoint | `endpoint_public_access = false` |
| No SSH access | Bastion uses SSM only, no key pair |
| IMDSv2 enforced | `http_tokens = "required"` on bastion |
| Encrypted volumes | All EBS volumes encrypted at rest |
| Least-privilege IAM | IRSA roles scoped per service account |
| Node IAM | `AmazonEC2ContainerRegistryReadOnly` only |
| Container non-root | FastAPI runs as non-root user |
| Ingress disabled | Service accessible via port-forward / ALB only |

---

## Known Issues & Workarounds

| Issue | Workaround |
|---|---|
| vLLM CPU CUDA init failure | Replaced with custom HuggingFace transformers server |
| EKS private endpoint | SSM port-forward tunnel required for kubectl access |
| AL2 AMI deprecated in k8s 1.32 | Using `AL2023_x86_64_STANDARD` |
| Node disk full (5.5GB image) | EBS root volume increased to 50GB via launch template |
| gp3 StorageClass missing CSI driver | Created `gp2-csi` StorageClass using `ebs.csi.aws.com` |
| Docker image wrong arch (ARM64) | Build with `--platform linux/amd64` |

---

## Production Scaling Strategies for LLM Workloads on EKS

Scaling LLM inference differs fundamentally from scaling stateless APIs. Models are large, load times are slow, and GPU/CPU resources are expensive. The strategies below cover the full spectrum from node-level provisioning to request-level optimization.

---

### 1. Node Autoscaling — Karpenter over Cluster Autoscaler

For LLM workloads, **Karpenter** is the preferred autoscaler. Unlike Cluster Autoscaler which works against fixed node groups, Karpenter provisions the exact instance type the pending pod needs within seconds.

```yaml
# karpenter/nodepool.yaml
apiVersion: karpenter.sh/v1beta1
kind: NodePool
metadata:
  name: gpu-inference
spec:
  template:
    spec:
      requirements:
        - key: karpenter.k8s.aws/instance-family
          operator: In
          values: ["g5", "g4dn"]           # NVIDIA A10G / T4
        - key: karpenter.k8s.aws/instance-size
          operator: In
          values: ["xlarge", "2xlarge"]
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
      nodeClassRef:
        name: gpu-node-class
  limits:
    cpu: "64"
    memory: 256Gi
  disruption:
    consolidationPolicy: WhenEmpty          # reclaim idle GPU nodes aggressively
    consolidateAfter: 5m
```

**Key benefits for LLMs:**
- Scales to zero when no inference requests are pending — critical for cost control on expensive GPU instances
- Can mix Spot and On-Demand within the same pool (Spot for dev/batch, On-Demand for production SLAs)
- Provisions `p4d.24xlarge` for large models, `g4dn.xlarge` for smaller ones — all from a single NodePool

---

### 2. Horizontal Pod Autoscaling — KEDA over HPA

Standard HPA based on CPU/memory is a poor signal for LLM inference — a pod can be idle at 5% CPU while a queue of 500 requests builds up. **KEDA** (Kubernetes Event-Driven Autoscaling) scales on the metric that actually matters: queue depth or request rate.

```yaml
# keda/scaledobject-vllm.yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: vllm-service-scaler
  namespace: ai-platform
spec:
  scaleTargetRef:
    name: vllm-service
  minReplicaCount: 1
  maxReplicaCount: 10
  cooldownPeriod: 300                       # LLMs take time to load — avoid thrashing
  triggers:
    - type: prometheus
      metadata:
        serverAddress: http://prometheus:9090
        metricName: vllm_pending_requests
        threshold: "5"                      # scale up when >5 requests are queued per pod
        query: sum(vllm_num_requests_waiting)
```

**Scale-to-zero consideration:** LLMs have cold start times of 30s–5min depending on model size. For production, keep `minReplicaCount: 1` to avoid cold starts on customer-facing traffic. Use scale-to-zero only for batch/async workloads.

---

### 3. GPU Node Optimization — Time-Slicing and MIG

A single `g5.12xlarge` (4× A10G GPUs) running one vLLM pod wastes 75% of GPU capacity for a 7B model. Two strategies prevent this:

**GPU Time-Slicing** (small models, multiple tenants):
```yaml
# configmap for NVIDIA device plugin
apiVersion: v1
kind: ConfigMap
metadata:
  name: time-slicing-config
  namespace: kube-system
data:
  any: |-
    version: v1
    flags:
      migStrategy: none
    sharing:
      timeSlicing:
        resources:
          - name: nvidia.com/gpu
            replicas: 4             # 4 pods share one physical GPU
```

**NVIDIA MIG (Multi-Instance GPU)** (A100/H100, hard isolation):
```yaml
# Split an A100 into 7 × 10GB GPU instances
# Each vLLM pod gets a dedicated MIG slice with guaranteed memory bandwidth
resources:
  limits:
    nvidia.com/mig-1g.10gb: 1
```

Use MIG for production (guaranteed isolation, no noisy neighbor) and time-slicing for dev/test (cheaper, softer guarantees).

---

### 4. Model Serving Optimization — vLLM Production Configuration

For production vLLM deployments (GPU nodes), several settings dramatically improve throughput:

```yaml
# helm/vllm-service/values.yaml — production GPU config
args:
  - "--model"
  - "meta-llama/Llama-3-8B-Instruct"
  - "--device"
  - "cuda"
  - "--dtype"
  - "bfloat16"
  - "--tensor-parallel-size"              # split model across N GPUs
  - "2"
  - "--max-model-len"
  - "8192"
  - "--gpu-memory-utilization"
  - "0.90"
  - "--enable-prefix-caching"             # cache KV for repeated system prompts
  - "--max-num-seqs"
  - "256"                                 # concurrent sequences in flight
  - "--served-model-name"
  - "llama-3-8b"
```

**Continuous batching** (built into vLLM) is the most impactful throughput optimization — it fills idle GPU cycles with new requests mid-generation rather than waiting for the full batch to complete.

---

### 5. Multi-Model Serving — Inference Gateway Pattern

Running one pod per model is wasteful. For production with multiple models:

```
Client → AWS ALB → Inference Gateway (LiteLLM / OpenRouter) → vLLM Pod (Llama-3-8B)
                                                              → vLLM Pod (Mistral-7B)
                                                              → vLLM Pod (SmolLM2-135M)
```

**LiteLLM** as a gateway provides:
- Single OpenAI-compatible endpoint for all models
- Load balancing across model replicas
- Fallback routing (primary → backup model on timeout)
- Cost tracking per model/team

```yaml
# litellm config.yaml
model_list:
  - model_name: fast                       # cheap, fast responses
    litellm_params:
      model: openai/SmolLM2-135M-Instruct
      api_base: http://smollm-service:8000
  - model_name: balanced
    litellm_params:
      model: openai/llama-3-8b
      api_base: http://llama-service:8000
  - model_name: powerful
    litellm_params:
      model: openai/llama-3-70b
      api_base: http://llama-70b-service:8000
```

---

### 6. Spot Instance Strategy

GPU instances are expensive. Spot can cut costs by 60–70% with the right fault-tolerance setup:

```hcl
# terraform/modules/eks/main.tf
resource "aws_eks_node_group" "gpu_spot" {
  capacity_type  = "SPOT"
  instance_types = ["g5.xlarge", "g5.2xlarge", "g4dn.xlarge", "g4dn.2xlarge"]
  # multiple instance types = higher Spot availability

  labels = { "inference/capacity-type" = "spot" }
  taints = [{
    key    = "inference/spot"
    value  = "true"
    effect = "NO_SCHEDULE"
  }]
}
```

Pair with:
- **Spot interruption handler** (AWS Node Termination Handler) to drain pods gracefully on 2-minute interruption notice
- **PodDisruptionBudget** with `minAvailable: 1` so at least one replica stays up during drains
- **Checkpoint/resume** — vLLM supports saving KV cache state; in-flight requests can be retried on another pod

---

### 7. Observability for Scaling Decisions

Scaling decisions are only as good as the signals driving them. Key metrics to expose:

```yaml
# prometheus scrape config for vLLM
- job_name: vllm
  static_configs:
    - targets: ['vllm-service:8000']
  metrics_path: /metrics
```

| Metric | Alert Threshold | Scaling Action |
|---|---|---|
| `vllm_num_requests_waiting` | > 10 for 2m | Scale out pods |
| `vllm_gpu_cache_usage_perc` | > 85% | Scale out or reduce `max-num-seqs` |
| `vllm_time_to_first_token_seconds` | p99 > 2s | Scale out pods |
| `vllm_generation_tokens_per_second` | < 50 tok/s | Investigate GPU health |
| Node GPU utilization | < 20% for 30m | Karpenter consolidation |

---

### Summary

| Layer | Tool | When to Use |
|---|---|---|
| Node provisioning | Karpenter | Always — faster and more flexible than CAS |
| Pod scaling | KEDA + Prometheus | Queue-depth scaling for LLMs |
| GPU efficiency | MIG / Time-slicing | Multiple models or tenants per node |
| Model serving | vLLM continuous batching | GPU production workloads |
| Multi-model | LiteLLM gateway | 3+ models in production |
| Cost reduction | Spot + NTH | Dev, batch, and fault-tolerant workloads |
| Observability | Prometheus + Grafana | KEDA trigger source + capacity planning |

---

## Teardown

```bash
helm uninstall fastapi-service -n ai-platform
helm uninstall vllm-service -n ai-platform
helm uninstall aws-load-balancer-controller -n kube-system

cd terraform/environments/dev
terraform destroy
```