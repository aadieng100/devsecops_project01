package com.devsecops.userapi.model;

import jakarta.persistence.*;
import jakarta.validation.constraints.Email;
import jakarta.validation.constraints.NotBlank;

@Entity
@Table(name = "users")
public class User {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @NotBlank(message = "Name is required")
    @Column(nullable = false)
    private String name;

    @NotBlank(message = "Email is required")
    @Email(message = "Email must be valid")
    @Column(nullable = false, unique = true)
    private String email;

    // ── Constructors ────────────────────────────────────────────────────────
    public User() {}

    public User(String name, String email) {
        this.name  = name;
        this.email = email;
    }

    // ── Getters / Setters ───────────────────────────────────────────────────
    public Long getId()            { return id; }
    public void setId(Long id)     { this.id = id; }

    public String getName()            { return name; }
    public void setName(String name)   { this.name = name; }

    public String getEmail()             { return email; }
    public void setEmail(String email)   { this.email = email; }
}
