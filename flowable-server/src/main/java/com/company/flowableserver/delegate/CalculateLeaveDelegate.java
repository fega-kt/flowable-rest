package com.company.flowableserver.delegate;

import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.flowable.engine.delegate.BpmnError;
import org.flowable.engine.delegate.DelegateExecution;
import org.flowable.engine.delegate.JavaDelegate;
import org.springframework.stereotype.Component;
import org.springframework.web.reactive.function.client.WebClient;

import java.time.Duration;

/**
 * Service Task tuỳ chọn: kiểm tra số ngày phép còn lại trước khi bắt đầu luồng duyệt.
 *
 * NestJS đã validate trước khi start process (mục 5.3 docs) — delegate này đóng vai trò
 * lớp bảo vệ thứ hai bên trong BPMN. Ném BpmnError("INSUFFICIENT_LEAVE_BALANCE")
 * nếu không đủ ngày phép để BPMN có thể xử lý nhánh lỗi riêng.
 *
 * Dùng trong BPMN: flowable:delegateExpression="${calculateLeaveDelegate}"
 */
@Slf4j
@Component("calculateLeaveDelegate")
@RequiredArgsConstructor
public class CalculateLeaveDelegate implements JavaDelegate {

    private final WebClient nestjsClient;

    @Override
    public void execute(DelegateExecution execution) {
        String employeeId = (String) execution.getVariable("employeeId");
        Number numberOfDaysRaw = (Number) execution.getVariable("numberOfDays");
        int requestedDays = numberOfDaysRaw != null ? numberOfDaysRaw.intValue() : 0;

        log.info("CalculateLeaveDelegate: employeeId={}, requestedDays={}", employeeId, requestedDays);

        Integer remaining = nestjsClient.get()
                .uri("/internal/hrm/{employeeId}/remaining-leave-days", employeeId)
                .header("X-Internal-Auth", internalServiceToken())
                .retrieve()
                .bodyToMono(Integer.class)
                .block(Duration.ofSeconds(5));

        if (remaining == null || remaining < requestedDays) {
            log.warn("Insufficient leave balance: employeeId={}, remaining={}, requested={}",
                    employeeId, remaining, requestedDays);
            throw new BpmnError("INSUFFICIENT_LEAVE_BALANCE",
                    "Số ngày phép còn lại không đủ: còn " + remaining + " ngày, yêu cầu " + requestedDays + " ngày");
        }

        execution.setVariable("remainingLeaveDays", remaining);
        log.info("CalculateLeaveDelegate: employeeId={}, remaining={} days — OK", employeeId, remaining);
    }

    private String internalServiceToken() {
        return System.getenv("INTERNAL_SERVICE_TOKEN");
    }
}
