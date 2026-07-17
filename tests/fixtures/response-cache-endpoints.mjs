/**
 * Exhaustive provider / effective-provider / leg endpoint-slug contract.
 * Shared by provider-request tests and response-cache path/envelope tests.
 *
 * credentialAlias labels document current OpenCode source keys/profile fallback;
 * they are not persisted in the cache envelope.
 */
// requestKey matches ProfileRefreshProviders.buildRequests: non-Grok legs use
// "default"; Grok dual-fetch uses "default" + "credits". (Plan draft said
// "usage"; product I002 source is authoritative.)
export const RESPONSE_CACHE_ENDPOINT_CASES = [
    { name: "claude", provider: "claude", opencodeSlot: "", effectiveProvider: "claude", endpoint: "oauth-usage", requestKey: "default" },
    { name: "anthropic alias", provider: "anthropic", opencodeSlot: "", effectiveProvider: "anthropic", endpoint: "oauth-usage", requestKey: "default" },
    { name: "codex", provider: "codex", opencodeSlot: "", effectiveProvider: "codex", endpoint: "wham-usage", requestKey: "default" },
    { name: "openai alias", provider: "openai", opencodeSlot: "", effectiveProvider: "openai", endpoint: "wham-usage", requestKey: "default" },
    { name: "zai", provider: "zai", opencodeSlot: "", effectiveProvider: "zai", endpoint: "quota-limit", requestKey: "default" },
    { name: "kimi", provider: "kimi", opencodeSlot: "", effectiveProvider: "kimi", endpoint: "coding-usages", requestKey: "default" },
    { name: "minimax", provider: "minimax", opencodeSlot: "", effectiveProvider: "minimax", endpoint: "coding-plan-remains", requestKey: "default" },
    { name: "opencode fallback", provider: "opencode", opencodeSlot: "", credentialAlias: "missing/default -> anthropic", effectiveProvider: "anthropic", endpoint: "oauth-usage", requestKey: "default" },
    { name: "opencode anthropic", provider: "opencode", opencodeSlot: "anthropic", credentialAlias: "anthropic / anthropic-accounts", effectiveProvider: "anthropic", endpoint: "oauth-usage", requestKey: "default" },
    { name: "opencode openai", provider: "opencode", opencodeSlot: "openai", credentialAlias: "openai", effectiveProvider: "openai", endpoint: "wham-usage", requestKey: "default" },
    { name: "opencode minimax", provider: "opencode", opencodeSlot: "minimax", credentialAlias: "minimax-coding-plan", effectiveProvider: "minimax", endpoint: "coding-plan-remains", requestKey: "default" },
    { name: "opencode zai", provider: "opencode", opencodeSlot: "zai", credentialAlias: "zai-coding-plan", effectiveProvider: "zai", endpoint: "quota-limit", requestKey: "default" },
    { name: "opencode kimi", provider: "opencode", opencodeSlot: "kimi", credentialAlias: "kimi-for-coding", effectiveProvider: "kimi", endpoint: "coding-usages", requestKey: "default" },
    { name: "grok default", provider: "grok", opencodeSlot: "", effectiveProvider: "grok", endpoint: "billing", requestKey: "default" },
    { name: "grok credits", provider: "grok", opencodeSlot: "", effectiveProvider: "grok", endpoint: "billing-credits", requestKey: "credits" }
]
