# Changelog

All notable changes to `idempotency_kit` will be documented in this file.

The format is based on Keep a Changelog.

## [0.1.0] - 2026-05-20

### Added
- Extracted reusable idempotency toolkit modules:
  - `IdempotencyKit.Core`
  - `IdempotencyKit.Store`
  - `IdempotencyKit.Store.Ecto`
  - `IdempotencyKit.Phoenix.Action`
- Added package README with installation, integration, and Redis replacement guidance.
- Added package-local test suite for:
  - Phoenix adapter behavior
  - Core delegation behavior
  - Ecto helper unit behavior
  - Postgres integration behavior

### Changed
- Aligned Ecto helper specs with `IdempotencyKit.Store.request_record()` contract.
- Added warning logging for raised create-changeset builder errors.
