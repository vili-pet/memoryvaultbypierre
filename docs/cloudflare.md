# Cloudflare deployment and initialization

MemoryVault runs as a Cloudflare Worker (`ai-memory-mcp`) with three account resources:

| Binding | Resource | Purpose |
|---------|----------|---------|
| `DB` | D1 database `ai-memory` | Users, brains, memories, graph, OAuth |
| `RATE_LIMIT_KV` | KV namespace | Login/signup rate limiting |
| `MEMORY_INDEX` | Vectorize index `ai-memory-semantic-v1` | Semantic search (768-dim cosine, `@cf/baai/bge-base-en-v1.5`) |
| `AI` | Workers AI | Embedding generation |

`schema.sql` is idempotent (`CREATE TABLE IF NOT EXISTS`, `INSERT OR IGNORE`). Applying it more than once does not wipe data.

The Worker also runs lightweight `ALTER TABLE ... ADD COLUMN` migrations at request time in `src/db.ts`, so existing databases pick up new columns without a dump/restore.

## Prerequisites

- Node.js 20+
- npm (Wrangler 4 is a project `devDependency`)
- A Cloudflare account
- For remote commands: `npx wrangler login`, or `CLOUDFLARE_API_TOKEN` with Workers / D1 / KV / Vectorize permissions

```bash
npm install
npx wrangler login    # remote only
```

## Secrets and environment variables

Never commit `.dev.vars` or wrangler secret values.

| Name | Required | Local | Production | Purpose |
|------|----------|-------|------------|---------|
| `AUTH_SECRET` | Yes | `.dev.vars` | `npx wrangler secret put AUTH_SECRET` | Signs JWTs; also accepted as legacy `Authorization: Bearer` |
| `ADMIN_TOKEN` | Yes | `.dev.vars` | `npx wrangler secret put ADMIN_TOKEN` | Authorizes `POST /register` except trusted `claude.ai` / `poke.com` redirect URIs |
| `OAUTH_REDIRECT_DOMAIN_ALLOWLIST` | No | `.dev.vars` | `npx wrangler secret put OAUTH_REDIRECT_DOMAIN_ALLOWLIST` or `[vars]` | Extra OAuth redirect hostnames. `localhost` and `127.0.0.1` are always allowed |

Generate local values with `openssl rand -hex 32`, then:

```bash
cp .dev.vars.example .dev.vars
# edit the placeholder AUTH_SECRET and ADMIN_TOKEN values
```

`wrangler.toml` holds resource **IDs**, not secrets. Those IDs are account-specific. If you are deploying to a new Cloudflare account, create resources and write the new IDs with `--update-config` (below).

## Repeatable init

`scripts/init-cloudflare.sh` is idempotent: it reuses D1 / KV / Vectorize when they already exist, applies `schema.sql` safely, and never prints secret values.

```bash
npm run cf:check                 # prerequisites + current wrangler.toml bindings
npm run cf:init:local            # local D1 schema + .dev.vars checks
npm run cf:init:remote           # create/reuse remote resources + apply schema
npm run cf:init:remote -- --update-config   # also write discovered IDs into wrangler.toml
npm run cf:init:remote -- --env dev         # wrangler [env.dev] names/IDs
npm run cf:init:local -- --dry-run
```

Equivalent direct calls:

```bash
bash scripts/init-cloudflare.sh --check
bash scripts/init-cloudflare.sh --local
bash scripts/init-cloudflare.sh --remote --update-config
```

Schema-only (skip create/lookup):

```bash
npm run d1:schema:local
npm run d1:schema:remote
# or
bash scripts/init-cloudflare.sh --local --apply-schema-only
bash scripts/init-cloudflare.sh --remote --apply-schema-only
```

## Local development

1. `npm install`
2. `cp .dev.vars.example .dev.vars` and replace placeholders
3. `npm run cf:init:local`
4. `npm run dev`

Wrangler serves the worker at `http://127.0.0.1:8787` by default.

| URL | Use |
|-----|-----|
| `http://127.0.0.1:8787/mcp` | MCP JSON-RPC / SSE |
| `http://127.0.0.1:8787/view` | Web viewer |
| `http://127.0.0.1:8787/.well-known/oauth-authorization-server` | OAuth discovery |

Local D1 is a file under `.wrangler/` (gitignored). Local mode does **not** create remote KV or Vectorize. Semantic search needs Workers AI + Vectorize:

```bash
npx wrangler dev --remote
```

## Production deploy

1. Log in: `npx wrangler login`
2. Create or reuse resources and apply the remote schema:

   ```bash
   npm run cf:init:remote -- --update-config
   ```

3. Set secrets (interactive; values are not echoed by this repo's scripts):

   ```bash
   npx wrangler secret put AUTH_SECRET
   npx wrangler secret put ADMIN_TOKEN
   ```

4. Deploy:

   ```bash
   npm run deploy
   ```

5. Confirm the worker:

   ```bash
   curl -sS https://<your-worker>.<your-subdomain>.workers.dev/
   # expect JSON: name, version, status, tools
   ```

Optional Wrangler environment (`[env.dev]` in `wrangler.toml`):

```bash
npm run cf:init:remote -- --env dev --update-config
npx wrangler secret put AUTH_SECRET --env dev
npx wrangler secret put ADMIN_TOKEN --env dev
npx wrangler deploy --env dev
```

`[env.dev]` currently shares the D1 database name with production. Use a different `database_name` / `database_id` if you need isolated data.

## Manual wrangler commands

Use these if you prefer not to run the init script.

```bash
# D1
npx wrangler d1 create ai-memory
npx wrangler d1 list --json
npx wrangler d1 execute ai-memory --local --file=schema.sql
npx wrangler d1 execute ai-memory --remote --file=schema.sql

# KV (binding RATE_LIMIT_KV)
npx wrangler kv namespace create RATE_LIMIT_KV
npx wrangler kv namespace list

# Vectorize (768 dims, cosine — must match Workers AI bge-base-en-v1.5)
npx wrangler vectorize create ai-memory-semantic-v1 --dimensions=768 --metric=cosine
npx wrangler vectorize list --json

# Secrets
npx wrangler secret list
npx wrangler secret put AUTH_SECRET
npx wrangler secret put ADMIN_TOKEN

# Deploy
npx wrangler deploy
```

After `d1 create` / `kv namespace create`, copy the printed `database_id` and KV `id` into `wrangler.toml`, or re-run the init script with `--update-config`.

## Validation

```bash
npm ci
npm run type-check
npm run test:unit
# equivalent: npm test
```

OAuth isolation smoke test against a running local or remote worker (requires `ADMIN_TOKEN`; does not print tokens):

```bash
ADMIN_TOKEN=... npm run smoke:oauth-isolation
# or against a deployed URL
ADMIN_TOKEN=... bash scripts/smoke_oauth_isolation.sh https://<your-worker>.<your-subdomain>.workers.dev
```

## MCP clients

After the worker is reachable, point clients at `/mcp`. Concrete Claude Desktop, Cursor, and Claude Code configs are in [examples/mcp/](../examples/mcp/README.md).
