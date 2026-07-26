package com.company.flowableserver.config;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.ansi.AnsiColor;
import org.springframework.boot.ansi.AnsiOutput;
import org.springframework.core.Ordered;
import org.springframework.core.annotation.Order;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;

/**
 * Logs every incoming HTTP request/response, similar to Nest.js's built-in
 * request logger: method, path, status code and response time.
 */
@Component
@Order(Ordered.HIGHEST_PRECEDENCE)
public class RequestLoggingFilter extends OncePerRequestFilter {

    private static final Logger log = LoggerFactory.getLogger("HTTP");

    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response, FilterChain filterChain)
            throws ServletException, IOException {
        long startTime = System.currentTimeMillis();
        try {
            filterChain.doFilter(request, response);
        } finally {
            long duration = System.currentTimeMillis() - startTime;
            String query = request.getQueryString();
            String path = query != null ? request.getRequestURI() + "?" + query : request.getRequestURI();
            int status = response.getStatus();
            log.info("{} {} {} {} {}",
                    colorize(clientIp(request), AnsiColor.MAGENTA),
                    colorize(request.getMethod(), methodColor(request.getMethod())),
                    path,
                    colorize(String.valueOf(status), statusColor(status)),
                    colorize(duration + "ms", durationColor(duration)));
        }
    }

    private static String clientIp(HttpServletRequest request) {
        String forwardedFor = request.getHeader("X-Forwarded-For");
        if (forwardedFor != null && !forwardedFor.isBlank()) {
            return forwardedFor.split(",")[0].trim();
        }
        String realIp = request.getHeader("X-Real-IP");
        if (realIp != null && !realIp.isBlank()) {
            return realIp;
        }
        return request.getRemoteAddr();
    }

    private static String colorize(String text, AnsiColor color) {
        return AnsiOutput.toString(color, text, AnsiColor.DEFAULT);
    }

    private static AnsiColor methodColor(String method) {
        return switch (method) {
            case "GET" -> AnsiColor.GREEN;
            case "POST" -> AnsiColor.YELLOW;
            case "PUT", "PATCH" -> AnsiColor.BLUE;
            case "DELETE" -> AnsiColor.RED;
            default -> AnsiColor.DEFAULT;
        };
    }

    private static AnsiColor statusColor(int status) {
        if (status >= 500) return AnsiColor.RED;
        if (status >= 400) return AnsiColor.YELLOW;
        if (status >= 300) return AnsiColor.CYAN;
        return AnsiColor.GREEN;
    }

    private static AnsiColor durationColor(long duration) {
        if (duration >= 1000) return AnsiColor.RED;
        if (duration >= 300) return AnsiColor.YELLOW;
        return AnsiColor.GREEN;
    }
}
