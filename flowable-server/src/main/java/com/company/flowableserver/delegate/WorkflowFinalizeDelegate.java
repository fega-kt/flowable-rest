package com.company.flowableserver.delegate;

import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.flowable.engine.delegate.BpmnError;
import org.flowable.engine.delegate.DelegateExecution;
import org.flowable.engine.delegate.JavaDelegate;
import org.springframework.http.HttpStatusCode;
import org.springframework.stereotype.Component;
import org.springframework.web.reactive.function.client.WebClient;
import reactor.core.publisher.Mono;

import java.time.Duration;
import java.util.Map;

/**
 * Service Task: "Workflow finalize" — generic version of FinalizeApprovalDelegate, dùng cho MỌI
 * quy trình sinh động từ workflow-setting (không gắn với 1 loại nghiệp vụ cụ thể như leave request).
 *
 * Chỉ gọi ngược NestJS để đóng trạng thái workflow instance (Approved/Rejected/Returned).
 * Không tự thực hiện logic nghiệp vụ nào ở đây.
 *
 * Dùng trong BPMN: flowable:delegateExpression="${workflowFinalizeDelegate}"
 * Đặt flowable:async="true" trên Service Task để tách khỏi transaction chính.
 */
@Slf4j
@Component("workflowFinalizeDelegate")
@RequiredArgsConstructor
public class WorkflowFinalizeDelegate implements JavaDelegate {

    private final WebClient nestjsClient;

    @Override
    public void execute(DelegateExecution execution) {
        String businessKey = execution.getProcessInstanceBusinessKey();
        String decision = (String) execution.getVariable("decision");

        log.info("WorkflowFinalizeDelegate: businessKey={}, decision={}", businessKey, decision);

        Map<String, Object> body = Map.of(
                "businessKey", businessKey,
                "decision", decision != null ? decision : "APPROVE"
        );

        nestjsClient.post()
                .uri("/internal/workflow/finalize")
                .header("X-Internal-Auth", internalServiceToken())
                .bodyValue(body)
                .retrieve()
                .onStatus(HttpStatusCode::isError, response ->
                        response.bodyToMono(String.class).flatMap(errorBody -> {
                            log.error("NestJS finalize failed: status={}, body={}", response.statusCode(), errorBody);
                            return Mono.error(new BpmnError("NESTJS_CALL_FAILED",
                                    "Gọi NestJS /internal/workflow/finalize thất bại: " + errorBody));
                        })
                )
                .toBodilessEntity()
                .block(Duration.ofSeconds(5));

        log.info("WorkflowFinalizeDelegate: completed for businessKey={}", businessKey);
    }

    private String internalServiceToken() {
        return System.getenv("INTERNAL_SERVICE_TOKEN");
    }
}
