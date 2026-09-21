# Kubernetes Microservices Lab

CKAD (Certified Kubernetes Application Developer) sınavı ve genel Kubernetes pratiği için hazırladigim 1-node Minikube cluster. Gerçek bir 3-tier **SynergyChat** uygulaması üzerinden Deployment, Service, ConfigMap, Multi-container Pod, Volume, PVC, HPA ve Gateway API kavramlarını çalışmayı hedefler.

Uygulama iki yolla kurulabilir:

- **Helm chart ile** → `helm-chart/` (önerilen, tek komutla kurulum)
- **Raw YAML ile** → kök dizindeki manifest dosyaları (kaynağı görme ve tek tek apply etme pratiği için)

---

## Mimari Genel Bakış

```
Client (browser / curl)
  │
  ▼
┌──────────────────────────────────────────────────┐
│  app-gateway (Gateway API - Envoy)  :80          │
│  ├─ synchat.internal    → web-httproute          │
│  └─ synchatapi.internal → api-httproute          │
└─────────────┬───────────────────────┬────────────┘
              │                       │
              ▼                       ▼
      web-service:80          api-service:80
              │                       │
              ▼                       ▼
  synergychat-web (HPA:1-4)  synergychat-api (x1)
                                    │
                              ┌─────┴─────┐
                              │ PVC: 1Gi  │
                              │ /persist  │
                              └─────┬─────┘
                                    │ (cross-namespace)
                                    ▼
                           crawler-service:80
                           (namespace: crawler)
                                    │
                                    ▼
                          synergychat-crawler (x1 pod)
                          ┌── crawler-1 :8080 ──┐
                          ├── crawler-2 :8081 ──┤ emptyDir volume
                          └── crawler-3 :8082 ──┘   (/cache)

Test Workloads (default namespace):
  synergychat-testcpu (10m CPU limit) ← testcpu-hpa
  synergychat-testram (256Mi mem limit) ← testram-configmap (MEGABYTES)
```

**Trafik akışı:**

1. Client, `synchat.internal` veya `synchatapi.internal` domain'ine istek gönderir
2. Envoy Gateway (L7) hostname'e göre `HTTPRoute` ile doğru Service'e yönlendirir
3. Service, `selector` ile eşleşen Pod'lara trafiği iletir (`port:80 → targetPort:8080`)
4. Web frontend, `API_URL=http://synchatapi.internal` ile API'ye erişir
5. API Pod'u PVC ile mount edilen `/persist` dizininden veri okur/yazar (`/persist/db.json`)
6. API, `CRAWLER_BASE_URL=http://crawler-service.crawler.svc.cluster.local` ile crawler namespace'indeki servise erişir
7. Crawler Pod'u 3 sidecar container içerir; `emptyDir` volume üzerinden `/cache` dizinini paylaşır
8. Web deployment HPA tarafından yönetilir, CPU kullanımına göre 1-4 replica arasında ölçeklenir

---

## Kurulum

### Ön Koşullar

| Araç | Kurulum |
|---|---|
| **Minikube** | `curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64 && sudo install minikube-linux-amd64 /usr/local/bin/minikube` |
| **kubectl** | `curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" && sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl` |
| **Helm** (yalnızca Helm yöntemi) | `curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \| bash` |
| **Envoy Gateway** | Aşağıda |

### 1. Minikube Başlat

```bash
minikube start --driver=docker --nodes=1
```

### 2. Envoy Gateway Kur

```bash
helm install eg oci://docker.io/envoyproxy/gateway-helm --version v1.2.0 -n envoy-gateway-system --create-namespace
```

> GatewayClass hazır olmadan uygulamaları apply etmeyin. Kontrol:
> ```bash
> kubectl get gatewayclass app-gatewayclass -o wide
> ```
> `ACCEPTED` durumunda olmalı.

### 3A. Yöntem 1 - Helm Chart ile Kurulum

```bash
# Crawler namespace'i (chart release namespace'inden farklıysa)
kubectl create namespace crawler

# Chart'ı kur
helm install synergychat ./helm-chart

# Test workload'ları olmadan kurmak istersen
helm install synergychat ./helm-chart --set testcpu.enabled=false --set testram.enabled=false
```

Değerleri özelleştirmek için:

```bash
helm install synergychat ./helm-chart \
  --set crawler.namespace=crawler \
  --set web.hpa.maxReplicas=6 \
  --set gateway.hostnames.web=benim.site.local
```

Yaygın `--set` anahtarları:

| Değer | Varsayılan | Açıklama |
|---|---|---|
| `crawler.namespace` | `crawler` | Crawler kaynaklarının çalıştığı namespace |
| `testcpu.enabled` / `testram.enabled` | `true` | Test workload'larını kapatma |
| `web.hpa.minReplicas` / `maxReplicas` | `1` / `4` | Web HPA sınırları |
| `api.pvc.size` | `1Gi` | API PVC boyutu |
| `gateway.hostnames.web` / `api` | `synchat.internal` / `synchatapi.internal` | HTTPRoute hostname'leri |

Güncelleme ve kaldırma:

```bash
helm upgrade synergychat ./helm-chart   # values değişikliği sonrası
helm uninstall synergychat              # kaldırma (crawler ns'dekiler dahil)
```

> **Not:** Crawler kaynakları `crawler` namespace'inde, diğer kaynaklar release namespace'inde (varsayılan `default`) oluşur. Helm tek release içinde birden fazla namespace'i yönetebilir; ancak `helm uninstall` cross-namespace kaynakları da temizler.

### 3B. Yöntem 2 - Raw YAML ile Kurulum

Kaynakları uygulama sırası önemlidir - ConfigMap'ler, PVC ve Gateway kaynakları önce oluşturulmalıdır:

```bash
# Namespace
kubectl create namespace crawler

# 1. ConfigMaps (env referansları önce olmalı)
kubectl apply -f api-configmap.yaml
kubectl apply -f crawler-configmap.yaml -n crawler
kubectl apply -f web-configmap.yaml
kubectl apply -f testram-configmap.yaml

# 2. PVC (Deployment'tan önce)
kubectl apply -f api-pvc.yaml

# 3. Altyapı - GatewayClass + Gateway
kubectl apply -f app-gatewayclass.yaml
kubectl apply -f app-gateway.yaml

# 4. Deployments
kubectl apply -f api-deployment.yaml
kubectl apply -f crawler-deployment.yaml -n crawler
kubectl apply -f web-deployment.yaml
kubectl apply -f testcpu-deployment.yaml
kubectl apply -f testram-deployment.yaml

# 5. Services
kubectl apply -f api-service.yaml
kubectl apply -f crawler-service.yaml -n crawler
kubectl apply -f web-service.yaml

# 6. HPA'lar (Deployment'lar hazır olduktan sonra)
kubectl apply -f web-hpa.yaml
kubectl apply -f testcpu-hpa.yaml

# 7. HTTPRoutes (Gateway hazır olduktan sonra)
kubectl apply -f api-httproute.yaml
kubectl apply -f web-httproute.yaml
```

> **Tek seferde apply (hızlı yol):**
> ```bash
> kubectl apply -f .
> kubectl apply -f crawler-configmap.yaml -n crawler
> kubectl apply -f crawler-deployment.yaml -n crawler
> kubectl apply -f crawler-service.yaml -n crawler
> ```
> Kubernetes bağımlılıkları kendi yönetir; ilk çalıştırmada bazı Pod'lar ConfigMap henüz oluşmadığı için `ContainerCreating` durumunda kalabilir ve kısa sürede kendiliğinden düzelir.

### 4. Tunnel Başlat

Minikube üzerinde Gateway API'nin external IP alabilmesi için:

```bash
# Ayrı bir terminalde çalıştır
minikube tunnel
```

Çalışmazsa:

```bash
minikube tunnel --cleanup
```

### 5. `/etc/hosts` Güncelle

```bash
MINIKUBE_IP=$(minikube ip)
echo "$MINIKUBE_IP synchat.internal synchatapi.internal" | sudo tee -a /etc/hosts
```

> **Not:** `minikube tunnel` çalışıyorsa IP `127.0.0.1` olabilir. Bu durumda:
> ```bash
> echo "127.0.0.1 synchat.internal synchatapi.internal" | sudo tee -a /etc/hosts
> ```

---

## Test & Doğrulama

### Tüm Kaynakları Kontrol Et

```bash
kubectl get pods,svc,gateway,httproute,hpa,pvc -o wide
kubectl get pods,svc,configmap -n crawler
```

### Uygulamaya Erişim

```bash
curl http://synchat.internal   # Web frontend
curl http://synchatapi.internal # API backend
```

### PVC Durumu

```bash
kubectl get pvc
kubectl describe pvc synergychat-api-pvc
```

### HPA Durumu

```bash
kubectl get hpa
kubectl describe hpa web-hpa
kubectl describe hpa testcpu-hpa
```

### Resource Usage

```bash
kubectl top pods
kubectl top nodes
```

### Gateway Durumu

```bash
kubectl get gateway app-gateway -o wide
kubectl get httproute
```

### Pod Logları

```bash
# Tek container'lı Pod
kubectl logs -l app=synergychat-api

# Multi-container Pod - spesifik container
kubectl logs -l app=synergychat-crawler -n crawler -c synergychat-crawler-1
kubectl logs -l app=synergychat-crawler -n crawler -c synergychat-crawler-2
kubectl logs -l app=synergychat-crawler -n crawler -c synergychat-crawler-3
```

### Detaylı Pod Bilgisi

```bash
kubectl describe pod -l app=synergychat-api
kubectl describe pod -l app=synergychat-crawler -n crawler
kubectl describe pod -l app=synergychat-testcpu
kubectl describe pod -l app=synergychat-testram
```

---

## CKAD Konu Haritası

Bu projedeki YAML'ların CKAD müfredatındaki karşılığı:

| CKAD Konusu | Projedeki Karşılığı | İlgili Dosya(lar) |
|---|---|---|
| **Deployment & ReplicaSet** | web (HPA yönetiyor, min:1 max:4), api (1 replica), crawler (1 replica, ns: crawler) | `*-deployment.yaml` |
| **ConfigMap - envFrom** | Web deployment tüm anahtarları tek seferde alır | `web-deployment.yaml` → `web-configmap.yaml` |
| **ConfigMap - configMapKeyRef** | API, crawler ve testram her anahtarı tek tek referans eder | `api-deployment.yaml`, `crawler-deployment.yaml`, `testram-deployment.yaml` |
| **Services (ClusterIP)** | Varsayılan type, port→targetPort mapping | `*-service.yaml` |
| **Multi-container Pod (Sidecar)** | 3 crawler container aynı Pod içinde çalışır | `crawler-deployment.yaml` |
| **Volumes - emptyDir** | Sidecar'lar arasında `/cache` paylaşımı | `crawler-deployment.yaml` |
| **PersistentVolumeClaim** | API Pod'u PVC ile `/persist` dizinine kalıcı depolama mount eder | `api-pvc.yaml`, `api-deployment.yaml` |
| **Horizontal Pod Autoscaler (HPA)** | Web deployment CPU-based auto-scaling, testcpu HPA | `web-hpa.yaml`, `testcpu-hpa.yaml` |
| **Resource Limits (CPU/Memory)** | testcpu CPU limit (10m), testram memory limit (256Mi) | `testcpu-deployment.yaml`, `testram-deployment.yaml` |
| **Labels & Selectors** | Service→Pod eşleşmesi `app: synergychat-*` | tüm dosyalar |
| **Namespaces** | Crawler kaynakları ayrı namespace'de, cross-namespace Service erişimi | `crawler-*.yaml` |
| **Gateway API** | GatewayClass → Gateway → HTTPRoute zinciri, L7 routing | `app-gateway*.yaml`, `*-httproute.yaml` |
| **Container Image** | `image: latest` kullanımı, `docker.io` prefix farkı | `*-deployment.yaml` |

---

## CKAD Alıştırmaları

Her alıştırma, sınavda karşılaşabileceğin gerçek senaryolara dayanır. Önce kendin dene, sonra çözüme bak.

### Alıştırma 1 - Replica Scaling

```bash
kubectl scale deployment synergychat-web --replicas=5
kubectl get pods -l app=synergychat-web

# Geri al
kubectl scale deployment synergychat-web --replicas=3
```

### Alıştırma 2 - ConfigMap Güncelleme ve Pod Restart

```bash
kubectl edit configmap synergychat-api-configmap
# API_PORT: "8080" → "9090"

# ConfigMap güncellenince Pod otomatik yeniden başlamaz:
kubectl rollout restart deployment synergychat-api
kubectl rollout status deployment synergychat-api
```

### Alıştırma 3 - Sidecar Container Debug

```bash
# 2. sidecar'ın logları
kubectl logs -l app=synergychat-crawler -n crawler -c synergychat-crawler-2

# Tüm container'ların durumunu gör
kubectl get pods -l app=synergychat-crawler -n crawler -o jsonpath='{.items[*].status.containerStatuses[*].name}'
```

### Alıştırma 4 - Service Selector Kırma ve Onarma

```bash
kubectl edit svc api-service
# selector.app: synergychat-api → wrong-label

kubectl get endpoints api-service   # Endpoint'ler boş - trafik kesildi

kubectl edit svc api-service
# selector.app: wrong-label → synergychat-api

kubectl get endpoints api-service   # Endpoint'ler geri geldi
```

### Alıştırma 5 - Rolling Update

```bash
kubectl set image deployment/synergychat-web synergychat-web=bootdotdev/synergychat-web:v2
kubectl rollout status deployment/synergychat-web
kubectl rollout undo deployment/synergychat-web
kubectl rollout history deployment/synergychat-web
```

### Alıştırma 6 - Resource Limits Ekleme

```bash
kubectl edit deployment synergychat-api
```

Container spec'e eklenecek blok:

```yaml
resources:
  requests:
    cpu: "100m"
    memory: "128Mi"
  limits:
    cpu: "500m"
    memory: "256Mi"
```

`kubectl patch` alternatifi:

```bash
kubectl patch deployment synergychat-api --type json -p '[{"op":"add","path":"/spec/template/spec/containers/0/resources","value":{"requests":{"cpu":"100m","memory":"128Mi"},"limits":{"cpu":"500m","memory":"256Mi"}}}]'
```

### Alıştırma 7 - Node Affinity

```bash
kubectl get nodes --show-labels
kubectl edit deployment synergychat-web
```

```yaml
spec:
  template:
    spec:
      nodeSelector:
        kubernetes.io/os: linux
```

### Alıştırma 8 - Pod Silme ve Self-Healing

```bash
kubectl get pods -l app=synergychat-web
kubectl delete pod <pod-adı>
kubectl get pods -l app=synergychat-web   # Yeni Pod yeni bir adla oluşur
```

### Alıştırma 9 - HPA ile Otomatik Ölçeklendirme

```bash
kubectl get hpa web-hpa

# Web Pod'larını izle (ayrı terminal)
kubectl get pods -l app=synergychat-web -w

# Yük oluştur
kubectl run load-gen --image=busybox --rm -it --restart=Never -- /bin/sh -c "while true; do wget -qO- http://web-service:80; done"

# HPA'nın replica sayısını artırdığını/azalttığını izle
kubectl get hpa web-hpa -w
```

### Alıştırma 10 - PVC ve Veri Kalıcılığı

```bash
kubectl get pvc synergychat-api-pvc
kubectl exec <api-pod> -- ls /persist/

kubectl delete pod <api-pod>
kubectl get pods -l app=synergychat-api -w

# Yeni Pod'da veri hala mevcut olmalı
kubectl exec <yeni-api-pod> -- ls /persist/
```

### Alıştırma 11 - Memory Limits ve OOMKilled

```bash
kubectl edit configmap testram-configmap
# MEGABYTES: "10" → "500"

kubectl rollout restart deployment synergychat-testram
kubectl get pods -l app=synergychat-testram -w

kubectl describe pod -l app=synergychat-testram
# Last State: Terminated, Reason: OOMKilled

# Geri al
kubectl edit configmap testram-configmap
# MEGABYTES: "500" → "10"
kubectl rollout restart deployment synergychat-testram
```

### CKAD Cep Rehberi

Sınavda sıkça karşılaşılan tuzaklar - bu projedeki örneklerle:

| Konu | Özet | Proje Örneği |
|---|---|---|
| `envFrom` vs `configMapKeyRef` | `envFrom` tüm anahtarları, `configMapKeyRef` seçili anahtarı alır | web vs api deployment |
| `selector.matchLabels` ≡ `template.metadata.labels` | Eşleşmezse `kubectl apply` hata verir | tüm deployment'lar |
| Service `targetPort` | Pod'un dinlediği port (8080) ≠ Service portu (80) | `*-service.yaml` |
| `emptyDir` lifecycle | Container restart'ta korunur, Pod silinince gider | crawler `/cache` |
| PVC vs emptyDir | PVC Pod'dan bağımsız kalıcı, emptyDir geçici | api-pvc vs crawler cache |
| HPA + `kubectl scale` çakışması | HPA aktifken manuel scale yapma | web-hpa |
| OOMKilled | Memory limit aşımı → container öldürülür; CPU aşımı → throttle | testram vs testcpu |
| Cross-namespace DNS | `<svc>.<ns>.svc.cluster.local` | api → crawler-service |
| ConfigMap güncelleme | Pod otomatik restart olmaz → `rollout restart` gerekir | alıştırma 2 |
| Service selector debug | `kubectl get endpoints <svc>` boşsa selector yanlış | alıştırma 4 |

---

## Derinlemesine Konular

### Gateway API vs NodePort

Eski yaklaşım `old_configs/old-api-service.yaml` içinde: Service `type: NodePort` ile `nodePort: 30080` üzerinden dışarıya açılıyordu.

| | NodePort | Gateway API |
|---|---|---|
| Erişim | `<node-ip>:30000-32767` | Domain + standart port (80) |
| Domain-based routing | Yok - her servis ayrı port | HTTPRoute hostname ile |
| Path/header matching | Yok | `PathPrefix`, `Exact`, header, query param |
| Load balancing | L4 | L7 |
| Rol ayrımı | Tek Service nesnesi | GatewayClass/Gateway (infra) + HTTPRoute (app) |
| CKAD müfredatı | Klasik | v1.31+'da yer alıyor |

Bu projedeki zincir: `GatewayClass` (Envoy controller) → `Gateway` (:80 listener) → `HTTPRoute` (hostname → Service).

### Crawler Sidecar Pattern

`crawler-deployment.yaml` - tek Pod içinde 3 container:

1. **3 container, 1 Pod:** Aynı network namespace - `localhost` üzerinden iletişim
2. **emptyDir volume:** Tüm container'lar `/cache`'i paylaşır; Pod silinince veri gider
3. **ConfigMap ile port yönetimi:** Her container farklı port anahtarı kullanır (`CRAWLER_PORT`, `CRAWLER_PORT_2`, `CRAWLER_PORT_3`)
4. **Service yalnızca 1. container'ı hedefler:** `crawler-service` yalnızca `targetPort: 8080`'ı (crawler-1) expose eder
5. **Cross-namespace erişim:** API, `http://crawler-service.crawler.svc.cluster.local` üzerinden erişir

Faydalı komutlar:

```bash
kubectl logs -c <container-adı> ...     # spesifik container logu
kubectl exec -c <container-adı> ...     # spesifik container'da komut
```

Sidecar'lardan biri crash ederse Pod `CrashLoopBackOff` durumuna geçer.

### Persistent Volume Pattern

`api-pvc.yaml` + `api-deployment.yaml`:

```
Pod → volume(persistentVolumeClaim: synergychat-api-pvc) → container volumeMount(/persist)
```

| Özellik | PVC | emptyDir |
|---|---|---|
| Veri kalıcılığı | Pod silinse bile korunur | Pod silindiğinde kaybolur |
| Erişim modu | `ReadWriteOnce`, `ReadWriteMany` | Pod içi |
| Dinamik provisioning | StorageClass ile | Yok |
| Kullanım senaryosu | Veritabanı, dosya depolama | Geçici cache, shared buffer |

Notlar:

- Minikube'de `standard` StorageClass varsayılan olarak dinamik PV provisioning sağlar
- `ReadWriteOnce` tek node mount'u demektir - Minikube tek node olduğu için sorun değil

### HPA ve Resource Limits

**web-hpa.yaml** - CPU %50 hedefiyle 1-4 replica arası ölçekleme:

```yaml
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: synergychat-web
  minReplicas: 1
  maxReplicas: 4
  targetCPUUtilizationPercentage: 50
```

**testcpu** - `cpu: 10m` limiti (toplam CPU'nun %1'i). CPU limiti aşıldığında container öldürülmez, **throttle** edilir.

**testram** - `memory: 256Mi` limiti + ConfigMap'ten `MEGABYTES` değeri. `MEGABYTES: "500"` yapıldığında limit aşılır ve container kernel tarafından **OOMKilled** edilir.

```bash
# OOMKilled tespiti
kubectl get pods -l app=synergychat-testram -o jsonpath='{.items[*].status.containerStatuses[0].lastState.reason}'
kubectl describe pod -l app=synergychat-testram | grep -A5 "Last State"
```

---

## Bu Projede Olmayan CKAD Konuları

CKAD müfredatında yer alır ancak bu projede uygulamalı olarak bulunmaz:

| CKAD Konusu | Kısa Açıklama |
|---|---|
| **Secrets** | Hassas verileri base64 ile saklama, env/volume olarak mount etme |
| **Init Containers** | Ana container'dan önce çalışan hazırlık container'ları |
| **Probes (Liveness/Readiness/Startup)** | Pod sağlık kontrolü, `exec`/`httpGet`/`tcpSocket` tipleri |
| **NetworkPolicies** | Ingress/Egress kısıtlama, pod selector ile trafik izolasyonu |
| **Jobs & CronJobs** | Tek seferlik ve zamanlanmış batch işleri, `completions`, `parallelism` |
| **RBAC** | ServiceAccount, Role, RoleBinding, ClusterRole, ClusterRoleBinding |
| **Taints & Tolerations** | Node scheduling kısıtlama, `NoSchedule`/`NoExecute` efektleri |
| **Pod Affinity/Anti-Affinity** | Pod'ları aynı/farklı node'a yerleştirme stratejileri |
| **Security Context** | `runAsUser`, `fsGroup`, `capabilities`, `readOnlyRootFilesystem` |
| **StorageClass & PV** | Dinamik provisioning, accessModes, reclaimPolicy |
| **StatefulSet** | Stable network identity, ordered deploy/scale, volumeClaimTemplates |
| **DaemonSet** | Her node'da bir Pod çalıştırma (log agent, monitoring vb.) |
| **Ingress** | Gateway API dışındaki geleneksel L7 routing yöntemi |

---

## Sorun Giderme (Troubleshooting)

### Pod Durumları

```bash
kubectl get pods -o wide
kubectl get pods -n crawler -o wide
kubectl describe pod <pod-adı>
kubectl logs <pod-adı> --previous                      # CrashLoopBackOff önceki logları
kubectl describe pod <pod-adı> | grep -A5 "Last State" # OOMKilled tespiti
```

### Service Endpoint Kontrolü

```bash
kubectl get endpoints api-service
kubectl get endpoints web-service
kubectl get endpoints crawler-service -n crawler
# Endpoint boşsa → selector eşleşmesi yanlış
```

### PVC Debug

```bash
kubectl get pvc
kubectl describe pvc synergychat-api-pvc
kubectl get pv
```

### HPA Debug

```bash
kubectl get hpa
kubectl describe hpa web-hpa
kubectl get events --field-selector reason=SuccessfulRescale
```

### Gateway ve HTTPRoute Debug

```bash
kubectl describe gateway app-gateway
kubectl get httproute -o wide
kubectl get gateway app-gateway -o jsonpath='{.status.addresses[0].value}'
```

### ConfigMap ve Ortam Değişkenleri

```bash
kubectl get configmap synergychat-api-configmap -o yaml
kubectl get configmap testram-configmap -o yaml
kubectl exec <pod-adı> -- env | sort
```

### Network Debug

```bash
# Cluster içi DNS çözümleme
kubectl run tmp --image=busybox --rm -it --restart=Never -- nslookup api-service.default.svc.cluster.local

# Cross-namespace DNS çözümleme
kubectl run tmp --image=busybox --rm -it --restart=Never -- nslookup crawler-service.crawler.svc.cluster.local

# Service'e cluster içinden istek
kubectl run tmp --image=busybox --rm -it --restart=Never -- wget -qO- http://api-service:80

# Geçici debug Pod'u ile çoklu test
kubectl run tmp --image=busybox --rm -it --restart=Never -- sh
# Pod içinde:
#   wget -qO- http://web-service:80
#   wget -qO- http://crawler-service.crawler.svc.cluster.local:80
#   nslookup synchat.internal
```

---

## Dosya Yapısı

```
kubernetes-microservices-lab/
├── helm-chart/                     # Helm chart (önerilen kurulum yöntemi)
│   ├── Chart.yaml                  # Chart metadata (synergychat v0.1.0)
│   ├── values.yaml                 # Varsayılan değerler
│   └── templates/
│       ├── _helpers.tpl            # Helm helper'ları (isim, label)
│       ├── configmaps.yaml         # api, web, crawler, testram ConfigMap'leri
│       ├── deployments.yaml        # web, api, crawler (3 sidecar), testcpu, testram
│       ├── services.yaml           # api, web, crawler ClusterIP Service'leri
│       ├── pvc.yaml                # API PVC (1Gi, ReadWriteOnce)
│       ├── hpa.yaml                # web-hpa, testcpu-hpa
│       └── gateway.yaml            # GatewayClass, Gateway, HTTPRoute'lar
├── app-gatewayclass.yaml           # GatewayClass - Envoy controller tanımı
├── app-gateway.yaml                # Gateway - HTTP listener :80
├── api-configmap.yaml              # ConfigMap - API ortam değişkenleri
├── api-deployment.yaml             # Deployment - API backend (1 replica, PVC mount)
├── api-service.yaml                # Service - API ClusterIP 80→8080
├── api-httproute.yaml              # HTTPRoute - synchatapi.internal → API
├── api-pvc.yaml                    # PersistentVolumeClaim - API 1Gi kalıcı depolama
├── crawler-configmap.yaml          # ConfigMap - Crawler ortam değişkenleri (ns: crawler)
├── crawler-deployment.yaml         # Deployment - Crawler (3 sidecar + emptyDir, ns: crawler)
├── crawler-service.yaml            # Service - Crawler ClusterIP 80→8080 (ns: crawler)
├── web-configmap.yaml              # ConfigMap - Web ortam değişkenleri
├── web-deployment.yaml             # Deployment - Web frontend (HPA: min:1, max:4)
├── web-service.yaml                # Service - Web ClusterIP 80→8080
├── web-httproute.yaml              # HTTPRoute - synchat.internal → Web
├── web-hpa.yaml                    # HorizontalPodAutoscaler - Web CPU-based scaling
├── testcpu-deployment.yaml         # Deployment - CPU stress test (10m CPU limit)
├── testcpu-hpa.yaml                # HorizontalPodAutoscaler - CPU test auto-scaling
├── testram-configmap.yaml          # ConfigMap - RAM test bellek miktarı
├── testram-deployment.yaml         # Deployment - RAM stress test (256Mi memory limit)
├── old_configs/                    # Eski yapılandırmalar (arşiv)
│   ├── old-api-service.yaml        # NodePort:30080 (Gateway API öncesi)
│   ├── old-emptydir-crawler-deployment.yaml
│   ├── old-emptydir-crawler-configmap.yaml
│   ├── web-deployment.yaml         # Cluster dump (canlı çıktı, arşiv)
│   └── 3-replicas-web-deployment.yaml  # 3 replikalı web deployment (HPA öncesi)
└── README.md
```

---

## Kaynaklar

- [Kubernetes Gateway API Dokümantasyonu](https://gateway-api.sigs.k8s.io/)
- [Envoy Gateway Kurulum Rehberi](https://gateway.envoyproxy.io/)
- [Helm Dokümantasyonu](https://helm.sh/docs/)
- [CNCF CKAD Sınav Müfredatı](https://github.com/cncf/curriculum)
- [Kubernetes Resmi Dokümantasyon](https://kubernetes.io/docs/)
- [Kubernetes HPA Dokümantasyonu](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/)
- [Kubernetes Persistent Volumes](https://kubernetes.io/docs/concepts/storage/persistent-volumes/)
