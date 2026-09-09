# Kroniku Frontend-Backend Integration Plan

## Overview
This plan outlines the phased approach to update the iOS frontend to use the backend APIs defined in `backend-api-contract.md`. The frontend currently uses local SwiftData storage; we will add network sync capabilities while maintaining offline-first functionality.

---

## Phase 1: Foundation (Network & Auth)

### 1.1 Network Layer
**Objective:** Establish HTTP client infrastructure with JWT handling

**Tasks:**
- Create `APIClient.swift` - Centralized URLSession wrapper
  - Base URL configuration (environment-dependent)
  - Request/response logging
  - Automatic JWT injection into `Authorization: Bearer` header
  - Error parsing for standard response shapes (400, 401, 403, 404, 409)
- Create `HTTPError.swift` - Typed error parsing
  - `ValidationError(messages: [String])` for 400
  - `UnauthorizedError(message: String)` for 401
  - `ForbiddenError(message: String)` for 403
  - `NotFoundError(message: String)` for 404
  - `ConflictError(message: String)` for 409

**Deliverable:** A reusable `APIClient` that can be injected into all services

---

### 1.2 Authentication Service
**Objective:** Handle registration, login, and provider authentication

**Tasks:**
- Create `AuthService.swift` - HTTP methods for auth endpoints
  - `register(email: String, password: String, clientDeviceId: String, platform: String, appVersion: String, publicKey: String?) async throws -> AuthResponse`
  - `login(email: String, password: String, clientDeviceId: String, platform: String, appVersion: String, publicKey: String?) async throws -> AuthResponse`
  - `loginWithProvider(provider: String, idToken: String, clientDeviceId: String, platform: String, appVersion: String, publicKey: String?) async throws -> ProviderAuthResponse`
  - `getBackendStatus() async throws -> HealthResponse`

- Create `AuthModels.swift` - Decodable types matching backend response
  - `struct AuthResponse { accessToken: String, user: User, device: Device }`
  - `struct ProviderAuthResponse { accessToken: String, user: User, device: Device, isNewAccount: Bool }`
  - `struct User { id: String, email: String, retrievalOptIn: Bool }`
  - `struct Device { id: String, clientDeviceId: String }`

- Update `@main KronikuApp` initialization
  - Persist `accessToken` to Keychain after auth
  - Persist `clientDeviceId` to Keychain (must be stable across app launches)
  - Persist `device.id` (server-managed identity in JWT)

**Deliverable:** Reusable `AuthService` with type-safe responses; Keychain persistence layer for JWT and device ID

---

## Phase 2: Event Sync

### 2.1 Sync Models & Service
**Objective:** Define backend sync data structures; build pull/push methods

**Tasks:**
- Create `SyncModels.swift` - Decodable types for sync endpoints
  - `struct PushEventRequest { eventId: String, version: Int, occurredAt: Date, source: String, title: String?, detail: String?, searchText: String?, encryptedPayload: String, payloadHash: String, isDeleted: Bool }`
  - `struct PushSyncResponse { applied: [AppliedEvent], conflicts: [ConflictEvent], ignored: [IgnoredEvent] }`
  - `struct AppliedEvent { eventId: String, version: Int, updatedAt: Date }`
  - `struct ConflictEvent { eventId: String, strategy: String, serverVersion: Int, incomingVersion: Int }`
  - `struct PullEventResponse { id: String, eventId: String, version: Int, occurredAt: Date, source: String, title: String?, detail: String?, searchText: String?, encryptedPayload: String, payloadHash: String, isDeleted: Bool, createdAt: Date, updatedAt: Date }`
  - `struct PullSyncResponse { events: [PullEventResponse], cursor: Date? }`

- Create `SyncService.swift` - HTTP methods for sync
  - `pushSync(events: [PushEventRequest]) async throws -> PushSyncResponse`
  - `pullSync(since: Date?) async throws -> PullSyncResponse`

**Deliverable:** Type-safe models and service for push/pull operations

---

### 2.2 Local ↔ Remote Sync Reconciliation
**Objective:** Map between SwiftData local events and backend sync model

**Tasks:**
- Extend `SwiftDataMemoryRepository` with sync-aware methods
  - `func fetchUnsyncedEvents() -> [MemoryEvent]` - Events with `syncedToBackendAt == nil`
  - `func markSynced(eventId: String, version: Int, syncedAt: Date) throws` - Update local version after successful push
  - `func applyConflict(eventId: String, serverVersion: Int, strategy: String) throws` - Log server-side conflicts
  - `func mergePulledEvents(_ events: [PullEventResponse]) throws` - Integrate remote events into local store
    - Use last-write-wins by comparing local `updatedAt` with server `updatedAt`
    - Handle `isDeleted` flag by soft-deleting locally
    - Preserve `encryptedPayload` as authoritative

- Add metadata fields to `MemoryEvent` model
  - `backendEventId: String?` - Maps local UUID to remote eventId
  - `backendVersion: Int` - For conflict resolution
  - `syncedToBackendAt: Date?` - Last successful push timestamp
  - `payloadHash: String?` - For detecting stale conflicts

**Deliverable:** Bidirectional sync methods with conflict resolution

---

### 2.3 Sync Orchestration
**Objective:** Coordinate periodic or manual pull/push cycles

**Tasks:**
- Create `SyncCoordinator.swift`
  - `func performFullSync() async throws` - Pull then push in sequence
  - `func pushPending() async throws` - Send unsynced events only
  - `func pullLatest() async throws` - Fetch events since last cursor
  - Error handling: retry logic, conflict reporting, offline queuing

- Integrate with app lifecycle
  - Call `pullLatest()` on app launch (if network available)
  - Call `pushPending()` after adding/editing a memory locally
  - Optional: Periodic background sync every N minutes

**Deliverable:** Main orchestration entry point for sync workflows

---

## Phase 3: Search

### 3.1 Search Models & Service
**Objective:** Build keyword and natural-language search

**Tasks:**
- Create `SearchModels.swift`
  - `struct SearchRequest { query: String, limit: Int }`
  - `struct KeywordSearchResponse { mode: String, query: String, count: Int, results: [SearchResult] }`
  - `struct NaturalSearchResponse { mode: String, query: String, rationale: String, count: Int, results: [ScoredResult] }`
  - `struct SearchResult { ...event fields matching PullEventResponse }`
  - `struct ScoredResult { event: SearchResult, score: Double }`

- Create `SearchService.swift`
  - `func keywordSearch(query: String, limit: Int = 10) async throws -> KeywordSearchResponse`
  - `func naturalSearch(query: String, limit: Int = 5) async throws -> NaturalSearchResponse`

**Deliverable:** Type-safe search service for both query modes

---

### 3.2 UI Integration
**Objective:** Wire search UI to new backend endpoints

**Tasks:**
- Identify/create search UI view (likely in `TimelineView` or new search tab)
- Replace local in-memory search (if any) with calls to `SearchService`
- Handle 403 response for natural-language search (retrieval opt-in disabled)
- Display search results with proper error states

**Deliverable:** Search UI bound to backend queries

---

## Phase 4: Account Lifecycle

### 4.1 Account Service
**Objective:** Handle retrieval opt-in, export, and deletion

**Tasks:**
- Create `AccountService.swift`
  - `func enableRetrievalOptIn(_ enabled: Bool) async throws -> RetrievalOptInResponse`
  - `func exportAccountData() async throws -> ExportResponse`
  - `func deleteAccount() async throws -> DeleteResponse`

- Create `AccountModels.swift`
  - `struct RetrievalOptInResponse { userId: String, retrievalOptIn: Bool, updatedAt: Date }`
  - `struct ExportResponse { exportedAt: Date, account: AccountInfo, devices: [Device], events: [PullEventResponse] }`
  - `struct DeleteResponse { deleted: Bool, deletedAt: Date }`

**Deliverable:** Reusable account management service

---

### 4.2 Settings UI Wiring
**Objective:** Connect account actions to UI

**Tasks:**
- Update `SettingsView.swift`
  - "Enable Retrieval Opt-In" toggle → calls `AccountService.enableRetrievalOptIn()`
  - "Export My Data" button → calls `AccountService.exportAccountData()`, present download
  - "Delete Account" button → confirmation alert → calls `AccountService.deleteAccount()`, clears local data and JWT

**Deliverable:** Settings page bound to account endpoints

---

## Phase 5: Error Handling & Offline Behavior

### 5.1 Network Availability & Retry
**Objective:** Graceful fallback when offline

**Tasks:**
- Create `NetworkMonitor.swift` using `Network` framework
  - Track connectivity state (reachable vs. unreachable)
  - Publish state changes via `@Published` property

- Update `SyncCoordinator`
  - Queue push/pull operations when offline
  - Retry on network recovery (backoff strategy)
  - Show user feedback: "Syncing...", "Sync failed", "Offline"

**Deliverable:** Offline-aware sync with retry logic

---

### 5.2 User Feedback
**Objective:** Surface errors and status clearly

**Tasks:**
- Add sync status display to app UI (top banner or tab badge)
- Show error alerts for:
  - 401 Unauthorized → Logout, return to auth screen
  - 409 Conflict → Explain version conflict, suggest manual resolution
  - 403 Forbidden (natural search) → Suggest enabling in Settings
  - Network errors → "Check your connection"

**Deliverable:** Comprehensive error messaging

---

## Phase 6: Security & Encryption

### 6.1 Payload Encryption (Optional - Deferrable)
**Objective:** Support client-side encryption for `encryptedPayload`

**Tasks:**
- Decide on encryption library (e.g., CryptoKit for symmetric, or JWE for standard)
- Create `EncryptionService.swift` to handle payload encryption/decryption
- Backend contract says: "encryptedPayload is accepted as opaque client-side ciphertext and is never decrypted by the backend"
- For MVP: Send plaintext or base64 placeholder; implement true encryption in follow-up phase

**Deliverable:** Encryption layer (may be stub for MVP)

---

### 6.2 Device Public Key
**Objective:** Implement device identity in registration/login

**Tasks:**
- Generate stable public key on first app install
- Store private key securely in Keychain
- Send `publicKey` (base64) in auth requests
- (Future: use for signed sync batch integrity)

**Deliverable:** Device identity layer

---

## Phase 7: Testing

### 7.1 Unit Tests
**Objective:** Test services in isolation

**Tasks:**
- Create `APIClientTests.swift` - Mock URLSession, test request construction
- Create `AuthServiceTests.swift` - Mock responses, test token parsing
- Create `SyncServiceTests.swift` - Test push/pull decoding
- Create `SearchServiceTests.swift` - Test query encoding/response parsing

**Deliverable:** > 80% coverage of services

---

### 7.2 Integration Tests
**Objective:** Test against local mock backend (or staging)

**Tasks:**
- Add mock backend server (e.g., simple Node.js/Express mock endpoints)
- Test full auth → sync → search flow end-to-end
- Test conflict resolution, offline/online transitions
- Update `KronikuTests/` with integration test cases

**Deliverable:** Integration test suite

---

## Implementation Order

1. **Week 1:** Phase 1 (APIClient, AuthService, Keychain)
2. **Week 2:** Phase 2.1–2.2 (SyncModels, repository updates)
3. **Week 3:** Phase 2.3 (SyncCoordinator, app lifecycle)
4. **Week 4:** Phase 3 (SearchService, UI wiring)
5. **Week 5:** Phase 4 (AccountService, Settings UI)
6. **Week 6:** Phase 5 (Error handling, offline)
7. **Week 7–8:** Phase 6 & 7 (Encryption, testing)

---

## Acceptance Criteria

- ✅ Auth: User can register, login, and provider-login; JWT persisted to Keychain
- ✅ Sync: Local events push to backend; backend events pull to local store; conflicts logged
- ✅ Search: Keyword and natural-language queries work; 403 handled gracefully
- ✅ Account: Retrieval opt-in, export, and delete workflows function end-to-end
- ✅ Offline: App queues actions offline; retries on network recovery
- ✅ Tests: Core services have >80% unit test coverage

---

## Notes for Implementation

1. **Incremental Rollout:** Wrap all backend calls behind feature flags; start with auth, then sync, then search.
2. **Backward Compatibility:** Keep local SwiftData as primary store; treat backend as source-of-truth for pull; push is best-effort.
3. **Error Messages:** Match backend contract exactly (400 message arrays, 401/403 variants) to provide precise user feedback.
4. **Concurrency:** Use Swift Concurrency (`async/await`) throughout; avoid DispatchQueue where possible.
5. **Logging:** Add detailed logs for sync conflicts, auth failures, and network transitions for debugging.

