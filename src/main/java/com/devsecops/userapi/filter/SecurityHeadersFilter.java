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
 * Servlet filter that injects all required HTTP security response headers
 * on every response, regardless of route or content type.
 *
 * Headers and the ZAP/CWE findings they resolve:
 *
 *  Cache-Control / Pragma / Expires
 *    → ZAP 10049 "Storable and Cacheable Content" (CWE-524)
 *      Prevents RFC 7234 proxy caches from storing and re-serving responses.
 *
 *  X-Content-Type-Options: nosniff
 *    → ZAP 10021 "X-Content-Type-Options Header Missing" (CWE-693 / WASC-15)
 *      Blocks browsers from MIME-sniffing a response away from its declared
 *      Content-Type, mitigating drive-by download and content-injection risks.
 *
 *  Cross-Origin-Resource-Policy: same-origin
 *    → ZAP 90004 "Cross-Origin-Resource-Policy Header Missing" (CWE-693)
 *      Opts the resource out of cross-origin inclusion, countering Spectre-
 *      class side-channel attacks that leak pixel/timing data across origins.
 *
 *  Cross-Origin-Opener-Policy: same-origin
 *    → ZAP 90004 "Cross-Origin-Opener-Policy Header Missing" (CWE-693)
 *      Isolates the browsing context so that cross-origin documents cannot
 *      obtain a reference to this window, preventing XS-Leaks.
 *
 *  Cross-Origin-Embedder-Policy: require-corp
 *    → ZAP 90004 "Cross-Origin-Embedder-Policy Header Missing" (CWE-693)
 *      Prevents the document from loading cross-origin resources that do not
 *      explicitly grant permission via CORS or CORP, enabling shared memory
 *      APIs (SharedArrayBuffer) safely and closing Spectre gadget windows.
 */
@Component
@Order(1)
public class SecurityHeadersFilter implements Filter {

    @Override
    public void doFilter(ServletRequest request,
                         ServletResponse response,
                         FilterChain chain) throws IOException, ServletException {

        HttpServletResponse res = (HttpServletResponse) response;

        // ── Cache headers ────────────────────────────────────────────────────
        // Resolves ZAP 10049 – Storable and Cacheable Content (CWE-524)
        res.setHeader("Cache-Control", "no-cache, no-store, must-revalidate, private");
        res.setHeader("Pragma", "no-cache");          // HTTP/1.0 compat
        res.setDateHeader("Expires", 0);              // HTTP/1.0 compat

        // ── Anti-MIME-sniffing ───────────────────────────────────────────────
        // Resolves ZAP 10021 – X-Content-Type-Options Header Missing (CWE-693)
        res.setHeader("X-Content-Type-Options", "nosniff");

        // ── Cross-origin isolation headers ───────────────────────────────────
        // Resolves ZAP 90004 – Cross-Origin-Resource-Policy Missing (CWE-693)
        res.setHeader("Cross-Origin-Resource-Policy", "same-origin");

        // Resolves ZAP 90004 – Cross-Origin-Opener-Policy Missing (CWE-693)
        res.setHeader("Cross-Origin-Opener-Policy", "same-origin");

        // Resolves ZAP 90004 – Cross-Origin-Embedder-Policy Missing (CWE-693)
        res.setHeader("Cross-Origin-Embedder-Policy", "require-corp");

        chain.doFilter(request, response);
    }
}
