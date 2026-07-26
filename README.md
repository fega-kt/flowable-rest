# Approval App

Hệ thống quản lý phê duyệt — Flowable + NestJS + React + Supabase.

## Stack

- **Flowable REST** — BPMN engine (Docker)
- **NestJS** — Backend API
- **React + bpmn-js** — Frontend
- **Supabase** — PostgreSQL + Auth + Realtime

## Cấu trúc DB

```text
zhizhu (Supabase DB)
├── public/     ← bảng app (approval_requests, profiles, task_actions...)
└── flowable/   ← bảng Flowable tự tạo (~50 bảng ACT_*)
```

## Bắt đầu

### 1. Tạo schema flowable trong Supabase

Vào Supabase SQL Editor, chọn DB `zhizhu`, chạy:

```sql
CREATE SCHEMA IF NOT EXISTS flowable;
```

### 2. Cấu hình env

```bash
cp .env.example .env
```

Điền vào `.env`:

| Biến | Mô tả |
| ---- | ----- |
| `SUPABASE_DB_URL` | Connection string JDBC từ Supabase Dashboard → Settings → Database. Đổi database thành `zhizhu` |
| `SUPABASE_DB_USER` | Thường là `postgres` |
| `SUPABASE_DB_PASSWORD` | Password Supabase |
| `FLOWABLE_ADMIN_USER` | Tên admin Flowable (mặc định: `admin`) |
| `FLOWABLE_ADMIN_PASSWORD` | Password mạnh — NestJS dùng để gọi Flowable REST API |
| `FLOWABLE_ADMIN_EMAIL` | Email admin Flowable |

### 3. Chạy Flowable

Image được build & push lên GHCR qua CI (xem [Deploy qua GitHub Actions](#deploy-qua-github-actions)), `docker-compose.yml` không tự build tại chỗ nữa — cần login GHCR trước rồi pull:

```bash
docker login ghcr.io -u <github-username>   # dùng PAT có quyền read:packages
docker compose pull
docker compose up
```

Cách khác — dùng `dev.sh` (tự fetch secrets từ Vault rồi ghi `.env`):

```bash
bash dev.sh          # docker compose pull + up (chạy trong container)
bash dev.sh --mvn    # mvn spring-boot:run (hot reload, không cần Docker)
```

Chờ log xuất hiện:

```text
Started FlowableRestApplication in ... seconds
```

Container có healthcheck tự động gọi `/flowable-rest/service/repository/deployments` mỗi 30 giây (timeout 10s, tối đa 5 lần retry, chờ 60s khởi động).

### 4. Kiểm tra

```bash
curl -u admin:your-password http://localhost:8080/flowable-rest/service/repository/deployments
```

Kết quả mong đợi:

```json
{ "data": [], "total": 0, "start": 0, "size": 0 }
```

## Flowable REST API endpoints hay dùng

| Method | Endpoint                              | Mô tả                    |
| ------ | ------------------------------------- | ------------------------ |
| POST   | `/repository/deployments`             | Deploy BPMN file         |
| GET    | `/repository/process-definitions`     | List process definitions |
| POST   | `/runtime/process-instances`          | Start process instance   |
| GET    | `/runtime/tasks`                      | Lấy danh sách task       |
| POST   | `/runtime/tasks/:id`                  | Complete / claim task    |
| GET    | `/history/historic-process-instances` | Lịch sử process          |

## Deploy qua GitHub Actions

Workflow `.github/workflows/deploy.yml` chạy khi push vào `main` (hoặc trigger thủ công `workflow_dispatch`):

1. **Build & Push** — build image từ `flowable-server/Dockerfile`, push lên `ghcr.io/<owner>/<repo>-flowable-server` (tag `latest` + `sha-<commit>`)
2. **Deploy** — SSH vào server qua Cloudflare Access tunnel, chạy `up.sh` non-interactive để pull image mới và `docker compose up -d`

### Secrets cần thêm ở GitHub (Settings → Secrets and variables → Actions)

| Secret | Mô tả |
| ------ | ----- |
| `SERVER_SSH_KEY` | Private key SSH để đăng nhập server |
| `SERVER_HOST` | Hostname server (qua Cloudflare Access tunnel) |
| `SERVER_USER` | User SSH trên server |
| `SERVER_DEPLOY_PATH` | Đường dẫn thư mục chứa repo này trên server |
| `CF_ACCESS_CLIENT_ID` | Cloudflare Access service token — client ID |
| `CF_ACCESS_CLIENT_SECRET` | Cloudflare Access service token — client secret |
| `GHCR_PAT` | Personal Access Token quyền `read:packages`, để server login pull image từ GHCR |
| `VAULT_ADDR` | Địa chỉ Vault, ví dụ `https://vault.zhizhu.online` |
| `VAULT_TOKEN` | Vault token (nên tạo token riêng cho CI, policy read-only vào path production) |
| `VAULT_SECRET_PATH` | Path chứa secrets production trong Vault, ví dụ `secret/flowable-server-prod` |

`GITHUB_TOKEN` (build & push lên GHCR) đã có sẵn tự động, không cần tạo thêm.

Lưu ý: GHCR package mặc định **private** — máy dev chạy `docker compose pull` cũng cần `docker login ghcr.io` bằng token có quyền `read:packages`, hoặc chuyển package sang public trong GitHub → Packages settings sau lần build đầu tiên.
