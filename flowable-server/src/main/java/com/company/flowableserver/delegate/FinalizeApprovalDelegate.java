package com.company.flowableserver.delegate;

import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.flowable.common.engine.api.delegate.Expression;
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
 * Service Task: "Finalize approval" — chạy khi quyết định cuối cùng đã có.
 *
 * Chỉ gọi ngược NestJS để NestJS cập nhật trạng thái đơn nghiệp vụ,
 * gửi email, cập nhật HRM, v.v. Không tự thực hiện logic nghiệp vụ nào ở đây.
 *
 * Dùng trong BPMN: flowable:delegateExpression="${finalizeApprovalDelegate}"
 * Đặt flowable:async="true" trên Service Task để tách khỏi transaction chính.
 */
@Slf4j
@Component("finalizeApprovalDelegate")
@RequiredArgsConstructor
public class FinalizeApprovalDelegate implements JavaDelegate {

    private final WebClient nestjsClient;

    @Override
    public void execute(DelegateExecution execution) {
        String businessKey = execution.getProcessInstanceBusinessKey();
        String decision = (String) execution.getVariable("decision");

        log.info("FinalizeApprovalDelegate: businessKey={}, decision={}", businessKey, decision);

        Map<String, Object> body = Map.of(
                "businessKey", businessKey,
                "decision", decision != null ? decision : "APPROVED"
        );

        nestjsClient.post()
                .uri("/internal/workflow/leave/finalize")
                .header("X-Internal-Auth", internalServiceToken())
                .bodyValue(body)
                .retrieve()
                .onStatus(HttpStatusCode::isError, response ->
                        response.bodyToMono(String.class).flatMap(errorBody -> {
                            log.error("NestJS finalize failed: status={}, body={}", response.statusCode(), errorBody);
                            return Mono.error(new BpmnError("NESTJS_CALL_FAILED",
                                    "Gọi NestJS /internal/workflow/leave/finalize thất bại: " + errorBody));
                        })
                )
                .toBodilessEntity()
                .block(Duration.ofSeconds(5));

        log.info("FinalizeApprovalDelegate: completed for businessKey={}", businessKey);
    }

    private String internalServiceToken() {
        return System.getenv("INTERNAL_SERVICE_TOKEN");
    }
}
