# MemoryVault MCP

A self-hosted, graph-aware memory server for AI assistants. Built on Cloudflare Workers + D1.

MemoryVault gives AI clients (Claude, ChatGPT, etc.) persistent memory across sessions via the [Model Context Protocol (MCP)](https://modelcontextprotocol.io). Store notes, facts, and journal entries. Link related memories into a knowledge graph. Search with hybrid lexical + semantic retrieval.

**Repository:** [github.com/vili-pet/memoryvaultbypierre](https://github.com/vili-pet/memoryvaultbypierre)

## Features

- **40+ MCP tools** — memory CRUD, graph linking, conflict detection, objectives, snapshots, and more
- **Hybrid search** — lexical + semantic (Vectorize + Workers AI embeddings) with RRF fusion
- **Knowledge graph** — typed relationships, path finding, neighborhood traversal, inferred links
- **Multi-tenant** — user accounts with isolated "brains" and per-brain policies
- **OAuth + PKCE** — standards-based auth for MCP clients, plus legacy bearer token fallback
- **Web viewer** — browse memories, explore the graph, manage settings at `/view`
- **6 themes** — cyberpunk, light, midnight, solarized, ember, arctic
- **Zero external dependencies** at runtime (just @modelcontextprotocol/sdk and zod)

## Quick Start

1. **Clone and install**

```bash
git clone https://github.com/vili-pet/memoryvaultbypierre.git
cd memoryvaultbypierre
npm install
```

2. **Configure local secrets**

```bash
cp .dev.vars.example .dev.vars
# Replace AUTH_SECRET and ADMIN_TOKEN. Generate with: openssl rand -hex 32
```

3. **Initialize local D1**

```bash
npm run cf:init:local
```

This applies `schema.sql` to the local D1 database (idempotent) and checks that `.dev.vars` exists. It does not print secret values.

4. **Run locally**

```bash
npm run dev
```

The worker listens on `http://127.0.0.1:8787`. MCP is at `/mcp`; the viewer is at `/view`.

For remote D1, KV, Vectorize, secrets, and deploy, see [docs/cloudflare.md](./docs/cloudflare.md). Short version:

```bash
npx wrangler login
npm run cf:init:remote -- --update-config
npx wrangler secret put AUTH_SECRET
npx wrangler secret put ADMIN_TOKEN
npm run deploy
```

## Configuration

| Variable | Required | Description |
|----------|----------|-------------|
| `AUTH_SECRET` | Yes | Signs JWTs and secures legacy bearer auth |
| `ADMIN_TOKEN` | Yes | Required for `POST /register` (OAuth client registration) unless every `redirect_uri` is on `claude.ai` or `poke.com` |
| `OAUTH_REDIRECT_DOMAIN_ALLOWLIST` | No | Comma-separated hostnames for OAuth redirect URIs. `localhost` and `127.0.0.1` are always allowed |

Local: set these in `.dev.vars` (gitignored). Production: `npx wrangler secret put <NAME>`. Do not put secrets in `wrangler.toml`.

`wrangler.toml` bindings (account-specific IDs):

| Binding | Resource | Default name |
|---------|----------|--------------|
| `DB` | D1 | `ai-memory` |
| `RATE_LIMIT_KV` | KV | `RATE_LIMIT_KV` |
| `MEMORY_INDEX` | Vectorize | `ai-memory-semantic-v1` (768 dims, cosine) |
| `AI` | Workers AI | `@cf/baai/bge-base-en-v1.5` |

`npm run cf:check` prints the current IDs without mutating anything.

## MCP Integration

Worker entry point: `src/index.ts` (`npm run dev` / `npm run deploy`). MCP endpoint: `/mcp`.

```
Local:      http://127.0.0.1:8787/mcp
Production: https://<YOUR_WORKER>.<YOUR_SUBDOMAIN>.workers.dev/mcp
```

Default worker name is `ai-memory-mcp`.

**OAuth mode (recommended):** Leave the API key empty. The server responds with OAuth discovery metadata. Your client handles PKCE (`S256`).

**Legacy bearer mode:** Send `Authorization: Bearer <AUTH_SECRET>`.

Copy-ready client configs (placeholders only — no credentials):

- [examples/mcp/claude-desktop.oauth.json](./examples/mcp/claude-desktop.oauth.json) — Claude Desktop, native remote URL
- [examples/mcp/claude-desktop.mcp-remote.json](./examples/mcp/claude-desktop.mcp-remote.json) — Claude Desktop via `npx mcp-remote`
- [examples/mcp/claude-desktop.bearer.json](./examples/mcp/claude-desktop.bearer.json) — Claude Desktop + bearer `AUTH_SECRET`
- [examples/mcp/claude-desktop.local.json](./examples/mcp/claude-desktop.local.json) — Claude Desktop against `npm run dev`
- [examples/mcp/cursor.mcp.json](./examples/mcp/cursor.mcp.json) — Cursor `.cursor/mcp.json`

Claude Desktop config path: `~/Library/Application Support/Claude/claude_desktop_config.json` (macOS), `%APPDATA%\Claude\claude_desktop_config.json` (Windows), `~/.config/Claude/claude_desktop_config.json` (Linux).

Claude Code:

```bash
claude mcp add --transport http memoryvault \
  https://YOUR_WORKER.YOUR_SUBDOMAIN.workers.dev/mcp
```

Full placeholder table and auth notes: [examples/mcp/README.md](./examples/mcp/README.md).

## Architecture

| Module | Purpose |
|--------|---------|
| `src/index.ts` | Worker entry point and HTTP routing |
| `src/types.ts` | Shared TypeScript types |
| `src/constants.ts` | Configuration constants |
| `src/utils.ts` | Pure utility functions |
| `src/crypto.ts` | PBKDF2, JWT, HMAC utilities |
| `src/cors.ts` | CORS and security headers |
| `src/db.ts` | D1 queries and schema migration |
| `src/auth.ts` | Session management and auth endpoints |
| `src/oauth.ts` | OAuth protocol (authorization, token, registration) |
| `src/vectorize.ts` | Semantic search and Vectorize integration |
| `src/scoring.ts` | Dynamic confidence/importance scoring |
| `src/tools-schema.ts` | MCP tool definitions and metadata |
| `src/tools.ts` | MCP tool handler implementations |
| `src/viewer.ts` | Web viewer UI (`/view`) |
| `src/routes.ts` | API and HTML route handlers |

**Tech stack:** Cloudflare Workers, D1 (SQLite), Vectorize, Workers AI (`@cf/baai/bge-base-en-v1.5`), MCP SDK

## Available MCP Tools

**Memory operations:** `memory_save`, `memory_get`, `memory_get_fact`, `memory_search`, `memory_context_pack`, `memory_list`, `memory_update`, `memory_delete`, `memory_reindex`, `memory_stats`

**Graph:** `memory_link`, `memory_unlink`, `memory_links`, `memory_link_suggest`, `memory_path_find`, `memory_subgraph`, `memory_neighbors`, `memory_graph_stats`, `memory_tag_stats`

**Knowledge management:** `memory_consolidate`, `memory_forget`, `memory_activate`, `memory_reinforce`, `memory_decay`, `memory_conflicts`, `memory_conflict_resolve`, `memory_entity_resolve`

**Trust & policy:** `memory_source_trust_set`, `memory_source_trust_get`, `brain_policy_set`, `brain_policy_get`

**Snapshots:** `brain_snapshot_create`, `brain_snapshot_list`, `brain_snapshot_restore`

**Objectives:** `objective_set`, `objective_list`, `objective_next_actions`

**Observability:** `memory_changelog`, `memory_watch`, `memory_explain_score`, `tool_manifest`, `tool_changelog`

## Development

```bash
npm run dev            # Start local worker
npm run type-check     # TypeScript check
npm run test:unit      # Vitest
npm test               # type-check + unit tests
npm run cf:check       # Print Cloudflare bindings and prerequisites
npm run cf:init:local  # Idempotent local D1 schema
npm run deploy         # Deploy to Cloudflare
```

**Smoke test** (needs a running worker and `ADMIN_TOKEN`; does not print tokens):

```bash
ADMIN_TOKEN=... npm run smoke:oauth-isolation
```

**Notes:**
- Semantic search requires Workers AI/Vectorize bindings — use `npx wrangler dev --remote` for full functionality
- Local D1 is created under `.wrangler/` and is gitignored

## Validation

Recorded on 2026-09-16 against this branch after `npm ci`:

| Command | Outcome |
|---------|---------|
| `npm run type-check` | See the pull request for the latest recorded result |
| `npm run test:unit` | See the pull request for the latest recorded result |
| `bash -n scripts/init-cloudflare.sh` | Syntax-checked as part of this refresh |

Re-run locally with `npm ci && npm test`.

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md). Issues: [github.com/vili-pet/memoryvaultbypierre/issues](https://github.com/vili-pet/memoryvaultbypierre/issues).

## License

[MIT](./LICENSE)
