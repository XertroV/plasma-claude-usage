/**
 * Exhaustive provider / effective-provider / leg endpoint-slug contract.
 * Shared by provider-request tests and response-cache path/envelope tests.
 *
 * credentialAlias labels document current OpenCode source keys/profile fallback;
 * they are not persisted in the cache envelope.
 */
export const RESPONSE_CACHE_ENDPOINT_CASES = [
    { name: "claude", provider: "claude", opencodeSlot: "", effectiveProvider: "claude", endpoint: "oauth-usage", requestKey: "usage" },
    { name: "anthropic alias", provider: "anthropic", opencodeSlot: "", effectiveProvider: "anthropic", endpoint: "oauth-usage", requestKey: "usage" },
    { name: "codex", provider: "codex", opencodeSlot: "", effectiveProvider: "codex", endpoint: "wham-usage", requestKey: "usage" },
    { name: "openai alias", provider: "openai", opencodeSlot: "", effectiveProvider: "openai", endpoint: "wham-usage", requestKey: "usage" },
    { name: "zai", provider: "zai", opencodeSlot: "", effectiveProvider: "zai", endpoint: "quota-limit", requestKey: "usage" },
    { name: "kimi", provider: "kimi", opencodeSlot: "", effectiveProvider: "kimi", endpoint: "coding-usages", requestKey: "usage" },
    { name: "minimax", provider: "minimax", opencodeSlot: "", effectiveProvider: "minimax", endpoint: "coding-plan-remains", requestKey: "usage" },
    { name: "opencode fallback", provider: "opencode", opencodeSlot: "", credentialAlias: "missing/default -> anthropic", effectiveProvider: "anthropic", endpoint: "oauth-usage", requestKey: "usage" },
    { name: "opencode anthropic", provider: "opencode", opencodeSlot: "anthropic", credentialAlias: "anthropic / anthropic-accounts", effectiveProvider: "anthropic", endpoint: "oauth-usage", requestKey: "usage" },
    { name: "opencode openai", provider: "opencode", opencodeSlot: "openai", credentialAlias: "openai", effectiveProvider: "openai", endpoint: "wham-usage", requestKey: "usage" },
    { name: "opencode minimax", provider: "opencode", opencodeSlot: "minimax", credentialAlias: "minimax-coding-plan", effectiveProvider: "minimax", endpoint: "coding-plan-remains", requestKey: "usage" },
    { name: "opencode zai", provider: "opencode", opencodeSlot: "zai", credentialAlias: "zai-coding-plan", effectiveProvider: "zai", endpoint: "quota-limit", requestKey: "usage" },
    { name: "opencode kimi", provider: "opencode", opencodeSlot: "kimi", credentialAlias: "kimi-for-coding", effectiveProvider: "kimi", endpoint: "coding-usages", requestKey: "usage" },
    { name: "grok default", provider: "grok", opencodeSlot: "", effectiveProvider: "grok", endpoint: "billing", requestKey: "default" },
    { name: "grok credits", provider: "grok", opencodeSlot: "", effectiveProvider: "grok", endpoint: "billing-credits", requestKey: "credits" }
]
