package com.devsecops.userapi.filter;

import jakarta.servlet.Filter;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.ServletRequest;
import jakarta.servlet.ServletResponse;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.core.annotation.Order;
import org.springframework.stereotype.Component;

import java.io.IOException;

/**
 * Servlet filter that adds explicit Cache-Control directives to every HTTP
 * response.
 *
 * Without these headers, RFC 7234-compliant caching proxies may store
 * responses and serve them to other users, which is the root cause of the
 * ZAP "Storable and Cacheable Content" (CWE-524) finding.
 *
 * Headers set:
 *   Cache-Control: no-cache, no-store, must-revalidate, private
 *   Pragma:        no-cache          (HTTP/1.0 compat)
 *   Expires:       0                 (HTTP/1.0 compat)
 */
@Component
@Order(1)
public class NoCacheFilter implements Filter {

    @Override
    public void doFilter(ServletRequest request,
                         ServletResponse response,
                         FilterChain chain) throws IOException, ServletException {

        HttpServletResponse httpResponse = (HttpServletResponse) response;

        // HTTP/1.1 – instruct caches not to store or reuse this response
        httpResponse.setHeader("Cache-Control",
                "no-cache, no-store, must-revalidate, private");

        // HTTP/1.0 backward-compat
        httpResponse.setHeader("Pragma", "no-cache");

        // HTTP/1.0 backward-compat: force expiry immediately
        httpResponse.setDateHeader("Expires", 0);

        chain.doFilter(request, response);
    }
}
