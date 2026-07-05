package com.company.flowableserver.listener;

import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.flowable.engine.delegate.TaskListener;
import org.flowable.task.service.delegate.DelegateTask;
import org.springframework.stereotype.Component;
import org.springframework.web.reactive.function.client.WebClient;

import java.time.Duration;

/**
 * TaskListener: gán assignee động cho User Task "lineManagerApproval".
 *
 * Chạy tại event="create" ngay khi task được khởi tạo.
 * Gọi NestJS để lấy managerId theo employeeId từ org chart — giữ nguồn sự thật
 * duy nhất ở NestJS, không cần duplicate logic tra cứu org chart ở Java.
 *
 * Dùng trong BPMN:
 *   <flowable:taskListener event="create" delegateExpression="${assignManagerListener}"/>
 */
@Slf4j
@Component("assignManagerListener")
@RequiredArgsConstructor
public class AssignManagerListener implements TaskListener {

    private final WebClient nestjsClient;

    @Override
    public void notify(DelegateTask delegateTask) {
        String employeeId = (String) delegateTask.getVariable("employeeId");

        log.info("AssignManagerListener: resolving manager for employeeId={}", employeeId);

        String managerId = nestjsClient.get()
                .uri("/internal/org-chart/{employeeId}/manager", employeeId)
                .header("X-Internal-Auth", internalServiceToken())
                .retrieve()
                .bodyToMono(String.class)
                .block(Duration.ofSeconds(5));

        if (managerId == null || managerId.isBlank()) {
            log.error("AssignManagerListener: no manager found for employeeId={}", employeeId);
            throw new IllegalStateException("Không tìm được manager cho employeeId: " + employeeId);
        }

        delegateTask.setAssignee(managerId);
        log.info("AssignManagerListener: task={} assigned to managerId={}", delegateTask.getId(), managerId);
    }

    private String internalServiceToken() {
        return System.getenv("INTERNAL_SERVICE_TOKEN");
    }
}
