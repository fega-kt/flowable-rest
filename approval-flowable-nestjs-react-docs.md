# Tài liệu kỹ thuật: Hệ thống Quản lý Phê duyệt — React + NestJS + Flowable (server riêng)

> Phiên bản: 2.0
> Stack hiện có: **React** (FE), **NestJS** (BE chính, chứa business logic, xác thực người dùng qua **Supabase Auth**), **Flowable Engine** chạy như **server riêng** nhưng **team tự build/tuỳ biến được code Java** của server đó (đã xác nhận).
> Vì team tự build được Java cho Flowable, tài liệu này dùng **JavaDelegate/TaskListener chuẩn** làm cách tiếp cận chính (thay vì HTTP Task/External Worker như phương án dự phòng cho trường hợp server đóng hộp). Nguyên tắc xuyên suốt: **JavaDelegate chỉ là lớp mỏng gọi ngược vào NestJS** để lấy business logic — tránh việc logic nghiệp vụ bị viết trùng ở cả Java lẫn NestJS.

---

## Mục lục

1. [Kiến trúc tổng thể](#1-kiến-trúc-tổng-thể)
2. [Vì team build lại được Java cho Flowable server — chọn cách tiếp cận nào?](#2-vì-team-build-lại-được-java-cho-flowable-server--chọn-cách-tiếp-cận-nào)
3. [Cấu hình Flowable server cho production](#3-cấu-hình-flowable-server-cho-production)
4. [Thiết kế BPMN dùng JavaDelegate (lớp mỏng gọi NestJS)](#4-thiết-kế-bpmn-dùng-javadelegate-lớp-mỏng-gọi-nestjs)
5. [NestJS — Module tích hợp Flowable REST](#5-nestjs--module-tích-hợp-flowable-rest)
6. [Khi nào vẫn nên dùng HTTP Task / External Worker thay vì JavaDelegate](#6-khi-nào-vẫn-nên-dùng-http-task--external-worker-thay-vì-javadelegate)
7. [Đồng bộ trạng thái & database nghiệp vụ](#7-đồng-bộ-trạng-thái--database-nghiệp-vụ)
   - 7.1 Kiến trúc database: tách riêng với DB của Flowable
   - 7.5 Bảng nghiệp vụ mẫu (MikroORM)
   - 7.6 Ví dụ end-to-end: vòng đời dữ liệu 1 đơn xin nghỉ phép
8. [Bảo mật & phân quyền](#8-bảo-mật--phân-quyền)
9. [Frontend React — tích hợp qua NestJS](#9-frontend-react--tích-hợp-qua-nestjs)
10. [Xử lý lỗi, retry, idempotency](#10-xử-lý-lỗi-retry-idempotency)
11. [Testing](#11-testing)
12. [Triển khai production (Docker/Kubernetes)](#12-triển-khai-production-dockerkubernetes)
13. [Checklist production-readiness](#13-checklist-production-readiness)

---

## 1. Kiến trúc tổng thể

```
┌──────────────┐   Supabase JWT (access_token)  ┌───────────────────────┐
│   React SPA   │ ──────────────────────────────▶ │      Supabase Auth      │
└──────┬───────┘                                 └───────────────────────┘
       │ HTTPS + Bearer <Supabase access_token>
       ▼
┌──────────────────────────────────────────────────────────────┐
│                         NestJS (BFF + Business)                │
│  ┌───────────────┐  ┌────────────────┐  ┌────────────────────┐│
│  │ AuthModule     │  │ ApprovalModule  │  │ FlowableClientModule││
│  │ (Passport-JWT, │  │ (business logic)│  │ (axios → REST API)  ││
│  │  Supabase)     │  │                  │  │                      ││
│  └───────────────┘  └────────────────┘  └──────────┬─────────┘│
│  ┌───────────────────────────────────────────────────────────┐│
│  │ WorkerModule (External Worker polling, cron reconcile job) ││
│  └───────────────────────────────────────────────────────────┘│
└───────────────────────────┬─────────────────────┬──────────────┘
             REST (Basic Auth, internal network)   │ callback từ JavaDelegate/
                            ▼                       │ TaskListener
                ┌───────────────────────┐            │
                │   Flowable Server      │◀───────────┘
                │ (server riêng, team    │  callback qua JavaDelegate/
                │  tự build Java được)   │  TaskListener gọi NestJS
                └───────────┬────────────┘
                            ▼
                ┌───────────────────────┐        ┌───────────────────────┐
                │ PostgreSQL (flowable)  │        │ PostgreSQL (business)  │
                └───────────────────────┘        └───────────────────────┘
```

**Nguyên tắc cốt lõi**: Flowable server chỉ đóng vai trò **"cỗ máy trạng thái quy trình"** (process state machine). Mọi business logic (tính toán, gọi HRM/ERP, gửi email, xác định người duyệt, validate dữ liệu) đều nằm ở **NestJS**. BPMN chỉ điều phối luồng, gọi ngược vào NestJS khi cần xử lý.

---

## 2. Vì team build lại được Java cho Flowable server — chọn cách tiếp cận nào?

Vì server Flowable là do team tự build (có thể thêm Spring Bean, class Java tuỳ ý), toàn bộ cơ chế chuẩn của Flowable đều dùng được:

| Cơ chế Flowable                                                        | Dùng được                                                   | Ghi chú                                                                                                                                                       |
| ---------------------------------------------------------------------- | ----------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `flowable:delegateExpression="${bean}"` (JavaDelegate qua Spring Bean) | ✅ Có — **cách khuyến nghị chính**                          | Bean đăng ký trong chính Spring Boot app đóng gói Flowable                                                                                                    |
| `flowable:class="..."`                                                 | ✅ Có nhưng **không khuyến nghị**                           | Class không do Spring quản lý → khó test, khó inject dependency (HTTP client, config); nên luôn dùng `delegateExpression` trỏ tới Spring Bean thay vì `class` |
| TaskListener (`delegateExpression`) gán assignee động                  | ✅ Có                                                       | Java code gọi ngược NestJS lấy `managerId`, `candidateGroups`...                                                                                              |
| HTTP Task / External Worker Task                                       | ✅ Vẫn dùng được, nhưng giờ là **tuỳ chọn**, không bắt buộc | Cân nhắc dùng cho job cần retry/backoff phức tạp hoặc khi muốn NestJS tự chủ hoàn toàn việc polling (xem mục 6)                                               |
| Script Task (Groovy/JavaScript inline)                                 | ⚠️ Hạn chế                                                  | Vẫn nên tránh cho production vì rủi ro bảo mật khi có người chỉnh sửa BPMN qua Modeler UI                                                                     |

### 2.1 Nguyên tắc quan trọng nhất: JavaDelegate là lớp mỏng, không phải nơi viết business logic

Vì **NestJS đã là hệ thống chứa business logic chính** (tính lương, tra cứu tổ chức, validate nghiệp vụ, gửi thông báo…), việc viết lại toàn bộ logic đó bằng Java trong JavaDelegate sẽ dẫn đến **hai nguồn sự thật** (logic nghiệp vụ nằm rải rác ở cả Java và NestJS, dễ lệch nhau khi sửa một bên mà quên bên kia).

➡️ **Quy ước**: mọi `JavaDelegate`/`TaskListener` trong Flowable **chỉ làm 2 việc**:

1. Đọc biến process (`DelegateExecution`/`DelegateTask`).
2. Gọi một API nội bộ của NestJS (qua `WebClient`/`RestTemplate`) để thực thi business logic thật, rồi ghi kết quả trả về vào lại biến process.

Cách này giữ được ưu điểm của JavaDelegate chuẩn (gọn trong BPMN, không cần cấu hình HTTP request thủ công bằng XML như HTTP Task, dễ debug bằng Java IDE, dễ viết unit test) nhưng vẫn đảm bảo **NestJS là nguồn sự thật duy nhất về business logic**.

---

## 3. Cấu hình Flowable server cho production

Vì server đã có sẵn, phần này là **checklist rà soát lại cấu hình** hơn là hướng dẫn cài mới.

### 3.1 Những điểm cần xác nhận với người quản trị Flowable server

- [ ] REST API endpoint nội bộ là gì (VD: `http://flowable-internal:8080/flowable-rest/service`) — **không** nên expose ra internet, chỉ NestJS gọi qua network nội bộ (VPC/K8s ClusterIP).
- [ ] Cơ chế xác thực REST API: mặc định Flowable REST dùng **HTTP Basic Auth** với user khai báo trong bảng `ACT_ID_USER`. Cần tạo một **service account riêng cho NestJS** (VD: `svc-nestjs-approval`), **không dùng chung** tài khoản admin.
- [ ] Bật `history-level=full` (hoặc tối thiểu `audit`) để đủ dữ liệu tra cứu lịch sử qua History REST API.
- [ ] Xác nhận `async-executor` đã bật trên server (bắt buộc để Timer Boundary Event và External Worker Job hoạt động).
- [ ] Có app **Flowable Modeler UI** không? Nếu có và cho phép Business Analyst tự sửa BPMN, cần quy trình review/duyệt trước khi deploy version mới vào production (không để sửa trực tiếp trên môi trường live).
- [ ] Xác nhận phiên bản Flowable (6.x hay 7.x) — cú pháp/endpoint External Worker Job khác nhau đôi chút giữa các bản, cần đối chiếu OpenAPI docs (`/docs`) của chính server đang chạy trước khi code NestJS client.

### 3.2 Đề xuất bảo mật tầng network

```
React → (public) → NestJS → (internal network / VPC / mTLS) → Flowable REST
```

- Đặt Flowable server sau firewall/K8s NetworkPolicy chỉ cho phép NestJS pod gọi tới.
- Nếu không kiểm soát được network layer, ít nhất bật HTTPS + IP whitelist cho REST endpoint của Flowable.
- Basic Auth credentials của service account lưu trong Secret Manager (Vault/K8s Secret), NestJS đọc qua biến môi trường, **không hardcode**.

---

## 4. Thiết kế BPMN dùng JavaDelegate (lớp mỏng gọi NestJS)

### 4.1 Nguyên tắc thiết kế biến process

Toàn bộ dữ liệu cần cho quyết định luồng (gateway) hoặc cho assignee **phải được NestJS tính toán trước và truyền vào lúc `startProcessInstance`**, vì BPMN không tự gọi code Java để tính được nữa.

Ví dụ luồng nghỉ phép:

```
NestJS (trước khi start process):
  1. Validate dữ liệu đơn (ngày nghỉ, số ngày còn lại) — gọi HRM API nếu cần
  2. Tính numberOfDays
  3. Tra cứu managerId của employeeId (org chart) → resolve trước, không để BPMN tự tra
  4. Gọi POST /runtime/process-instances để start, truyền kèm variables:
     { employeeId, numberOfDays, managerId, hrGroup: "hr-approvers" }
```

### 4.2 BPMN mẫu — dùng JavaDelegate/TaskListener trỏ tới NestJS

```xml
<?xml version="1.0" encoding="UTF-8"?>
<definitions xmlns="http://www.omg.org/spec/BPMN/20100524/MODEL"
             xmlns:flowable="http://flowable.org/bpmn"
             targetNamespace="http://approval.company.com">

  <process id="leaveRequestProcess" name="Leave Request Approval" isExecutable="true">

    <startEvent id="start"/>

    <!-- TaskListener gọi NestJS để resolve managerId ngay khi task được tạo -->
    <userTask id="lineManagerApproval" name="Line Manager Approval">
      <extensionElements>
        <flowable:taskListener event="create" delegateExpression="${assignManagerListener}"/>
      </extensionElements>
    </userTask>

    <boundaryEvent id="managerTimeout" attachedToRef="lineManagerApproval" cancelActivity="false">
      <timerEventDefinition>
        <timeDuration>PT24H</timeDuration>
      </timerEventDefinition>
    </boundaryEvent>

    <!-- Service Task chuẩn, async, delegate gọi ngược NestJS -->
    <serviceTask id="escalateNotify" name="Notify escalation"
                 flowable:delegateExpression="${escalationDelegate}"
                 flowable:async="true"/>

    <exclusiveGateway id="gwManagerDecision"/>

    <userTask id="hrApproval" name="HR Approval" flowable:candidateGroups="${hrGroup}"/>

    <exclusiveGateway id="gwHrDecision"/>

    <serviceTask id="finalizeApproval" name="Finalize approval"
                 flowable:delegateExpression="${finalizeApprovalDelegate}"
                 flowable:async="true"/>

    <endEvent id="endApproved"/>
    <endEvent id="endRejected"/>

    <sequenceFlow sourceRef="start" targetRef="lineManagerApproval"/>
    <sequenceFlow sourceRef="managerTimeout" targetRef="escalateNotify"/>
    <sequenceFlow sourceRef="escalateNotify" targetRef="lineManagerApproval"/>
    <sequenceFlow sourceRef="lineManagerApproval" targetRef="gwManagerDecision"/>

    <sequenceFlow sourceRef="gwManagerDecision" targetRef="hrApproval">
      <conditionExpression xsi:type="tFormalExpression">${decision == 'APPROVE' && numberOfDays > 2}</conditionExpression>
    </sequenceFlow>
    <sequenceFlow sourceRef="gwManagerDecision" targetRef="finalizeApproval">
      <conditionExpression xsi:type="tFormalExpression">${decision == 'APPROVE' && numberOfDays <= 2}</conditionExpression>
    </sequenceFlow>
    <sequenceFlow sourceRef="gwManagerDecision" targetRef="endRejected">
      <conditionExpression xsi:type="tFormalExpression">${decision == 'REJECT'}</conditionExpression>
    </sequenceFlow>

    <sequenceFlow sourceRef="hrApproval" targetRef="gwHrDecision"/>
    <sequenceFlow sourceRef="gwHrDecision" targetRef="finalizeApproval">
      <conditionExpression xsi:type="tFormalExpression">${decision == 'APPROVE'}</conditionExpression>
    </sequenceFlow>
    <sequenceFlow sourceRef="gwHrDecision" targetRef="endRejected">
      <conditionExpression xsi:type="tFormalExpression">${decision == 'REJECT'}</conditionExpression>
    </sequenceFlow>

    <sequenceFlow sourceRef="finalizeApproval" targetRef="endApproved"/>

  </process>
</definitions>
```

So với bản HTTP Task (cấu hình request bằng XML field), cách này gọn hơn nhiều trong BPMN — toàn bộ chi tiết "gọi API nào, header gì, xử lý response ra sao" chuyển sang code Java, dễ đọc/debug/test hơn XML.

> **Quy ước biến `decision`**: cả 2 gateway (`gwManagerDecision`, `gwHrDecision`) đều đọc chung 1 biến process tên `decision` — vì Flowable ghi đè giá trị biến mỗi lần task hoàn thành, nên NestJS chỉ cần luôn gửi `{ decision: 'APPROVE' | 'REJECT' }` khi complete bất kỳ task nào trong quy trình (mục 5.2, 8.2), không cần biết đang ở bước nào để chọn đúng tên biến.

### 4.2.1 Code Java tương ứng (Spring Bean, phía server Flowable)

Đây là phần Java **duy nhất** cần viết — chỉ đóng vai trò cầu nối, gọi thẳng vào NestJS:

```java
// FinalizeApprovalDelegate.java — chạy trong Spring Boot app đóng gói Flowable
@Component("finalizeApprovalDelegate")
@RequiredArgsConstructor
public class FinalizeApprovalDelegate implements JavaDelegate {

    private final WebClient nestjsClient; // WebClient trỏ base-url NestJS internal API

    @Override
    public void execute(DelegateExecution execution) {
        String businessKey = execution.getProcessInstanceBusinessKey();

        Map<String, Object> body = Map.of(
                "businessKey", businessKey,
                "decision", "APPROVED"
        );

        // Gọi thẳng vào NestJS — mọi business logic thật (cập nhật số ngày phép,
        // ghi log, gửi email...) nằm bên NestJS, Java chỉ forward request
        nestjsClient.post()
                .uri("/internal/workflow/leave/finalize")
                .header("X-Internal-Auth", internalServiceToken())
                .bodyValue(body)
                .retrieve()
                .onStatus(HttpStatusCode::isError, response ->
                        Mono.error(new BpmnError("NESTJS_CALL_FAILED", "Gọi NestJS thất bại")))
                .toBodilessEntity()
                .block(Duration.ofSeconds(5));
    }

    private String internalServiceToken() {
        return System.getenv("INTERNAL_SERVICE_TOKEN");
    }
}
```

```java
// AssignManagerListener.java — gán assignee động bằng cách gọi NestJS
@Component("assignManagerListener")
@RequiredArgsConstructor
public class AssignManagerListener implements TaskListener {

    private final WebClient nestjsClient;

    @Override
    public void notify(DelegateTask delegateTask) {
        String employeeId = (String) delegateTask.getVariable("employeeId");

        String managerId = nestjsClient.get()
                .uri("/internal/org-chart/{employeeId}/manager", employeeId)
                .header("X-Internal-Auth", System.getenv("INTERNAL_SERVICE_TOKEN"))
                .retrieve()
                .bodyToMono(String.class)
                .block(Duration.ofSeconds(3));

        delegateTask.setAssignee(managerId);
    }
}
```

```java
// WebClientConfig.java
@Configuration
public class WebClientConfig {
    @Bean
    public WebClient nestjsClient(@Value("${nestjs.internal.base-url}") String baseUrl) {
        return WebClient.builder()
                .baseUrl(baseUrl) // http://nestjs-approval-svc:3000
                .build();
    }
}
```

> **Lưu ý**: `JavaDelegate`/`TaskListener` chạy **trong transaction của engine** — nếu gọi NestJS đồng bộ (block) mà NestJS chậm/lỗi, sẽ giữ transaction lâu hoặc rollback cả bước xử lý. Vì vậy: (1) luôn đặt `flowable:async="true"` cho Service Task gọi ra ngoài để tách khỏi transaction chính, (2) đặt timeout ngắn (3–5s) cho `WebClient`, (3) ném `BpmnError` khi lỗi để BPMN có thể xử lý nhánh lỗi rõ ràng thay vì để exception chung chung làm treo job.

### 4.3 Gán assignee động — dùng TaskListener chuẩn

Với TaskListener Java (`assignManagerListener` ở mục 4.2.1), việc gán assignee động diễn ra ngay khi task được tạo, không cần resolve trước lúc start process — linh hoạt hơn vì có thể tính toán dựa trên trạng thái mới nhất tại thời điểm task thực sự sinh ra (thay vì cố định từ lúc start).

Vẫn có thể kết hợp cả hai cách tuỳ tình huống:

1. **Resolve trước khi start** (đơn giản, phù hợp khi assignee không đổi trong suốt vòng đời task): NestJS tính `managerId` lúc `submit()`, truyền vào variable, BPMN dùng `flowable:assignee="${managerId}"` — không cần TaskListener.
2. **TaskListener gọi NestJS lúc tạo task** (linh hoạt hơn, dùng khi assignee phụ thuộc dữ liệu có thể thay đổi giữa lúc start process và lúc task thực sự được tạo, ví dụ quy trình có nhiều bước trước đó): dùng cách ở mục 4.2.1.

Khuyến nghị: dùng cách 1 làm mặc định cho đơn giản, chỉ chuyển sang cách 2 khi có lý do nghiệp vụ cụ thể.

### 4.4 Multi-instance (duyệt song song hội đồng) — vẫn dùng được, không cần code

```xml
<userTask id="committeeApproval" name="Committee Approval" flowable:candidateGroups="committee">
  <multiInstanceLoopCharacteristics isSequential="false"
        flowable:collection="${committeeMembers}"
        flowable:elementVariable="member">
    <completionCondition>${nrOfCompletedInstances/nrOfInstances >= 0.66}</completionCondition>
  </multiInstanceLoopCharacteristics>
</userTask>
```

`committeeMembers` (mảng userId) được NestJS tính toán và truyền vào lúc start process — vẫn thuần biến, không cần Java.

---

## 5. NestJS — Module tích hợp Flowable REST

### 5.1 Cấu trúc thư mục gợi ý

```
src/
├── flowable-client/
│   ├── flowable-client.module.ts
│   ├── flowable-client.service.ts     # wrapper axios cho toàn bộ REST API Flowable
│   ├── dto/
│   │   ├── start-process.dto.ts
│   │   ├── task-query.dto.ts
│   │   └── complete-task.dto.ts
│   └── interfaces/
├── approval/
│   ├── leave-request/
│   │   ├── leave-request.controller.ts
│   │   ├── leave-request.service.ts
│   │   └── entities/leave-request.entity.ts
│   ├── task/
│   │   ├── task.controller.ts        # API cho FE: my-tasks, complete, claim
│   │   └── task.service.ts
│   └── internal/
│       └── workflow-callback.controller.ts   # nhận callback từ JavaDelegate của Flowable
├── org-chart/
│   └── org-chart.controller.ts        # endpoint nội bộ để AssignManagerListener (Java) gọi vào
├── worker/
│   └── external-worker.service.ts    # poll External Worker Job
├── auth/
│   ├── jwt.strategy.ts               # xác thực FE → NestJS
│   └── internal-auth.guard.ts        # xác thực Flowable → NestJS (X-Internal-Auth)
└── main.ts
```

### 5.2 FlowableClientService — wrapper gọi REST API

```typescript
// flowable-client/flowable-client.service.ts
import { HttpService } from "@nestjs/axios";
import { Injectable, Logger } from "@nestjs/common";
import { firstValueFrom } from "rxjs";

@Injectable()
export class FlowableClientService {
  private readonly logger = new Logger(FlowableClientService.name);
  private readonly baseUrl = process.env.FLOWABLE_REST_BASE_URL; // http://flowable-internal:8080/flowable-rest/service
  private readonly authHeader = {
    auth: {
      username: process.env.FLOWABLE_SVC_USER,
      password: process.env.FLOWABLE_SVC_PASSWORD,
    },
  };

  constructor(private readonly http: HttpService) {}

  async startProcessInstance(params: {
    processDefinitionKey: string;
    businessKey: string;
    variables: Record<string, any>;
  }) {
    const body = {
      processDefinitionKey: params.processDefinitionKey,
      businessKey: params.businessKey,
      variables: Object.entries(params.variables).map(([name, value]) => ({
        name,
        value,
      })),
    };
    const res = await firstValueFrom(
      this.http.post(`${this.baseUrl}/runtime/process-instances`, body, this.authHeader)
    );
    return res.data; // { id: processInstanceId, ... }
  }

  async getTasksByAssignee(userId: string, page = 0, size = 20) {
    const res = await firstValueFrom(
      this.http.get(`${this.baseUrl}/runtime/tasks`, {
        ...this.authHeader,
        params: { assignee: userId, start: page * size, size, sort: "createTime", order: "desc" },
      })
    );
    return res.data;
  }

  async getTasksByCandidateGroups(groups: string[], page = 0, size = 20) {
    const res = await firstValueFrom(
      this.http.get(`${this.baseUrl}/runtime/tasks`, {
        ...this.authHeader,
        params: {
          candidateGroups: groups.join(","),
          start: page * size,
          size,
        },
      })
    );
    return res.data;
  }

  async completeTask(taskId: string, variables: Record<string, any>) {
    const body = {
      action: "complete",
      variables: Object.entries(variables).map(([name, value]) => ({ name, value })),
    };
    await firstValueFrom(this.http.post(`${this.baseUrl}/runtime/tasks/${taskId}`, body, this.authHeader));
  }

  async claimTask(taskId: string, userId: string) {
    await firstValueFrom(
      this.http.post(`${this.baseUrl}/runtime/tasks/${taskId}`, { action: "claim", assignee: userId }, this.authHeader)
    );
  }

  async getTaskById(taskId: string) {
    const res = await firstValueFrom(this.http.get(`${this.baseUrl}/runtime/tasks/${taskId}`, this.authHeader));
    return res.data;
  }

  async getHistoricProcessInstance(processInstanceId: string) {
    const res = await firstValueFrom(
      this.http.get(`${this.baseUrl}/history/historic-process-instances/${processInstanceId}`, this.authHeader)
    );
    return res.data;
  }
}
```

> **Lưu ý xác thực quyền**: `getTaskById` + so sánh `assignee`/`candidateGroups` với `userId` đang đăng nhập **phải luôn được kiểm tra trong `TaskService` của NestJS trước khi gọi `completeTask`** — không tin `taskId` do FE gửi lên là "hợp lệ cho user này".

### 5.3 Service nghiệp vụ start process (resolve dữ liệu trước khi start)

```typescript
// approval/leave-request/leave-request.service.ts
@Injectable()
export class LeaveRequestService {
  constructor(
    private readonly flowableClient: FlowableClientService,
    private readonly orgChartClient: OrgChartClient,
    @InjectRepository(LeaveRequest)
    private readonly leaveRequestRepo: EntityRepository<LeaveRequest>,
    private readonly em: EntityManager
  ) {}

  async submit(dto: CreateLeaveRequestDto, employeeId: string) {
    const remaining = await this.orgChartClient.getRemainingLeaveDays(employeeId);
    if (remaining < dto.numberOfDays) {
      throw new BadRequestException("Số ngày phép còn lại không đủ");
    }

    const managerId = await this.orgChartClient.getDirectManager(employeeId);

    const entity = this.leaveRequestRepo.create({
      employeeId,
      numberOfDays: dto.numberOfDays,
      startDate: dto.startDate,
      endDate: dto.endDate,
      reason: dto.reason,
      status: "IN_PROGRESS",
    });
    await this.em.persistAndFlush(entity);

    const instance = await this.flowableClient.startProcessInstance({
      processDefinitionKey: "leaveRequestProcess",
      businessKey: entity.id.toString(),
      variables: {
        employeeId,
        numberOfDays: dto.numberOfDays,
        managerId,
        hrGroup: "hr-approvers",
      },
    });

    entity.processInstanceId = instance.id;
    await this.em.flush();
    return entity;
  }
}
```

> Lưu ý: `INTERNAL_SERVICE_TOKEN` **không** cần truyền qua biến process — JavaDelegate phía Java đọc thẳng từ biến môi trường của chính server Flowable (mục 4.2.1), NestJS chỉ cần cấu hình cùng giá trị secret ở biến môi trường của mình để so khớp trong `InternalAuthGuard`.

> Chi tiết đầy đủ về Entity/Repository MikroORM (`LeaveRequest`, migration, cấu hình module) xem mục 7.5 — phần trên chỉ minh hoạ luồng gọi `FlowableClientService`.

### 5.4 Controller nhận callback từ JavaDelegate (Flowable gọi ngược)

```typescript
// approval/internal/workflow-callback.controller.ts
@Controller("internal/workflow")
@UseGuards(InternalAuthGuard) // kiểm tra header X-Internal-Auth khớp token bí mật
export class WorkflowCallbackController {
  constructor(private readonly leaveRequestService: LeaveRequestService) {}

  @Post("leave/finalize")
  async finalize(@Body() body: { businessKey: string; decision: string }) {
    await this.leaveRequestService.finalizeByBusinessKey(body.businessKey, body.decision);
    return { status: "ok" };
  }

  @Post("escalate")
  async escalate(@Body() body: { processInstanceId: string; taskId: string; employeeId: string }) {
    await this.leaveRequestService.notifySkipLevelManager(body);
    return { status: "ok" };
  }
}
```

```typescript
// org-chart/org-chart.controller.ts — endpoint mà AssignManagerListener (Java, mục 4.2.1) gọi vào
@Controller("internal/org-chart")
@UseGuards(InternalAuthGuard)
export class OrgChartController {
  constructor(private readonly orgChartClient: OrgChartClient) {}

  @Get(":employeeId/manager")
  async getManager(@Param("employeeId") employeeId: string): Promise<string> {
    return this.orgChartClient.getDirectManager(employeeId);
  }
}
```

> **`InternalAuthGuard`**: so khớp header `X-Internal-Auth` với secret dùng chung giữa NestJS và Flowable (mỗi bên tự cấu hình cùng giá trị `INTERNAL_SERVICE_TOKEN` trong biến môi trường, JavaDelegate/TaskListener phía Java đọc và gửi kèm mỗi request — xem mục 4.2.1). Đây là cách xác thực đơn giản, đủ dùng khi Flowable/NestJS nằm trong cùng mạng nội bộ tin cậy. Nếu cần chặt hơn, đặt reverse proxy chỉ cho phép IP của Flowable server gọi vào route `/internal/*`.

---

## 6. Khi nào vẫn nên dùng HTTP Task / External Worker thay vì JavaDelegate

Dù JavaDelegate là lựa chọn mặc định (mục 4), vẫn có tình huống nên cân nhắc hai cơ chế còn lại:

### 6.1 So sánh 3 cách gọi ra ngoài từ BPMN

| Tiêu chí           | JavaDelegate (khuyến nghị)                                            | HTTP Task                                                                                 | External Worker Task                                                                                     |
| ------------------ | --------------------------------------------------------------------- | ----------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| Nơi cấu hình logic | Java code (IDE, test được)                                            | XML trong BPMN                                                                            | TypeScript code (worker trong NestJS)                                                                    |
| Phù hợp cho        | Đa số Service Task nghiệp vụ thông thường                             | Muốn Business Analyst tự sửa endpoint/payload qua Modeler UI mà không cần deploy lại Java | Job chạy lâu (vài phút+), cần retry/backoff riêng, muốn NestJS chủ động poll thay vì bị Flowable gọi vào |
| Ai maintain code   | Team Java (dù chỉ vài dòng gọi NestJS)                                | Không ai — chỉ cấu hình XML                                                               | Team NestJS hoàn toàn                                                                                    |
| Retry              | Theo cơ chế job retry mặc định của Flowable (`flowable:async="true"`) | Tương tự                                                                                  | Tự chủ hoàn toàn qua `success`/`failure` API, kiểm soát tinh hơn                                         |

### 6.2 Khuyến nghị thực tế

- **Mặc định dùng JavaDelegate** cho toàn bộ Service Task nghiệp vụ (mục 4) — đơn giản, dễ test, đúng chuẩn Flowable.
- **Cân nhắc External Worker Task** riêng cho các job đặc thù: đồng bộ dữ liệu ERP lớn, xử lý file, gọi hệ thống ngoài chậm/không ổn định — để đội NestJS tự kiểm soát toàn bộ vòng đời job (poll, retry, backoff) mà không phụ thuộc timeout của JavaDelegate.
- **HTTP Task hầu như không cần thiết** trong bối cảnh này (chỉ hữu ích khi _không_ build được Java) — có thể bỏ qua trừ khi có nhu cầu để non-dev tự cấu hình endpoint qua Modeler UI.

### 6.3 Cấu hình External Worker Task (nếu chọn dùng cho job nặng)

```xml
<serviceTask id="syncErpJob" name="Sync to ERP" flowable:type="external-worker" flowable:topic="erp-sync-topic"/>
```

NestJS viết worker poll job theo topic này (endpoint cụ thể có thể khác đôi chút theo phiên bản Flowable — kiểm tra OpenAPI docs của server đang chạy để xác nhận đường dẫn chính xác):

```typescript
// worker/external-worker.service.ts
@Injectable()
export class ExternalWorkerService implements OnModuleInit {
  private readonly workerId = `nestjs-worker-${os.hostname()}`;

  constructor(private readonly http: HttpService, private readonly erpClient: ErpClient) {}

  onModuleInit() {
    setInterval(() => this.pollAndExecute(), 3000); // poll mỗi 3s
  }

  private async pollAndExecute() {
    const acquireRes = await firstValueFrom(
      this.http.post(
        `${process.env.FLOWABLE_REST_BASE_URL}/acquire/jobs`,
        {
          workerId: this.workerId,
          topic: "erp-sync-topic",
          numberOfTasks: 5,
          lockDuration: "PT5M",
        },
        this.authHeader
      )
    );

    for (const job of acquireRes.data) {
      try {
        await this.erpClient.syncData(job.variables);
        await firstValueFrom(
          this.http.post(
            `${process.env.FLOWABLE_REST_BASE_URL}/jobs/${job.id}/success`,
            { workerId: this.workerId, variables: [{ name: "erpSyncStatus", value: "DONE" }] },
            this.authHeader
          )
        );
      } catch (err) {
        await firstValueFrom(
          this.http.post(
            `${process.env.FLOWABLE_REST_BASE_URL}/jobs/${job.id}/failure`,
            { workerId: this.workerId, errorMessage: err.message, retries: 2, retryTimeout: "PT1M" },
            this.authHeader
          )
        );
      }
    }
  }
}
```

> Trước khi triển khai thật, **đối chiếu chính xác path/payload External Worker API với version Flowable đang chạy** — cú pháp `acquire/jobs`, `jobs/{id}/success`, `jobs/{id}/failure` là theo tài liệu Flowable 7.x, một số bản cũ hơn có thể khác nhẹ.

### 6.4 Mẫu Service Task nghiệp vụ khác bằng JavaDelegate (tham khảo thêm)

```java
@Component("calculateLeaveDelegate")
@RequiredArgsConstructor
public class CalculateLeaveDelegate implements JavaDelegate {

    private final WebClient nestjsClient;

    @Override
    public void execute(DelegateExecution execution) {
        String employeeId = (String) execution.getVariable("employeeId");
        int requestedDays = (int) execution.getVariable("numberOfDays");

        Integer remaining = nestjsClient.get()
                .uri("/internal/hrm/{employeeId}/remaining-leave-days", employeeId)
                .header("X-Internal-Auth", System.getenv("INTERNAL_SERVICE_TOKEN"))
                .retrieve()
                .bodyToMono(Integer.class)
                .block(Duration.ofSeconds(3));

        if (remaining == null || remaining < requestedDays) {
            throw new BpmnError("INSUFFICIENT_LEAVE_BALANCE", "Số ngày phép còn lại không đủ");
        }
        execution.setVariable("remainingLeaveDays", remaining);
    }
}
```

---

## 7. Đồng bộ trạng thái & database nghiệp vụ

### 7.1 Kiến trúc database: tách riêng với DB của Flowable, không dùng chung

Vì Flowable chạy như **server riêng, đã có sẵn**, database của nó (các bảng `ACT_RE_*`, `ACT_RU_*`, `ACT_HI_*`...) nên được coi là **thuộc quyền quản lý của Flowable server**, hoàn toàn tách biệt với database nghiệp vụ mà NestJS/MikroORM dùng. Lý do:

| Lý do              | Giải thích                                                                                                                                                                                           |
| ------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Vòng đời khác nhau | Flowable server có lifecycle/version riêng, không nên trộn migration NestJS vào chung DB — mỗi bên tự chủ nâng cấp mà không ảnh hưởng nhau                                                           |
| Bảo mật/quyền      | NestJS **không nên có quyền ghi trực tiếp** vào bảng `ACT_*` — chỉ thao tác qua REST API, tránh việc code lỗi ở NestJS vô tình phá dữ liệu hệ thống của engine                                       |
| Connection pool    | Async job executor của Flowable query bảng `ACT_RU_JOB` liên tục (vài giây/lần) — nếu chung DB/pool với NestJS dễ tranh chấp connection lúc tải cao                                                  |
| Backup & retention | Flowable cần chính sách dọn lịch sử riêng (`ACT_HI_*`); DB nghiệp vụ (đơn từ, audit log) thường cần lưu **lâu hơn** cho mục đích kiểm toán — hai chính sách backup khác nhau, dễ quản lý khi tách DB |
| Scale độc lập      | Có thể tune/scale Postgres cho DB nghiệp vụ khác với DB Flowable tuỳ tải thực tế từng bên                                                                                                            |

**3 phương án cách ly, chọn theo hạ tầng thực tế:**

| Phương án                                       | Mô tả                                                                     | Khi nào chọn                                                                                                     |
| ----------------------------------------------- | ------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| **A — Instance Postgres hoàn toàn khác nhau**   | DB Flowable và DB nghiệp vụ ở 2 server/cluster riêng                      | Mặc định hợp lý nhất khi Flowable "đã có sẵn" — nhiều khả năng DB của nó vốn đã độc lập rồi                      |
| **B — Cùng 1 Postgres server, khác `database`** | `flowable_db` và `business_db` trên cùng instance, user/credentials riêng | Tiết kiệm hạ tầng ở quy mô nhỏ/vừa, vẫn cách ly tốt (Postgres không JOIN cross-database được)                    |
| **C — Cùng 1 database, khác `schema`**          | `schema flowable` / `schema business` trong cùng DB                       | Cách ly yếu nhất, chỉ dùng khi hạ tầng hạn chế — bắt buộc dùng 2 user Postgres riêng, giới hạn quyền theo schema |

**Liên kết dữ liệu giữa 2 DB — không dùng Foreign Key**: vì không thể tạo FK chéo giữa 2 database (hoặc nên tránh chéo schema hệ thống của Flowable), liên kết thực hiện ở **tầng ứng dụng** qua `processInstanceId`/`businessKey` lưu dạng chuỗi trong bảng nghiệp vụ (đã có sẵn trong entity `LeaveRequest`, cột `process_instance_id` — mục 7.5). Mọi truy vấn "lấy thêm dữ liệu từ Flowable" đi qua `FlowableClientService` (REST API), không JOIN SQL trực tiếp giữa 2 DB.

### 7.2 Vấn đề đồng bộ transaction

NestJS không "nhúng" engine nên không có transaction chung giữa việc lưu entity nghiệp vụ và start/complete process. Cần chọn 1 trong 2 chiến lược:

### 7.3 Chiến lược A — Callback đồng bộ qua JavaDelegate (khuyến nghị, đã minh hoạ ở mục 4–5)

- Mỗi điểm quan trọng trong BPMN (kết thúc, reject, escalate...) có 1 JavaDelegate gọi ngược `internal/workflow/...` để NestJS cập nhật bảng nghiệp vụ ngay lập tức (xem mục 4.2.1).
- Ưu điểm: real-time, đơn giản.
- Nhược điểm: nếu callback lỗi, process instance sẽ bị lỗi/đứng ở job retry — cần có job giám sát + alerting cho các Service Task bị treo (`GET /management/jobs?withException=true`).

### 7.4 Chiến lược B — Reconciliation job định kỳ (bổ sung, không thay thế A)

Chạy cron trong NestJS (VD: mỗi 5 phút) gọi History REST API để đối chiếu trạng thái process instance với bảng nghiệp vụ, tự sửa nếu lệch (bù cho trường hợp callback A bị mất do lỗi mạng tạm thời):

```typescript
@Cron('*/5 * * * *')
async reconcileLeaveRequestStatus() {
  const inProgress = await this.leaveRequestRepo.find({ status: LeaveRequestStatus.IN_PROGRESS });
  for (const lr of inProgress) {
    const hi = await this.flowableClient.getHistoricProcessInstance(lr.processInstanceId);
    if (hi.endTime) {
      lr.status = hi.deleteReason ? LeaveRequestStatus.CANCELLED : await this.resolveFinalStatus(lr);
    }
  }
  await this.em.flush(); // MikroORM: cần flush để commit toàn bộ thay đổi entity đã track
}
```

### 7.5 Bảng nghiệp vụ mẫu (NestJS tự quản lý DB riêng, dùng MikroORM)

```bash
npm install @mikro-orm/core @mikro-orm/postgresql @mikro-orm/nestjs @mikro-orm/migrations
```

#### 7.5.1 Entity

```typescript
// entities/leave-request.entity.ts
import { Entity, PrimaryKey, Property, Enum, Index } from "@mikro-orm/core";

export enum LeaveRequestStatus {
  DRAFT = "DRAFT",
  IN_PROGRESS = "IN_PROGRESS",
  APPROVED = "APPROVED",
  REJECTED = "REJECTED",
  CANCELLED = "CANCELLED",
}

@Entity({ tableName: "leave_request" })
export class LeaveRequest {
  @PrimaryKey({ type: "bigint" })
  id!: number;

  @Property({ fieldName: "employee_id", length: 64 })
  employeeId!: string;

  @Property({ fieldName: "number_of_days", type: "numeric", precision: 4, scale: 1 })
  numberOfDays!: number;

  @Property({ type: "date", fieldName: "start_date" })
  startDate!: Date;

  @Property({ type: "date", fieldName: "end_date" })
  endDate!: Date;

  @Property({ nullable: true })
  reason?: string;

  @Enum(() => LeaveRequestStatus)
  status: LeaveRequestStatus = LeaveRequestStatus.DRAFT;

  @Index()
  @Property({ fieldName: "process_instance_id", nullable: true, length: 64 })
  processInstanceId?: string;

  @Property({ fieldName: "process_def_key", length: 64, default: "leaveRequestProcess" })
  processDefKey: string = "leaveRequestProcess";

  @Property({ fieldName: "idempotency_key", nullable: true, unique: true, length: 128 })
  idempotencyKey?: string;

  @Property({ fieldName: "created_at", onCreate: () => new Date() })
  createdAt: Date = new Date();

  @Property({ fieldName: "updated_at", onCreate: () => new Date(), onUpdate: () => new Date() })
  updatedAt: Date = new Date();
}
```

```typescript
// entities/approval-history-log.entity.ts
import { Entity, PrimaryKey, Property } from "@mikro-orm/core";

@Entity({ tableName: "approval_history_log" })
export class ApprovalHistoryLog {
  @PrimaryKey({ type: "bigint" })
  id!: number;

  @Property({ fieldName: "business_key", length: 64 })
  businessKey!: string;

  @Property({ fieldName: "task_id", nullable: true, length: 64 })
  taskId?: string;

  @Property({ fieldName: "task_name", nullable: true })
  taskName?: string;

  @Property({ fieldName: "approver_id", nullable: true, length: 64 })
  approverId?: string;

  @Property({ nullable: true, length: 32 })
  decision?: string;

  @Property({ nullable: true })
  comment?: string;

  @Property({ fieldName: "decided_at", onCreate: () => new Date() })
  decidedAt: Date = new Date();
}
```

#### 7.5.2 Module & config

```typescript
// mikro-orm.config.ts
import { defineConfig } from "@mikro-orm/postgresql";
import { LeaveRequest } from "./entities/leave-request.entity";
import { ApprovalHistoryLog } from "./entities/approval-history-log.entity";

export default defineConfig({
  entities: [LeaveRequest, ApprovalHistoryLog],
  dbName: process.env.BUSINESS_DB_NAME,
  host: process.env.BUSINESS_DB_HOST,
  port: Number(process.env.BUSINESS_DB_PORT ?? 5432),
  user: process.env.BUSINESS_DB_USER,
  password: process.env.BUSINESS_DB_PASSWORD,
  schema: "business", // tách schema/database riêng khỏi DB của Flowable (mục 7.1)
  migrations: { path: "./dist/migrations", pathTs: "./src/migrations" },
  debug: process.env.NODE_ENV !== "production",
});
```

```typescript
// app.module.ts
import { MikroOrmModule } from "@mikro-orm/nestjs";
import mikroOrmConfig from "./mikro-orm.config";

@Module({
  imports: [MikroOrmModule.forRoot(mikroOrmConfig)],
})
export class AppModule {}
```

#### 7.5.3 Dùng `EntityRepository` trong service nghiệp vụ

```typescript
// leave-request.service.ts
import { InjectRepository } from "@mikro-orm/nestjs";
import { EntityRepository } from "@mikro-orm/postgresql";
import { EntityManager } from "@mikro-orm/postgresql";

@Injectable()
export class LeaveRequestService {
  constructor(
    @InjectRepository(LeaveRequest)
    private readonly leaveRequestRepo: EntityRepository<LeaveRequest>,
    @InjectRepository(ApprovalHistoryLog)
    private readonly historyLogRepo: EntityRepository<ApprovalHistoryLog>,
    private readonly em: EntityManager,
    private readonly flowableClient: FlowableClientService,
    private readonly orgChartClient: OrgChartClient
  ) {}

  async submit(dto: CreateLeaveRequestDto, employeeId: string, idempotencyKey: string) {
    const existing = await this.leaveRequestRepo.findOne({ idempotencyKey });
    if (existing) return existing; // chống double-submit, xem mục 10.1

    const remaining = await this.orgChartClient.getRemainingLeaveDays(employeeId);
    if (remaining < dto.numberOfDays) {
      throw new BadRequestException("Số ngày phép còn lại không đủ");
    }
    const managerId = await this.orgChartClient.getDirectManager(employeeId);

    const entity = this.leaveRequestRepo.create({
      employeeId,
      numberOfDays: dto.numberOfDays,
      startDate: dto.startDate,
      endDate: dto.endDate,
      reason: dto.reason,
      status: LeaveRequestStatus.IN_PROGRESS,
      idempotencyKey,
    });
    await this.em.persistAndFlush(entity);

    const instance = await this.flowableClient.startProcessInstance({
      processDefinitionKey: "leaveRequestProcess",
      businessKey: entity.id.toString(),
      variables: { employeeId, numberOfDays: dto.numberOfDays, managerId, hrGroup: "hr-approvers" },
    });

    entity.processInstanceId = instance.id;
    await this.em.flush();
    return entity;
  }

  async finalizeByBusinessKey(businessKey: string, decision: string) {
    const entity = await this.leaveRequestRepo.findOneOrFail({ id: Number(businessKey) });
    entity.status = decision === "APPROVED" ? LeaveRequestStatus.APPROVED : LeaveRequestStatus.REJECTED;
    await this.em.flush();
  }
}
```

> Lưu ý `EntityManager` (`em.persistAndFlush`/`em.flush`) là cách chuẩn của MikroORM để commit thay đổi — khác với TypeORM (`repository.save()` tự flush ngay). Cần chú ý gọi `flush()` sau mỗi lần đổi entity, đặc biệt trong các đoạn code có 2 bước ghi (lưu entity trước → gọi Flowable → cập nhật `processInstanceId` sau) như ví dụ trên.

#### 7.5.4 Migration (thay cho DDL thuần)

```bash
npx mikro-orm migration:create
npx mikro-orm migration:up
```

MikroORM tự sinh file migration TypeScript từ khai báo Entity (tương đương DDL bên dưới) — dùng migration thay vì chạy tay SQL để có lịch sử thay đổi schema rõ ràng, review được qua PR:

```sql
-- Migration000001.ts sẽ tạo tương đương:
CREATE TABLE business.leave_request (
  id                  BIGSERIAL PRIMARY KEY,
  employee_id         VARCHAR(64) NOT NULL,
  number_of_days      NUMERIC(4,1) NOT NULL,
  start_date          DATE NOT NULL,
  end_date            DATE NOT NULL,
  reason              TEXT,
  status              VARCHAR(32) NOT NULL DEFAULT 'DRAFT',
  process_instance_id VARCHAR(64),
  process_def_key     VARCHAR(64) NOT NULL DEFAULT 'leaveRequestProcess',
  idempotency_key     VARCHAR(128) UNIQUE,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_leave_request_process_instance ON business.leave_request(process_instance_id);

CREATE TABLE business.approval_history_log (
  id            BIGSERIAL PRIMARY KEY,
  business_key  VARCHAR(64) NOT NULL,
  task_id       VARCHAR(64),
  task_name     VARCHAR(255),
  approver_id   VARCHAR(64),
  decision      VARCHAR(32),
  comment       TEXT,
  decided_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

`approval_history_log` được NestJS ghi ngay trong `TaskService.completeTask()` (trước hoặc sau khi gọi Flowable REST) — không phụ thuộc vào History của Flowable, giúp truy vấn/báo cáo nhanh và không bị ảnh hưởng khi Flowable dọn dẹp lịch sử.

> **Production**: không dùng `synchronize`/`schemaGenerator.updateSchema()` của MikroORM ở production — tương tự nguyên tắc "không để ứng dụng tự động cập nhật schema lúc khởi động" áp dụng cho mọi ORM/engine (kể cả Flowable) — luôn chạy `migration:up` qua CI/CD pipeline có kiểm soát.

### 7.6 Ví dụ end-to-end: vòng đời dữ liệu của 1 đơn xin nghỉ phép

Bảng dưới đây theo dõi từng bước xử lý thật của **1 bản ghi cụ thể**, cho thấy rõ dữ liệu nằm ở DB nào tại mỗi thời điểm — minh hoạ trực tiếp cho nguyên tắc tách DB ở mục 7.1.

**Bối cảnh**: `business_db` (NestJS/MikroORM quản lý) và `flowable_db` (Flowable server tự quản lý, NestJS không đụng vào trực tiếp).

| Bước        | Hành động                                                                                                                                       | `business_db` (bảng `leave_request`)                                                                                         | `flowable_db` (Flowable tự ghi, NestJS chỉ thấy qua REST)                                                                                   |
| ----------- | ----------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| 0           | Nhân viên A mở form, bấm "Gửi"                                                                                                                  | _(chưa có gì)_                                                                                                               | _(chưa có gì)_                                                                                                                              |
| 1           | NestJS `submit()`: validate xong, `em.persistAndFlush()` insert bản ghi                                                                         | `id=1024, employee_id='A', status='IN_PROGRESS', process_instance_id=NULL`                                                   | _(chưa có)_                                                                                                                                 |
| 2           | NestJS gọi `flowableClient.startProcessInstance({ businessKey: '1024', variables: {...} })`                                                     | _(chưa đổi)_                                                                                                                 | Tạo `ACT_RU_EXECUTION` mới với `PROC_INST_ID_='9f8e...'`, `BUSINESS_KEY_='1024'`; tạo `ACT_RU_TASK` "Line Manager Approval"                 |
| 3           | NestJS nhận response `{ id: '9f8e...' }`, cập nhật lại entity, `em.flush()`                                                                     | `process_instance_id='9f8e...'`                                                                                              | _(không đổi thêm)_                                                                                                                          |
| 4           | Flowable tạo User Task → chạy `AssignManagerListener` (Java) → gọi `GET /internal/org-chart/A/manager` sang NestJS                              | NestJS chỉ **đọc**, không ghi gì ở bước này                                                                                  | `ACT_RU_TASK.ASSIGNEE_ = 'MANAGER001'`                                                                                                      |
| 5           | Manager mở "My Tasks" trên FE → NestJS gọi `GET /runtime/tasks?assignee=MANAGER001`                                                             | _(không đổi)_                                                                                                                | _(chỉ đọc, không đổi)_                                                                                                                      |
| 6           | Manager bấm "Phê duyệt" → FE gọi `POST /api/v1/tasks/{taskId}/complete`                                                                         | NestJS insert 1 dòng vào `approval_history_log`: `business_key='1024', approver_id='MANAGER001', decision='APPROVE'`         | Flowable `completeTask()`: đóng `ACT_RU_TASK` hiện tại, di chuyển `ACT_RU_EXECUTION` sang gateway rồi tới `finalizeApproval` (Service Task) |
| 7           | `finalizeApprovalDelegate` (Java) chạy → gọi `POST /internal/workflow/leave/finalize { businessKey: '1024', decision: 'APPROVED' }` sang NestJS | NestJS `finalizeByBusinessKey('1024', 'APPROVED')`: `UPDATE leave_request SET status='APPROVED' WHERE id=1024`, `em.flush()` | Process instance tiếp tục chạy tới `endApproved`                                                                                            |
| 8           | Process instance kết thúc                                                                                                                       | _(không đổi thêm)_                                                                                                           | `ACT_RU_EXECUTION` bị xoá (runtime kết thúc), dữ liệu chuyển hẳn sang `ACT_HI_PROCINST` (lịch sử)                                           |
| 9 (định kỳ) | Reconciliation cron chạy mỗi 5 phút, gọi `GET /history/historic-process-instances/9f8e...`                                                      | Nếu vì lý do gì bước 7 bị lỗi/miss, cron tự phát hiện `endTime` đã có → tự set lại `status` cho đúng                         | _(chỉ đọc)_                                                                                                                                 |

#### 7.6.1 Điểm mấu chốt rút ra từ ví dụ

1. **NestJS không bao giờ query trực tiếp bảng `ACT_*` trong `flowable_db`** — mọi thông tin về task/process instance đều lấy qua REST API (`FlowableClientService`), kể cả trong cron reconciliation (bước 9).
2. **`leave_request.process_instance_id`** là "sợi dây" duy nhất nối 2 DB — không phải Foreign Key thật (Postgres không cho FK chéo DB), chỉ là 1 cột string lưu ID tham chiếu.
3. **`approval_history_log`** trong `business_db` là **bản sao độc lập** của lịch sử duyệt — cố tình trùng lặp với `ACT_HI_*` bên Flowable, vì: (a) NestJS cần query nhanh cho màn hình báo cáo mà không phải gọi REST liên tục, (b) nếu sau này Flowable dọn `ACT_HI_*` theo retention policy, dữ liệu audit nghiệp vụ **vẫn còn nguyên** ở `business_db`.
4. **Thứ tự ghi quan trọng**: bước 1 (insert `leave_request`) phải **xong trước** bước 2 (start process) — nếu start process fail giữa chừng, bản ghi vẫn tồn tại ở trạng thái `IN_PROGRESS` với `process_instance_id=NULL`, dễ dò ra và xử lý lại (thay vì mất dấu vết hoàn toàn). Có thể thêm 1 cron riêng quét các bản ghi `IN_PROGRESS` với `process_instance_id IS NULL` quá X phút để cảnh báo/retry.

---

## 8. Bảo mật & phân quyền

### 8.1 Hai lớp xác thực riêng biệt

1. **React → NestJS**: dùng **Supabase Auth** — FE login qua `supabase-js`, nhận `access_token` (JWT do Supabase phát hành), gắn vào header `Authorization: Bearer <token>` khi gọi API NestJS.
2. **NestJS → Flowable REST**: Basic Auth bằng service account nội bộ, **không liên quan gì đến JWT của người dùng cuối** — Flowable server không cần biết user thật là ai, chỉ NestJS biết và kiểm tra quyền trước khi gọi.

#### 8.1.1 Xác thực JWT của Supabase ở NestJS

Supabase phát hành JWT ký bằng **JWT Secret** của project (HS256) — với project mới hơn cũng có thể dùng **JWKS/RS256** (Supabase gọi là "asymmetric JWT signing keys"). Kiểm tra trong Supabase Dashboard → **Project Settings → API → JWT Settings** xem project đang dùng kiểu nào để chọn cách verify tương ứng.

**Cách 1 — Verify cục bộ bằng JWT Secret (HS256, phổ biến nhất, nhanh, không cần gọi ra ngoài):**

```bash
npm install @nestjs/passport passport passport-jwt @nestjs/jwt
```

```typescript
// auth/supabase-jwt.strategy.ts
import { ExtractJwt, Strategy } from "passport-jwt";
import { PassportStrategy } from "@nestjs/passport";
import { Injectable } from "@nestjs/common";

@Injectable()
export class SupabaseJwtStrategy extends PassportStrategy(Strategy, "supabase-jwt") {
  constructor() {
    super({
      jwtFromRequest: ExtractJwt.fromAuthHeaderAsBearerToken(),
      ignoreExpiration: false,
      secretOrKey: process.env.SUPABASE_JWT_SECRET, // lấy trong Dashboard → Settings → API
      audience: "authenticated",
      issuer: `${process.env.SUPABASE_URL}/auth/v1`,
    });
  }

  async validate(payload: any) {
    // payload chuẩn của Supabase gồm: sub (userId), email, role, app_metadata, user_metadata, exp...
    return {
      userId: payload.sub,
      email: payload.email,
      role: payload.role, // role hệ thống Supabase (thường là "authenticated")
      appMetadata: payload.app_metadata ?? {}, // nơi lưu role/group nghiệp vụ — xem 8.1.2
      userMetadata: payload.user_metadata ?? {},
    };
  }
}
```

```typescript
// auth/jwt-auth.guard.ts
@Injectable()
export class JwtAuthGuard extends AuthGuard("supabase-jwt") {}
```

```typescript
// leave-request.controller.ts
@Controller("api/v1/leave-requests")
@UseGuards(JwtAuthGuard)
export class LeaveRequestController {
  @Post()
  submit(@CurrentUser() user: SupabaseUser, @Body() dto: CreateLeaveRequestDto) {
    return this.leaveRequestService.submit(dto, user.userId);
  }
}
```

**Cách 2 — Verify qua Supabase Admin API (chậm hơn, nhưng luôn đúng kể cả khi user bị revoke/ban ngay lập tức):**

```typescript
import { createClient } from "@supabase/supabase-js";

const supabaseAdmin = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_ROLE_KEY // service role key — chỉ dùng ở BE, tuyệt đối không lộ ra FE
);

async function verifyToken(token: string) {
  const { data, error } = await supabaseAdmin.auth.getUser(token);
  if (error) throw new UnauthorizedException("Token không hợp lệ");
  return data.user;
}
```

> **Khuyến nghị**: dùng **Cách 1** (verify cục bộ) làm mặc định cho mọi request thông thường vì nhanh, không tốn round-trip tới Supabase; chỉ dùng **Cách 2** cho các thao tác nhạy cảm cần chắc chắn token chưa bị revoke (VD: duyệt khoản thanh toán giá trị lớn).

#### 8.1.2 Map role/group nghiệp vụ (candidateGroups) từ Supabase

Supabase không có khái niệm "group" dựng sẵn như Keycloak — có 2 cách phổ biến để đưa role/group nghiệp vụ (VD: `hr-approvers`, `manager`) vào hệ thống:

**Cách A — Lưu trong `app_metadata` của user (đơn giản, đọc thẳng từ JWT, không cần query thêm):**

```sql
-- Chạy 1 lần (hoặc qua Supabase Admin API) để gán role cho user
update auth.users
set raw_app_meta_data = raw_app_meta_data || '{"roles": ["manager", "hr-approvers"]}'
where id = '<user-uuid>';
```

`app_metadata` tự động có trong JWT payload (`payload.app_metadata.roles`), NestJS đọc thẳng, không cần gọi thêm DB:

```typescript
const userGroups: string[] = user.appMetadata.roles ?? [];
```

**Cách B — Bảng riêng trong Postgres (khi cần quản lý role phức tạp/thay đổi thường xuyên qua UI admin), NestJS query khi cần:**

```sql
create table public.user_roles (
  user_id uuid primary key references auth.users(id),
  roles   text[] not null default '{}'
);
```

```typescript
async getUserGroups(userId: string): Promise<string[]> {
  const { data } = await this.supabaseAdmin
    .from('user_roles')
    .select('roles')
    .eq('user_id', userId)
    .single();
  return data?.roles ?? [];
}
```

> **Khuyến nghị**: dùng **Cách A** (`app_metadata`) làm mặc định vì tránh round-trip DB cho mỗi request — chỉ chuyển sang Cách B khi role thay đổi rất thường xuyên và cần cập nhật hiệu lực ngay (vì `app_metadata` chỉ cập nhật vào JWT ở lần refresh token tiếp theo, có độ trễ bằng thời gian sống của access token — mặc định Supabase là 1 giờ). Nếu cần cả hai ưu điểm (nhanh + cập nhật tức thời), Supabase hỗ trợ **Custom Access Token Hook** (Postgres function chạy mỗi khi phát hành token) để tự nhúng role mới nhất từ bảng `user_roles` vào JWT ngay lúc issue — cấu hình tại Dashboard → Authentication → Hooks.

### 8.2 Kiểm tra quyền xử lý task — bắt buộc ở tầng NestJS

```typescript
async completeTask(taskId: string, userId: string, userGroups: string[], decision: ApprovalDecisionDto) {
  const task = await this.flowableClient.getTaskById(taskId);

  const isAssignee = task.assignee === userId;
  const isCandidate = task.candidateGroups?.some((g: string) => userGroups.includes(g));

  if (!isAssignee && !isCandidate) {
    throw new ForbiddenException('Bạn không có quyền xử lý task này');
  }

  if (!task.assignee) {
    await this.flowableClient.claimTask(taskId, userId); // tự claim nếu đang là candidate
  }

  await this.flowableClient.completeTask(taskId, {
    decision: decision.decision, // dùng chung tên biến 'decision' cho mọi bước duyệt (xem BPMN mục 4.2) — Flowable ghi đè giá trị mỗi lần task hoàn thành
    comment: decision.comment,
  });

  const log = this.historyLogRepo.create({
    businessKey: task.businessKey,
    taskId,
    taskName: task.name,
    approverId: userId,
    decision: decision.decision,
    comment: decision.comment,
  });
  await this.em.persistAndFlush(log);
}
```

```typescript
// task.controller.ts — lấy userGroups từ payload JWT đã decode ở strategy
@Post(':taskId/complete')
@UseGuards(JwtAuthGuard)
completeTask(
  @Param('taskId') taskId: string,
  @CurrentUser() user: SupabaseUser,
  @Body() decision: ApprovalDecisionDto,
) {
  return this.taskService.completeTask(taskId, user.userId, user.appMetadata.roles ?? [], decision);
}
```

> `userGroups` lấy từ `app_metadata.roles` trong JWT của Supabase, **map trực tiếp sang `candidateGroups`** dùng trong BPMN — không dùng Identity Service nội bộ của Flowable (`ACT_ID_*`) làm nguồn sự thật về user/group.

### 8.3 Bảo vệ endpoint callback nội bộ

- `InternalAuthGuard` kiểm tra header bí mật (mục 5.4).
- Bổ sung: giới hạn route `/internal/*` chỉ chấp nhận request từ dải IP nội bộ của Flowable server (Nginx/K8s NetworkPolicy), phòng trường hợp secret bị lộ.

---

## 9. Frontend React — tích hợp qua NestJS

FE dùng **`supabase-js`** cho việc đăng nhập/lấy token, còn lại vẫn chỉ gọi API của NestJS — không biết gì về Flowable REST.

### 9.1 Đăng nhập & đính kèm access_token vào mọi request

```typescript
// lib/supabaseClient.ts
import { createClient } from "@supabase/supabase-js";

export const supabase = createClient(
  import.meta.env.VITE_SUPABASE_URL,
  import.meta.env.VITE_SUPABASE_ANON_KEY // anon/public key — an toàn để lộ ở FE
);
```

```typescript
// lib/httpClient.ts
import axios from "axios";
import { supabase } from "./supabaseClient";

export const axiosClient = axios.create({ baseURL: import.meta.env.VITE_API_BASE_URL });

axiosClient.interceptors.request.use(async (config) => {
  const { data } = await supabase.auth.getSession();
  const accessToken = data.session?.access_token;
  if (accessToken) {
    config.headers.Authorization = `Bearer ${accessToken}`;
  }
  return config;
});

// Tự refresh & retry khi access_token hết hạn (Supabase tự refresh session ở tầng client)
supabase.auth.onAuthStateChange((_event, session) => {
  if (!session) {
    window.location.href = "/login";
  }
});
```

```tsx
// features/auth/LoginForm.tsx
async function handleLogin(email: string, password: string) {
  const { data, error } = await supabase.auth.signInWithPassword({ email, password });
  if (error) {
    toast.error("Sai email hoặc mật khẩu");
    return;
  }
  navigate("/tasks");
}
```

> `supabase-js` tự lưu session vào `localStorage` và tự refresh `access_token` trước khi hết hạn — FE không cần tự viết logic refresh token thủ công như với JWT tuỳ chỉnh.

### 9.2 Gọi API nghiệp vụ (NestJS)

```typescript
// api/taskApi.ts
export const taskApi = {
  getMyTasks: (page: number, size: number) => axiosClient.get("/api/v1/tasks/my-tasks", { params: { page, size } }),

  completeTask: (taskId: string, decision: ApprovalDecisionDto) =>
    axiosClient.post(`/api/v1/tasks/${taskId}/complete`, decision),
};
```

```tsx
function ApprovalActionButtons({ taskId }: { taskId: string }) {
  const { mutate, isPending } = useMutation({
    mutationFn: (decision: ApprovalDecisionDto) => taskApi.completeTask(taskId, decision),
    onError: (err: AxiosError) => {
      if (err.response?.status === 409) {
        toast.error("Task đã được xử lý trước đó, vui lòng tải lại danh sách");
      }
    },
  });

  return (
    <Button disabled={isPending} onClick={() => mutate({ decision: "APPROVE", comment })}>
      Phê duyệt
    </Button>
  );
}
```

- NestJS trả lỗi `409 Conflict` khi `completeTask` thất bại vì task đã bị người khác xử lý (Flowable REST trả lỗi tương tự khi task không còn active — NestJS bắt và map lại thành 409 cho FE).
- Polling `refetchInterval` 20–30s cho danh sách task để cập nhật khi bị người khác claim.

---

## 10. Xử lý lỗi, retry, idempotency

### 10.1 Idempotency khi start process

- FE gửi kèm `Idempotency-Key` (UUID sinh ở client khi mở form) trong header.
- NestJS lưu key này cùng bản ghi `leave_request` (unique constraint) — nếu request lặp lại (double click, retry mạng), trả về bản ghi cũ thay vì start process 2 lần.

```typescript
@Post()
async submit(@Headers('Idempotency-Key') idemKey: string, @Body() dto: CreateLeaveRequestDto) {
  const existing = await this.leaveRequestRepo.findOne({ idempotencyKey: idemKey });
  if (existing) return existing;
  return this.leaveRequestService.submit(dto, idemKey);
}
```

### 10.2 Xử lý khi callback JavaDelegate lỗi (process instance bị treo ở Service Task)

- Theo dõi định kỳ: `GET /management/jobs?withException=true` (job lỗi còn retry) và `GET /management/deadletter-jobs` (hết retry).
- Có endpoint admin nội bộ trong NestJS để: xem danh sách job lỗi, xem lý do (`GET /management/jobs/{id}/exception-stacktrace`), và **retry thủ công** (`POST /management/jobs/{id}` với action `execute`, hoặc move từ deadletter về job queue).
- Alert (Slack/Email) ngay khi có deadletter job mới — đây là dấu hiệu process nghiệp vụ đang "treo" thật sự.

### 10.3 Timeout khi NestJS gọi Flowable REST

- Đặt timeout hợp lý (VD: 5s) cho `HttpService`, kèm retry có giới hạn (2–3 lần) cho GET (idempotent), **không tự ý retry POST start-process/complete-task** để tránh tạo trùng — thay vào đó dựa vào Idempotency-Key (10.1) hoặc kiểm tra trạng thái trước khi gọi lại.

---

## 11. Testing

### 11.1 NestJS — test integration với Flowable thật (docker-compose môi trường test)

```yaml
# docker-compose.test.yml
services:
  flowable-test:
    image: flowable/flowable-rest:latest
    ports: ["8090:8080"]
    environment:
      - SPRING_DATASOURCE_URL=jdbc:postgresql://postgres-test:5432/flowable_test
  postgres-test:
    image: postgres:15
    environment:
      POSTGRES_DB: flowable_test
```

```typescript
describe("LeaveRequestService (integration)", () => {
  it("should start process and create first task assigned to manager", async () => {
    const result = await leaveRequestService.submit(dto, "EMP001");
    expect(result.processInstanceId).toBeDefined();

    const tasks = await flowableClient.getTasksByAssignee("MANAGER001");
    expect(tasks.data[0].processInstanceId).toBe(result.processInstanceId);
  });
});
```

### 11.2 Test callback controller (mô phỏng Flowable gọi ngược)

```typescript
it("should reject callback without valid internal token", async () => {
  await request(app.getHttpServer())
    .post("/internal/workflow/leave/finalize")
    .send({ businessKey: "1", decision: "APPROVED" })
    .expect(403); // thiếu header X-Internal-Auth
});
```

### 11.3 Load test

- k6: mô phỏng N user start process đồng thời + M user complete task đồng thời, theo dõi latency NestJS↔Flowable REST và số lượng job pending/deadletter phát sinh.

---

## 12. Triển khai production (Docker/Kubernetes)

### 12.1 Các thành phần cần khai báo trong Helm/K8s

```yaml
# Chỉ phần liên quan tới việc NestJS gọi Flowable server đã có sẵn
apiVersion: v1
kind: Secret
metadata: { name: flowable-service-account }
stringData:
  FLOWABLE_SVC_USER: svc-nestjs-approval
  FLOWABLE_SVC_PASSWORD: ${VAULT_INJECTED}
  INTERNAL_SERVICE_TOKEN: ${VAULT_INJECTED}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: allow-nestjs-to-flowable }
spec:
  podSelector: { matchLabels: { app: flowable-server } }
  ingress:
    - from:
        - podSelector: { matchLabels: { app: nestjs-approval } }
      ports: [{ port: 8080 }]
```

- Đảm bảo `nestjs-approval` và `flowable-server` (đã có sẵn) nằm cùng namespace hoặc có NetworkPolicy/Service DNS trỏ đúng.
- Nếu Flowable server nằm ở hạ tầng khác (on-prem, VPC khác), cần VPN/Peering + xác nhận độ trễ mạng (ảnh hưởng trực tiếp tới latency mọi JavaDelegate/Service Task gọi ngược NestJS).

### 12.2 Health check phụ thuộc

NestJS nên có endpoint `/health` kiểm tra luôn kết nối tới Flowable REST (VD: gọi `GET /repository/process-definitions?size=1`), để readiness probe phản ánh đúng tình trạng phụ thuộc:

```typescript
@Get('health')
async health() {
  try {
    await this.flowableClient.ping();
    return { status: 'ok', flowable: 'reachable' };
  } catch {
    throw new ServiceUnavailableException('Không kết nối được Flowable server');
  }
}
```

---

## 13. Checklist production-readiness

- [ ] Đã xác nhận version + endpoint REST API chính xác của Flowable server đang dùng (đối chiếu OpenAPI/docs thực tế).
- [ ] DB nghiệp vụ (NestJS/MikroORM) tách riêng khỏi DB của Flowable (instance/database/schema riêng — xem mục 7.1), NestJS không có quyền ghi trực tiếp vào bảng `ACT_*`.
- [ ] Tạo service account riêng cho NestJS gọi Flowable (không dùng tài khoản admin).
- [ ] `SUPABASE_JWT_SECRET`/`SUPABASE_SERVICE_ROLE_KEY` chỉ để ở BE (NestJS), không lộ ra FE — FE chỉ dùng `anon key`.
- [ ] Đã xác nhận project Supabase dùng HS256 hay RS256/JWKS để cấu hình `SupabaseJwtStrategy` đúng cách.
- [ ] Role/group nghiệp vụ (`app_metadata.roles`) đã đồng bộ đúng cho toàn bộ user hiện có trước khi go-live.
- [ ] Flowable REST endpoint không public ra internet, chỉ NestJS gọi qua network nội bộ.
- [ ] Mọi JavaDelegate/TaskListener chỉ gọi ngược NestJS lấy business logic, **không tự viết logic nghiệp vụ trong Java** (đưa vào code review checklist).
- [ ] Service Task gọi ra ngoài đều đặt `flowable:async="true"` + timeout ngắn cho WebClient, tránh giữ transaction/job lâu.
- [ ] Có cơ chế Idempotency-Key chống double start-process từ FE.
- [ ] Có job giám sát `deadletter-jobs`/`jobs?withException=true` + alert.
- [ ] Có endpoint reconciliation (cron) đối chiếu trạng thái History API với DB nghiệp vụ.
- [ ] Kiểm tra quyền xử lý task ở tầng NestJS (`assignee`/`candidateGroups`) trước khi gọi complete, không tin dữ liệu từ FE.
- [ ] Endpoint `/internal/workflow/*`, `/internal/org-chart/*` trên NestJS được bảo vệ bằng token nội bộ + giới hạn nguồn gọi.
- [ ] FE xử lý lỗi 409 khi task đã được xử lý bởi người khác.
- [ ] Đã load test với kịch bản tải đỉnh thực tế, theo dõi độ trễ Java (Flowable) ↔ NestJS qua network nội bộ.
- [ ] Backup PostgreSQL của Flowable server được xác nhận có và test restore định kỳ.
- [ ] Có pipeline build/deploy riêng cho Java project của Flowable server (tách khỏi pipeline NestJS), kèm quy trình review khi thêm/sửa Delegate.

---

_Ghi chú_: Vì team build được Java cho server Flowable, JavaDelegate/TaskListener là lựa chọn chính trong tài liệu này — gọn hơn, dễ test hơn HTTP Task cấu hình bằng XML. Nguyên tắc quan trọng nhất cần giữ kỷ luật khi làm theo hướng này: **JavaDelegate không bao giờ chứa business logic thật**, nó chỉ gọi vào NestJS. Nếu về sau một lập trình viên Java tiện tay viết thêm logic tính toán trực tiếp trong delegate (thay vì gọi NestJS), hệ thống sẽ dần có 2 nguồn sự thật về nghiệp vụ — nên đưa quy tắc này vào code review checklist.
