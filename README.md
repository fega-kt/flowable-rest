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

```bash
docker-compose up
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
