# Chattr Project Guidelines

## Project Overview

Chattr is an end-to-end encrypted chat application built with **Flutter** and **Supabase**. It
focuses on privacy and security using RSA-2048 encryption for all messages, anonymous
authentication, and automatic content cleanup from the server.

## Project Structure

### Flutter App (`lib/`)

The application follows a feature-based structure combined with core infrastructure:

- `lib/features/`: Contains business logic and UI organized by feature (e.g., `auth`, `chats`,
  `messages`, `members`, `profiles`). Each feature typically includes controllers, repositories, and
  models.
- `lib/core/`: Shared infrastructure:
    - `config/`: Application configuration.
    - `database/`: Local SQLite database (encrypted).
    - `security/`: Encryption services (RSA key management, message encryption).
    - `logging/`: Centralized logging service.
    - `helpers/`: Utility classes.
- `lib/screens/`: UI layer for higher-level navigation points (chat list, settings, etc.).

### Backend (`supabase/`)

The backend is managed with Supabase:

- `supabase/migrations/`: SQL migration files defining the schema, functions, triggers, and RLS
  policies.
- `supabase/functions/`: Edge functions for backend logic.

## Coding Standards

### Naming Conventions

- Use `PascalCase` for classes and enums.
- Use `camelCase` for variables, properties, and method names.
- Use `snake_case` for file names and database columns/tables.

### Architecture Patterns

- **Controllers**: Use controllers for state management and UI-specific logic.
- **Repositories**: Encapsulate data access logic (Supabase, local DB).
- **Services**: Dedicated classes for specific cross-cutting concerns (e.g.,
  `MessageEncryptionService`, `EventBusService`).

## Testing

### Running Tests

- Standard Flutter tests can be run using: `flutter test`
- To run specific tests: `flutter test test/encryption_test.dart`
- Tests are located in the `test/` directory and follow the `*_test.dart` naming convention.

### Requirements

- When fixing bugs or adding complex logic, Junie is expected to write or update reproduction tests.
- Ensure all tests pass before submitting changes.

## Versioning

This project uses Semantic Versioning. Versions are centrally managed in `version.json`.

- Use `./scripts/bump-version.sh` to update versions.
- Use `./scripts/release.sh` for creating releases and tags.

## Guidelines for Junie

- Follow the existing feature-based architecture.
- Prioritize security and encryption-related logic.
- Maintain the SQLite local storage synchronization logic when modifying message handling.
- When adding new database tables or functions, provide the corresponding Supabase migration files.
- Ensure `analysis_options.yaml` rules are respected.
