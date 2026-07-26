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
 * Service Task: "Notify escalation" — chạy khi Timer Boundary Event trên
 * lineManagerApproval hết thời gian (mặc định PT24H).
 *
 * Gọi NestJS để NestJS xử lý: gửi email leo thang, ghi log, v.v.
 *
 * Dùng trong BPMN: flowable:delegateExpression="${escalationDelegate}"
 * Đặt flowable:async="true" để tách khỏi transaction timer.
 */
@Slf4j
@Component("escalationDelegate")
@RequiredArgsConstructor
public class EscalationDelegate implements JavaDelegate {

    private final WebClient nestjsClient;

    @Override
    public void execute(DelegateExecution execution) {
        String processInstanceId = execution.getProcessInstanceId();
        String businessKey = execution.getProcessInstanceBusinessKey();
        String employeeId = (String) execution.getVariable("employeeId");

        log.info("EscalationDelegate: processInstanceId={}, employeeId={}", processInstanceId, employeeId);

        Map<String, Object> body = Map.of(
                "processInstanceId", processInstanceId,
                "businessKey", businessKey != null ? businessKey : "",
                "employeeId", employeeId != null ? employeeId : ""
        );

        nestjsClient.post()
                .uri("/internal/workflow/escalate")
                .header("X-Internal-Auth", internalServiceToken())
                .bodyValue(body)
                .retrieve()
                .onStatus(HttpStatusCode::isError, response ->
                        response.bodyToMono(String.class).flatMap(errorBody -> {
                            log.error("NestJS escalate failed: status={}, body={}", response.statusCode(), errorBody);
                            return Mono.error(new BpmnError("NESTJS_CALL_FAILED",
                                    "Gọi NestJS /internal/workflow/escalate thất bại: " + errorBody));
                        })
                )
                .toBodilessEntity()
                .block(Duration.ofSeconds(5));

        log.info("EscalationDelegate: completed for processInstanceId={}", processInstanceId);
    }

    private String internalServiceToken() {
        return System.getenv("INTERNAL_SERVICE_TOKEN");
    }
}
