package com.devsecops.userapi.repository;

import com.devsecops.userapi.model.User;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.stereotype.Repository;

@Repository
public interface UserRepository extends JpaRepository<User, Long> {
    // Spring Data JPA fournit automatiquement : save(), findById(), deleteById(), etc.
}
