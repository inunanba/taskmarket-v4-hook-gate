// SPDX-License-Identifier: MIT
/** Every adapter failure is an AdapterError with a stable `code`. Callers must treat any error as "do not authorize". */
export class AdapterError extends Error {
  constructor(code, message, details = undefined) {
    super(`${code}: ${message}`);
    this.name = 'AdapterError';
    this.code = code;
    this.details = details;
  }
}

export const CODES = Object.freeze([
  'INVALID_INPUT', // bad CLI/API arguments
  'CONFIG', // missing key / RPC / hook settings
  'API_ERROR', // network failure, timeout, 5xx, oversized body
  'AUTH_REQUIRED', // 401/403: Taskmarket wants credentials we do not have (never bypassed)
  'PAYMENT_REQUIRED', // 402: X402-protected route (never bypassed, no payment is made)
  'NOT_FOUND', // 404
  'MALFORMED', // not JSON object, wrong content-type, bad types
  'MISSING_FIELD', // required field absent
  'MISMATCH', // response is about a different task
  'UNKNOWN_STATUS', // status outside the documented enum
  'WRONG_STATUS', // status is valid but not the one that unlocks the pool
  'TASK_EXPIRED', // active-status task already past expiryTime
  'UNVERIFIABLE_TIME', // missing/invalid HTTP Date header
  'STALE', // clock skew or cache Age too large
  'STALE_STATE', // task changed between the reads
  'WRONG_CHAIN', // RPC chain id differs from the requested chain
  'HOOK_CONFIG_MISMATCH', // hook pool config disagrees with request (not allowlisted, status, ttl)
  'UNAUTHORIZED_ADAPTER', // signer is not authorized on the hook
  'HOOK_REJECTED', // hook preview/submit returned a non-OK reason
]);

export function fail(code, message, details) {
  throw new AdapterError(code, message, details);
}
