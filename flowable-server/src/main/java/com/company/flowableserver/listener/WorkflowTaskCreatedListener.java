package com.company.flowableserver.listener;

import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.flowable.engine.delegate.TaskListener;
import org.flowable.task.service.delegate.DelegateTask;
import org.springframework.http.HttpStatusCode;
import org.springframework.stereotype.Component;
import org.springframework.web.reactive.function.client.WebClient;
import reactor.core.publisher.Mono;

import java.time.Duration;
import java.util.Map;

/**
 * TaskListener: thông báo cho NestJS ngay khi 1 User Task được tạo — generic, dùng cho MỌI quy
 * trình sinh từ workflow-setting (khác với AssignManagerListener chỉ dành riêng cho leave request).
 *
 * Chạy tại event="create". Chỉ để NestJS mirror task ngay lập tức (real-time), không quyết định gì
 * về nghiệp vụ — nếu gọi NestJS lỗi, KHÔNG chặn việc tạo task trong Flowable (chỉ log cảnh báo),
 * vì NestJS còn có cơ chế polling đồng bộ lại sau mỗi action làm phương án dự phòng.
 *
 * Dùng trong BPMN:
 *   <flowable:taskListener event="create" delegateExpression="${workflowTaskCreatedListener}"/>
 */
@Slf4j
@Component("workflowTaskCreatedListener")
@RequiredArgsConstructor
public class WorkflowTaskCreatedListener implements TaskListener {

    private final WebClient nestjsClient;

    @Override
    public void notify(DelegateTask delegateTask) {
        String processInstanceId = delegateTask.getProcessInstanceId();
        String taskId = delegateTask.getId();
        String taskDefinitionKey = delegateTask.getTaskDefinitionKey();
        String assignee = delegateTask.getAssignee();

        Map<String, Object> body = Map.of(
                "processInstanceId", processInstanceId != null ? processInstanceId : "",
                "taskId", taskId,
                "taskDefinitionKey", taskDefinitionKey != null ? taskDefinitionKey : "",
                "assignee", assignee != null ? assignee : ""
        );

        try {
            nestjsClient.post()
                    .uri("/internal/workflow/task-created")
                    .header("X-Internal-Auth", internalServiceToken())
                    .bodyValue(body)
                    .retrieve()
                    .onStatus(HttpStatusCode::isError, response ->
                            response.bodyToMono(String.class).flatMap(errorBody -> {
                                log.warn("NestJS task-created notify failed: status={}, body={}", response.statusCode(), errorBody);
                                return Mono.empty();
                            })
                    )
                    .toBodilessEntity()
                    .block(Duration.ofSeconds(3));
        } catch (Exception ex) {
            // Best-effort — the polling fallback (syncTasksFromFlowable) will pick this task up later.
            log.warn("WorkflowTaskCreatedListener: failed to notify NestJS for task={}: {}", taskId, ex.getMessage());
        }
    }

    private String internalServiceToken() {
        return System.getenv("INTERNAL_SERVICE_TOKEN");
    }
}
