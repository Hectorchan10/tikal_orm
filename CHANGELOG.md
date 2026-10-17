# Changelog

All notable changes to TikalORM will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/).

## [0.1.0] - 2026-10-16

### Added

- Initial experimental release of TikalORM.
- Support for PostgreSQL, MySQL/MariaDB, and SQLite.
- Annotation-based model definitions and field mapping.
- Static code generation with automatic model registration.
- Type-safe Query Builder with filtering, sorting, and pagination.
- CRUD operations through repositories and the Tikal facade.
- Model change tracking and partial updates.
- Primary keys, unique constraints, and relationship metadata.
- Database transactions and nested savepoints.
- Optional timestamps and soft deletes.
- PostgreSQL schema inspection, migrations, and schema diffing.
- Migration history verification and rollback support.
- Annotation-based database seeders with dependency execution.
- CLI commands for initialization, generation, migrations, and seeders.
- Automatic code regeneration with watch mode.
- Connection pooling for PostgreSQL and MySQL.
- Typed exceptions and database error handling.
- Parameterized SQL queries for safer database operations.

### Notes

- This is an experimental release. Public APIs may change before version 1.0.0.
- Schema inspection and migrations currently support PostgreSQL only.
- SQLite and MySQL/MariaDB support database operations but not schema migrations.
- Code generation must be executed before using generated model helpers.
- Database tables are not automatically created during connection configuration.