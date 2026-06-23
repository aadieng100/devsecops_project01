package com.devsecops.userapi.controller;

import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;

/**
 * Minimal root endpoint.
 *
 * Returning 200 on GET / prevents ZAP's spider from logging a
 * "spider error: 404 expected 200" and avoids the associated
 * Non-Storable Content [10049] alert variant on error responses.
 */
@RestController
public class RootController {

    @GetMapping("/")
    public ResponseEntity<Map<String, String>> root() {
        return ResponseEntity.ok(Map.of(
                "service", "user-api",
                "status",  "UP",
                "docs",    "/api/users"
        ));
    }
}
