# Acceptance matrix

Generated from `evidence/forge-test.log` and `evidence/adapter-test.log` (all PASS). Reproduce with `forge test` and `cd adapter && npm test`.

## Foundry (real v4 PoolManager): 78 tests

| # | Test | Criterion |
|---|---|---|
| 1 | `test_configurationEvents_emitted` | Unauthorized configuration / config events |
| 2 | `test_epochIsMonotonic_acrossDelistAndRelist` | Unauthorized configuration / config events |
| 3 | `test_invalidConfiguration_reverts` | Unauthorized configuration / config events |
| 4 | `test_twoStepOwnership` | Unauthorized configuration / config events |
| 5 | `test_unauthorizedConfiguration_reverts` | Unauthorized configuration / config events |
| 6 | `test_vector_digestAndSignerMatch` | JS↔Solidity encoding |
| 7 | `test_vector_hookDataBytesIdentical_andAcceptedInline` | JS↔Solidity encoding |
| 8 | `test_vector_poolIdMatchesV4` | JS↔Solidity encoding |
| 9 | `test_vector_submitInstallsGrant` | JS↔Solidity encoding |
| 10 | `test_constructor_rejectsAddressWithWrongPermissionBits` | Pool isolation & out-of-scope callbacks |
| 11 | `test_delistedPool_rejectsEvenValidBinding_rollback` | Allowlisted pool only |
| 12 | `test_disabledCallbacks_revertHookNotImplemented` | Pool isolation & out-of-scope callbacks |
| 13 | `test_donate_isNotGated_andConsumesNothing` | Pool isolation & out-of-scope callbacks |
| 14 | `test_foreignHookKey_neverAuthorized` | Pool isolation & out-of-scope callbacks |
| 15 | `test_permissions_onlySelectedCallbackBits` | Pool isolation & out-of-scope callbacks |
| 16 | `test_poolIsolation_inlineBindingForA_rejectedOnB` | Pool isolation & out-of-scope callbacks |
| 17 | `test_poolIsolation_installedGrantOnA_doesNotAuthorizeB` | Pool isolation & out-of-scope callbacks |
| 18 | `test_removeLiquidity_isNotGated_andConsumesNothing` | Pool isolation & out-of-scope callbacks |
| 19 | `test_removeLiquidity_withBindingAttached_isNotTreatedAsAuthorization` | Pool isolation & out-of-scope callbacks |
| 20 | `test_unallowlistedPool_cannotInitialize` | Allowlisted pool only |
| 21 | `test_ungatedActionOnAllowlistedPool_passesWithoutConsuming` | Pool isolation & out-of-scope callbacks |
| 22 | `test_unrelatedPoolWithoutHook_neverCallsHook` | Pool isolation & out-of-scope callbacks |
| 23 | `test_deployScript_minesAddressWithExactPermissionBits` | Deployment (CREATE2 bits, chain/PM guards) |
| 24 | `test_deployScript_refusesPoolManagerWithoutCode` | Deployment (CREATE2 bits, chain/PM guards) |
| 25 | `test_deployScript_refusesWrongChain` | Deployment (CREATE2 bits, chain/PM guards) |
| 26 | `test_hashBinding_matchesLibraryDigest` | Observable records / previews |
| 27 | `test_inline_validBinding_allowsAddLiquidity` | Valid binding permits selected callback |
| 28 | `test_inline_validBinding_allowsSwap_andEmitsDecision` | Valid binding permits selected callback |
| 29 | `test_install_bothActions_singleGrantCoversSwapAndAdd` | Valid binding permits selected callback |
| 30 | `test_install_emitsBindingUpdated_thenGrantAuthorizesExactlyMaxUses` | Valid binding permits selected callback |
| 31 | `test_install_grantPersistsStoredEvidence` | Observable records / previews |
| 32 | `test_newerBinding_replacesGrant` | Valid binding permits selected callback |
| 33 | `test_pinnedTaskId_acceptsMatchingTask` | Task state (status/task id) |
| 34 | `test_previewBinding_returnsSignerAndReason` | Observable records / previews |
| 35 | `test_previewCallback_matchesOutcome` | Observable records / previews |
| 36 | `test_bindingRejected_isLogged_andChangesNoState` | Observable records / previews |
| 37 | `test_cancelledNonce_rejected` | Reused nonce / replay |
| 38 | `test_chainSwitchAfterSigning_rejected` | Wrong chain / domain |
| 39 | `test_directCallerNotPoolManager_rejected` | Invalid authorization / caller |
| 40 | `test_expired_inline_rejected` | Expired / stale binding |
| 41 | `test_expired_installedGrant_rejected` | Expired / stale binding |
| 42 | `test_expiryBoundary_inclusive` | Expired / stale binding |
| 43 | `test_futureObservation_rejected` | Expired / stale binding |
| 44 | `test_garbageSignature_rejected` | Invalid authorization / caller |
| 45 | `test_highSSignature_rejected` | Invalid authorization / caller |
| 46 | `test_install_actionsNotGatedOnPool_rejected` | Invalid authorization / caller |
| 47 | `test_install_unallowlistedPool_rejected` | Allowlisted pool only |
| 48 | `test_installedGrant_wrongAction_rejected` | Invalid authorization / caller |
| 49 | `test_malformedBinding_zeroActionsOrUses_rejected` | Invalid authorization / caller |
| 50 | `test_malformedHookData_dirtyHighBits_rejected` | Invalid authorization / caller |
| 51 | `test_malformedHookData_rejected` | Invalid authorization / caller |
| 52 | `test_malformedHookData_shortSignature_rejected` | Invalid authorization / caller |
| 53 | `test_missingBinding_noGrant_rejected` | Invalid authorization / caller |
| 54 | `test_nonceSharedAcrossModes_inlineThenInstall_rejected` | Reused nonce / replay |
| 55 | `test_outdatedBinding_cannotOverwriteNewerGrant` | Reused nonce / replay |
| 56 | `test_paused_failsClosed_forCallbacksAndInstall` | Fail-closed controls (pause/epoch/revoke) |
| 57 | `test_reconfigure_bumpsEpoch_invalidatesBindingAndGrant` | Fail-closed controls (pause/epoch/revoke) |
| 58 | `test_replayedNonce_inline_rejected` | Reused nonce / replay |
| 59 | `test_replayedNonce_install_rejectedWithEvent` | Reused nonce / replay |
| 60 | `test_revokeGrant_byAdapter_blocksFurtherUse` | Fail-closed controls (pause/epoch/revoke) |
| 61 | `test_revokedAdapter_inline_rejected` | Invalid authorization / caller |
| 62 | `test_revokedAdapter_killsInstalledGrant` | Invalid authorization / caller |
| 63 | `test_signedForOtherChainDomain_rejected` | Wrong chain / domain |
| 64 | `test_signedForOtherVerifyingContract_rejected` | Wrong chain / domain |
| 65 | `test_staleObservation_rejected` | Expired / stale binding |
| 66 | `test_tamperedBinding_rejected` | Invalid authorization / caller |
| 67 | `test_ttlTooLong_rejected` | Expired / stale binding |
| 68 | `test_unauthorizedSigner_rejected` | Invalid authorization / caller |
| 69 | `test_wrongAction_rejected` | Invalid authorization / caller |
| 70 | `test_wrongActor_rejected` | Invalid authorization / caller |
| 71 | `test_wrongChainField_rejected` | Wrong chain / domain |
| 72 | `test_wrongHookField_rejected` | Wrong chain / domain |
| 73 | `test_wrongStatus_rejected` | Task state (status/task id) |
| 74 | `test_wrongTask_rejected` | Task state (status/task id) |
| 75 | `testFuzz_expiryWindow` | Expired / stale binding |
| 76 | `testFuzz_randomHookData_neverAuthorizes` | Invalid authorization / caller |
| 77 | `testFuzz_randomSignerKey_neverAuthorizes` | Invalid authorization / caller |
| 78 | `testFuzz_tamperAnySignedWord_rejected` | Invalid authorization / caller |

## Adapter (node:test): 60 tests

| # | Test | Criterion |
|---|---|---|
| 1 | offline happy path: signed binding, canonical hookData, evidence = keccak(raw bytes of the re-fetch) | Raw responses preserved before parsing |
| 2 | online: reads epoch/maxTtl from hook, previews on-chain, writes after a THIRD fetch | Authorization construction / hook pre-flight |
| 3 | observedAt is clamped to the chain head so the hook never sees a future observation | Stale / unverifiable state fails closed (re-fetch before writes) |
| 4 | open task: binding expiry is capped by the task expiryTime | Task state |
| 5 | wrong task status -> WRONG_STATUS and nothing is signed | Task state |
| 6 | expired active task -> TASK_EXPIRED | Task state |
| 7 | state changes between the read and the re-fetch -> STALE_STATE, nothing signed | Stale / unverifiable state fails closed (re-fetch before writes) |
| 8 | re-fetch failure (API down) -> API_ERROR, nothing signed | Adapter/API failure fails closed |
| 9 | state changes right before the write -> STALE_STATE, writer never called | Stale / unverifiable state fails closed (re-fetch before writes) |
| 10 | RPC on the wrong chain -> WRONG_CHAIN | Wrong chain |
| 11 | pool not allowlisted or status mismatch on the hook -> HOOK_CONFIG_MISMATCH | Hook pre-flight (on-chain config/preview) fails closed |
| 12 | signer not authorized on the hook -> UNAUTHORIZED_ADAPTER | Hook pre-flight (on-chain config/preview) fails closed |
| 13 | hook preview returns a non-OK reason -> HOOK_REJECTED (no write) | Hook pre-flight (on-chain config/preview) fails closed |
| 14 | on-chain BindingRejected outcome -> HOOK_REJECTED | Hook pre-flight (on-chain config/preview) fails closed |
| 15 | configuration errors fail before any network call | Adapter/API failure fails closed |
| 16 | invalid binding inputs are refused (actor zero) | Malformed / missing / untrusted input fails closed |
| 17 | revokeIfDrifted keeps the grant while state is valid | Revocation on drift (fail closed) |
| 18 | revokeIfDrifted revokes when the task leaves the required status | Revocation on drift (fail closed) |
| 19 | revokeIfDrifted revokes when state is unverifiable (fail closed) | Revocation on drift (fail closed) |
| 20 | no secret material in results | No secrets exposed |
| 21 | valid response parses to a minimal normalized view | Malformed / missing / untrusted input fails closed |
| 22 | raw bytes and metadata are preserved BEFORE parsing, even for garbage | Raw responses preserved before parsing |
| 23 | raw response is preserved for HTTP error statuses too | Raw responses preserved before parsing |
| 24 | HTTP 401 fails closed with AUTH_REQUIRED | Adapter/API failure fails closed |
| 25 | HTTP 403 fails closed with AUTH_REQUIRED | Adapter/API failure fails closed |
| 26 | HTTP 402 fails closed with PAYMENT_REQUIRED | Adapter/API failure fails closed |
| 27 | HTTP 404 fails closed with NOT_FOUND | Adapter/API failure fails closed |
| 28 | HTTP 429 fails closed with API_ERROR | Adapter/API failure fails closed |
| 29 | HTTP 503 fails closed with API_ERROR | Adapter/API failure fails closed |
| 30 | HTTP 301 fails closed with API_ERROR | Adapter/API failure fails closed |
| 31 | network failure fails closed (API_ERROR) | Adapter/API failure fails closed |
| 32 | timeout fails closed (API_ERROR) | Adapter/API failure fails closed |
| 33 | oversized body fails closed (API_ERROR) | Adapter/API failure fails closed |
| 34 | malformed: non-JSON body -> MALFORMED | Malformed / missing / untrusted input fails closed |
| 35 | malformed: invalid UTF-8 -> MALFORMED | Malformed / missing / untrusted input fails closed |
| 36 | malformed: JSON array -> MALFORMED | Malformed / missing / untrusted input fails closed |
| 37 | malformed: JSON null -> MALFORMED | Malformed / missing / untrusted input fails closed |
| 38 | malformed: JSON string -> MALFORMED | Malformed / missing / untrusted input fails closed |
| 39 | malformed: wrong content-type -> MALFORMED | Malformed / missing / untrusted input fails closed |
| 40 | malformed: missing content-type -> MALFORMED | Malformed / missing / untrusted input fails closed |
| 41 | malformed: non-string status -> MALFORMED | Malformed / missing / untrusted input fails closed |
| 42 | malformed: id not hex32 -> MALFORMED | Malformed / missing / untrusted input fails closed |
| 43 | malformed: expiryTime not a date -> MALFORMED | Malformed / missing / untrusted input fails closed |
| 44 | malformed: numeric expiryTime -> MALFORMED | Malformed / missing / untrusted input fails closed |
| 45 | malformed: negative Age header -> MALFORMED | Malformed / missing / untrusted input fails closed |
| 46 | missing required field id -> MISSING_FIELD | Malformed / missing / untrusted input fails closed |
| 47 | missing required field status -> MISSING_FIELD | Malformed / missing / untrusted input fails closed |
| 48 | missing required field expiryTime -> MISSING_FIELD | Malformed / missing / untrusted input fails closed |
| 49 | response for a different task -> MISMATCH | Malformed / missing / untrusted input fails closed |
| 50 | status outside the documented enum -> UNKNOWN_STATUS | Malformed / missing / untrusted input fails closed |
| 51 | missing HTTP Date header -> UNVERIFIABLE_TIME | Stale / unverifiable state fails closed (re-fetch before writes) |
| 52 | server/local clock skew beyond limit -> STALE | Stale / unverifiable state fails closed (re-fetch before writes) |
| 53 | cached response with large Age -> STALE | Stale / unverifiable state fails closed (re-fetch before writes) |
| 54 | input validation: bad task id, non-https API, missing rawDir | Malformed / missing / untrusted input fails closed |
| 55 | request is a plain GET to /api/tasks/{id} with redirects refused | Malformed / missing / untrusted input fails closed |
| 56 | committed Solidity fixture equals a fresh deterministic regeneration | JS↔Solidity encoding |
| 57 | poolIdFromKey matches the fixture PoolId (v4 keccak256(abi.encode(PoolKey))) | JS↔Solidity encoding |
| 58 | CLI: missing ADAPTER_PRIVATE_KEY exits 1 with ok:false and no hookData | CLI fail-closed behaviour |
| 59 | CLI: probe against a local Taskmarket-shaped server preserves raw and validates | CLI fail-closed behaviour |
| 60 | CLI: probe against a server returning 402 fails closed (no payment attempted) | CLI fail-closed behaviour |

## Fork of live Robinhood Chain testnet (opt-in): 3 tests

| Test | Criterion |
|---|---|
| `test_fork_chainIdIsRobinhoodTestnet` | Chain id 46630 verified on the live RPC |
| `test_fork_poolManagerHasCode` | Operator-supplied PoolManager has v4-sized runtime |
| `test_fork_gatedLifecycleOnLivePoolManager` | Through the live PoolManager bytecode: unlisted init rejected, then allowlist, init, inline add-liquidity, installed swap grant, and a `NO_GRANT` rejection |

## End-to-end (`scripts/e2e-local.sh`, see `evidence/e2e-local.log`)

Unauthorized swap rejected → adapter `authorize --submit` (3 reads, preview, write) → swap consumes the grant → replay logged as `BindingRejected(NONCE_USED)` → task drifts → `revoke-if-drifted` revokes → swap rejected → adapter refuses to sign (`WRONG_STATUS`) → on-chain event trail counted.
