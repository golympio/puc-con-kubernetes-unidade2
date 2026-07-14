# guess_game no Kubernetes (K3D) — CON Unidade 2

Reimplementação, em **Kubernetes (K3D)**, do sistema `guess_game` entregue na Unidade 1 com
Docker Compose. O comportamento funcional é **preservado** — o código-fonte do `guess_game`
(backend Flask e frontend React) **não** foi alterado. A única adaptação é de implantação: o
`upstream` do NGINX passa a apontar para o **Service** do backend.

> **Este README é autossuficiente.** Seguindo os passos abaixo **em ordem**, numa máquina limpa
> (com Docker), o sistema sobe do zero — clone, criação do cluster, deploy, testes e remoção —
> **sem nenhuma correção manual**. As imagens já estão **publicadas no Docker Hub**; **não é
> preciso reconstruí-las** (sem `docker build`, sem `k3d image import`, sem `imagePullSecrets`).

---

## 1. Componentes instalados

| Componente | Objeto Kubernetes | Imagem | Porta | Papel |
|---|---|---|---|---|
| Frontend / NGINX | `Deployment` + `Service` `con-guess-frontend` | `golympio/con-guess-frontend:v1.0.0` | 80 | Serve o build React e faz proxy reverso/LB para o backend |
| Backend / Flask | `Deployment` + `Service` `con-guess-backend` + **`HPA`** | `golympio/con-guess-backend:v1.0.0` | 5000 | API do jogo (`POST /create`, `POST /guess/<id>`, `GET /health`) |
| Banco / PostgreSQL | `StatefulSet` `con-guess-db` + **PVC** + 2 `Service` | `postgres:16.4-alpine` | 5432 | Persistência do estado do jogo |
| Configuração | `ConfigMap` `con-guess-config` + `Secret` `con-guess-secret` | — | — | Variáveis `FLASK_*` / `POSTGRES_*` |

**Services criados:** `con-guess-frontend` (ClusterIP :80), `con-guess-backend` (ClusterIP :5000),
`con-guess-db` (ClusterIP :5432, usado pelo backend) e `con-guess-db-headless`
(Headless, `clusterIP: None`, **governante** do StatefulSet).

**Comunicação interna (DNS do cluster):** frontend → `con-guess-backend:5000`;
backend → `con-guess-db:5432`.

### Imagens e tags

- `golympio/con-guess-backend:v1.0.0` — backend Flask **inalterado**.
- `golympio/con-guess-frontend:v1.0.0` — NGINX com `upstream` → Service do backend.
- `postgres:16.4-alpine` — imagem **oficial**, reusada diretamente.

Arquitetura `linux/amd64`, tags **versionadas** (SemVer) — **nunca** `latest`. Repositórios
**públicos** no Docker Hub `golympio`.

---

## 2. Pré-requisitos e instalação

Você precisa de **Docker**, **k3d** e **kubectl**. Na **VM/OVA do curso** o k3d já vem instalado.
Numa máquina Linux/WSL2 limpa, instale o que faltar:

```bash
# Docker: siga https://docs.docker.com/engine/install/ (precisa estar em execução)
docker version

# k3d (K3S em contêineres Docker)
curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
k3d version

# kubectl
curl -Lo kubectl "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/
kubectl version --client
```

---

## 3. Clonar o repositório

```bash
git clone https://github.com/golympio/puc-con-kubernetes-unidade2.git
cd puc-con-kubernetes-unidade2
```

Todos os comandos a seguir são executados **a partir da raiz do repositório** (onde estão
`k8s/`, `docker/`, `guess_game/` e este `README.md`).

---

## 4. Criar o cluster K3D

```bash
k3d cluster create con-guess --image rancher/k3s:v1.30.6-k3s1 --wait
kubectl cluster-info
kubectl get nodes            # aguardar o node ficar Ready
```

O acesso ao frontend é por `kubectl port-forward` (passo 6) — **não** é necessário mapear portas
na criação do cluster.

> **Por que fixar `--image rancher/k3s:v1.30.6-k3s1`?** Essa versão do k3s funciona tanto em
> hosts **cgroup v1** quanto **cgroup v2**, garantindo que o cluster suba em qualquer máquina.
> O k3s mais recente (k8s ≥ 1.32) **recusa** hosts em cgroup v1 (comum no WSL2), com o erro
> `kubelet is configured to not run on a host using cgroup v1`. Fixar a imagem evita esse
> problema. Os objetos em `/k8s` são agnósticos de versão (`autoscaling/v2`, `apps/v1`,
> StorageClass `local-path`, Metrics Server built-in).

---

## 5. Instalar a aplicação

```bash
kubectl apply -f k8s/
```

O Kubernetes **baixa as imagens prontas** do Docker Hub. Nenhum build local é necessário.

Aguarde os componentes ficarem prontos:

```bash
kubectl rollout status statefulset/con-guess-db --timeout=120s
kubectl rollout status deployment/con-guess-backend --timeout=120s
kubectl rollout status deployment/con-guess-frontend --timeout=120s
```

> Os Pods do backend podem reiniciar 1–2 vezes enquanto o Postgres inicializa (o backend abre a
> conexão no startup). Isso é esperado e se estabiliza sozinho assim que o banco fica pronto.

---

## 6. Verificar

```bash
kubectl get pods
kubectl get deploy,statefulset,svc,pvc,hpa
```

Esperado:

- Pods `con-guess-backend-*` (2), `con-guess-frontend-*` (1) e `con-guess-db-0` em `Running`/`Ready`.
- `StatefulSet con-guess-db` com **PVC `Bound`** (`data-con-guess-db-0`).
- Services `con-guess-frontend`, `con-guess-backend`, `con-guess-db` e `con-guess-db-headless`.
- `HPA con-guess-backend` (`autoscaling/v2`, alvo CPU 60%, `min 2` / `max 5`).

Confirmar o Metrics Server ativo (necessário para o HPA):

```bash
kubectl top nodes
kubectl top pods
```

---

## 7. Acessar o frontend (port-forward)

Em um terminal (deixe rodando):

```bash
kubectl port-forward svc/con-guess-frontend 8080:80
```

Abra <http://localhost:8080> no navegador — a página do jogo carrega.

---

## 8. Validar o fluxo ponta-a-ponta

As chamadas passam pelo frontend/NGINX → Service do backend → Postgres. Os payloads seguem o
**código real** da API (`/create` usa `password`; `/guess/<id>` usa `guess`):

```bash
# Criar um jogo (guardar o game_id retornado):
curl -fsS -X POST http://localhost:8080/create \
  -H 'Content-Type: application/json' \
  -d '{"password":"banana"}'
# -> {"game_id":"XXXXXXXX"}

# Tentar adivinhar (use o game_id acima):
curl -fsS -X POST http://localhost:8080/guess/XXXXXXXX \
  -H 'Content-Type: application/json' \
  -d '{"guess":"a"}'
# -> {"result":"..."}

# Saude do backend:
curl -fsS http://localhost:8080/health   # -> {"status":"ok"}
```

---

## 9. Validar a persistência (StatefulSet + PVC)

O `game_id` criado antes deve **sobreviver** à recriação do Pod do banco:

```bash
# 1. Crie um jogo (passo 8) e guarde o game_id.
# 2. Recrie o Pod do banco (o StatefulSet o recria e reancora o mesmo PVC):
kubectl delete pod con-guess-db-0
kubectl rollout status statefulset/con-guess-db --timeout=120s

# 3. Consulte o game_id criado antes — o dado deve continuar valido (preservado no PVC):
curl -sS -X POST http://localhost:8080/guess/XXXXXXXX \
  -H 'Content-Type: application/json' -d '{"guess":"a"}'
#    -> {"result":"..."}  => PERSISTENCIA OK (game_id sobreviveu ao restart do banco)
#    -> {"error":"Game not found"}  => dado perdido (nao deve acontecer)
#    -> erro 500  => conexao psycopg2 obsoleta (limitacao do fonte, ver nota). Reconecte e repita:
#         kubectl rollout restart deploy/con-guess-backend
#         kubectl rollout status deployment/con-guess-backend --timeout=120s
#       depois repita o curl acima -> deve retornar {"result":"..."}
```

> **Limitação conhecida (do código-fonte, não é requisito da entrega):** o backend abre **uma
> única** conexão `psycopg2` na inicialização e **não reconecta**; `GET /health` confirma só o
> processo Flask, não o banco. Após reiniciar o Postgres, a conexão fica obsoleta
> (`InterfaceError: connection already closed`) e as rotas de negócio erram com o Pod ainda
> `Ready`. Como o **código-fonte não pode ser alterado** (regra do enunciado), a reconexão é feita
> **manualmente** com o `kubectl rollout restart deploy/con-guess-backend` do passo 3 — que
> reproduz o papel do `autoheal` da Unidade 1. **A persistência do dado (objetivo do teste) é
> comprovada:** o `game_id` continua válido no PVC após o banco reiniciar.

---

## 10. Teste de AutoScale (HPA scale-out / scale-in)

```bash
# Baseline (REPLICAS=2, utilizacao baixa):
kubectl get hpa

# Gerar carga de CPU contra o Service do backend por uma rota GET leve (sem efeito colateral),
# com varios loops paralelos para ultrapassar 60%:
kubectl run load --image=busybox --restart=Never -- /bin/sh -c \
  'for i in 1 2 3 4 5 6 7 8; do (while true; do wget -q -O- http://con-guess-backend:5000/health >/dev/null 2>&1; done) & done; wait'

# Observar o scale-out (replicas 2 -> ... -> 5):
kubectl get hpa -w
kubectl top pods

# Cessar a carga; apos a janela de estabilizacao (~5 min, padrao do HPA), as replicas voltam a 2:
kubectl delete pod load --now
kubectl get hpa -w
```

> Se um único loop não elevar a CPU acima de 60%, aumente a concorrência (mais loops ou um gerador
> como `hey`/`ab`) até comprovar por `kubectl top pods` / `kubectl get hpa`. Em teste local a carga
> acima levou a utilização a ~900% e o backend de **2 → 5** réplicas; após cessar, voltou a **2**.

---

## 11. Desativar o ambiente (após testes e validações)

Ao terminar de testar, encerre os recursos na ordem abaixo. Há duas opções: **pausar** (para
retomar depois sem recriar) ou **remover** por completo.

### 11.1 Encerrar o que foi aberto durante os testes

```bash
# Parar o port-forward: no terminal em que ele roda, tecle Ctrl+C.
# Remover o Pod gerador de carga do teste de HPA, se ainda existir:
kubectl delete pod load --ignore-not-found
```

### 11.2 Opção A — Pausar o cluster (retomável, não apaga nada)

```bash
k3d cluster stop con-guess     # desliga os conteineres; preserva objetos e o PVC (dados)
# ... para voltar mais tarde:
k3d cluster start con-guess    # sobe tudo de novo, com os dados intactos
```

### 11.3 Opção B — Remover por completo

```bash
# 1) Remover os objetos da aplicacao (opcional, pois o passo 2 ja apaga tudo):
kubectl delete -f k8s/

# 2) Remover o cluster inteiro (conteineres + volumes/PVC + rede + entrada no kubeconfig):
k3d cluster delete con-guess

# 3) Conferir que nada ficou:
k3d cluster list               # con-guess nao deve aparecer
docker ps -a | grep k3d-con-guess || echo "sem conteineres do cluster (OK)"
```

> `k3d cluster delete` também descarta o **PVC** (dados do jogo) — é a limpeza total. Se quiser
> preservar os dados para uma próxima sessão, use a **Opção A** (`stop`/`start`).

### 11.4 (Opcional) Liberar as imagens baixadas do host

```bash
docker image rm golympio/con-guess-backend:v1.0.0 golympio/con-guess-frontend:v1.0.0 postgres:16.4-alpine
```

> As imagens continuam **públicas no Docker Hub**; removê-las localmente só libera espaço — um novo
> `kubectl apply` volta a baixá-las.

---

## 12. Instalação alternativa via Helm (bônus)

Além dos manifestos crus (passo 5, **caminho obrigatório e suficiente**), a entrega inclui um
**Helm Chart** em `k8s/helm/con-guess/` que empacota **exatamente os mesmos objetos**.

```bash
# Instalar (equivale a `kubectl apply -f k8s/`):
helm install con-guess k8s/helm/con-guess

# Verificar o que seria aplicado, sem cluster:
helm template con-guess k8s/helm/con-guess
helm lint k8s/helm/con-guess

# Desinstalar:
helm uninstall con-guess
```

> O `kubectl apply -f k8s/` **não** é recursivo, então os arquivos do Chart em `k8s/helm/` **não**
> são aplicados pelo caminho cru — os dois caminhos não colidem. Escolha **um**: manifestos crus
> **ou** Helm.

---

## 13. Solução de problemas

| Sintoma | Causa | Correção |
|---|---|---|
| Cluster não sobe; log do server tem `kubelet is configured to not run on a host using cgroup v1` | host em cgroup v1 (comum no WSL2) + k3s recente | use o comando do passo 4 com `--image rancher/k3s:v1.30.6-k3s1` (já incluído) |
| `kubectl get hpa` mostra `cpu: <unknown>/60%` | Metrics Server ainda coletando / sem `requests.cpu` | aguarde ~30–60s; confirme `kubectl top pods`; o backend já define `requests.cpu` |
| Pods do backend com `RESTARTS` logo após o deploy | backend conecta ao Postgres no startup, antes do banco ficar `Ready` | é esperado; estabiliza sozinho — confira com `kubectl get pods` |
| Após recriar `con-guess-db-0`, rotas de negócio dão erro 500 | conexão `psycopg2` obsoleta (limitação do fonte, passo 9) | `kubectl rollout restart deploy/con-guess-backend` |

---

## 14. Segurança e credenciais

- **Nenhuma credencial real** (Docker Hub, GitHub, nuvem) está versionada neste repositório.
- O `Secret con-guess-secret` contém apenas a **credencial didática de laboratório**
  `secretpass` (senha descartável do Postgres local, herdada da U1), versionada por
  **reprodutibilidade** para o ambiente subir self-contained. Um `Secret` é base64 (codificação,
  não criptografia). Ver `k8s/secret.yaml`.
