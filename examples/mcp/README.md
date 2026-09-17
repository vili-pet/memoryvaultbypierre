# MCP client configuration

MemoryVault is a **remote HTTP MCP server** on Cloudflare Workers. The Worker entry point is `src/index.ts` (`wrangler.toml` `main`). The MCP transport is:

| Environment | Command | MCP URL |
|-------------|---------|---------|
| Local | `npm run dev` | `http://127.0.0.1:8787/mcp` |
| Production | `npm run deploy` | `https://<YOUR_WORKER>.<YOUR_SUBDOMAIN>.workers.dev/mcp` |

Replace placeholders before use:

| Placeholder | Replace with |
|-------------|--------------|
| `YOUR_WORKER` | Wrangler worker name. Default in this repo: `ai-memory-mcp` |
| `YOUR_SUBDOMAIN` | Your Cloudflare workers.dev subdomain |
| `YOUR_AUTH_SECRET` | Same value as the worker `AUTH_SECRET` (legacy bearer mode only) |
| `http://127.0.0.1:8787` | Local Wrangler URL if you changed the default port |

Do not commit real secrets into these files.

## Auth modes

**OAuth (recommended).** Leave the client API key / header empty. The server returns `WWW-Authenticate` plus `/.well-known/oauth-authorization-server` and `/.well-known/oauth-protected-resource`. The client completes PKCE (`S256` only). Trusted hosted-client redirect hosts (`claude.ai`, `poke.com`) can register without `ADMIN_TOKEN`; other redirect hosts need `Authorization: Bearer <ADMIN_TOKEN>` on `POST /register`.

**Legacy bearer.** Send `Authorization: Bearer <AUTH_SECRET>`. Useful for scripts and stdio bridges. Anyone with this secret has full access to the legacy shared brain — treat it like a password.

## Example files

| File | Client | Auth |
|------|--------|------|
| [claude-desktop.oauth.json](./claude-desktop.oauth.json) | Claude Desktop, native remote URL | OAuth |
| [claude-desktop.mcp-remote.json](./claude-desktop.mcp-remote.json) | Claude Desktop, `npx mcp-remote` stdio bridge | OAuth via the bridge |
| [claude-desktop.bearer.json](./claude-desktop.bearer.json) | Claude Desktop, `mcp-remote` + bearer header | `AUTH_SECRET` |
| [claude-desktop.local.json](./claude-desktop.local.json) | Claude Desktop against `npm run dev` | OAuth on localhost |
| [cursor.mcp.json](./cursor.mcp.json) | Cursor project or user MCP config | OAuth |

Copy the JSON into the client config path below. Restart the client after editing.

## Claude Desktop

Config file:

- macOS: `~/Library/Application Support/Claude/claude_desktop_config.json`
- Windows: `%APPDATA%\Claude\claude_desktop_config.json`
- Linux: `~/.config/Claude/claude_desktop_config.json`

Merge the `mcpServers.memoryvault` object from an example file into that JSON. Native remote URL (current Claude Desktop):

```json
{
  "mcpServers": {
    "memoryvault": {
      "url": "https://YOUR_WORKER.YOUR_SUBDOMAIN.workers.dev/mcp"
    }
  }
}
```

If your Claude Desktop build does not accept `url`, use the `mcp-remote` stdio bridge in `claude-desktop.mcp-remote.json`.

## Cursor

Project file: `.cursor/mcp.json`  
User file: `~/.cursor/mcp.json`

```json
{
  "mcpServers": {
    "memoryvault": {
      "url": "https://YOUR_WORKER.YOUR_SUBDOMAIN.workers.dev/mcp"
    }
  }
}
```

See [cursor.mcp.json](./cursor.mcp.json).

## Claude Code

```bash
claude mcp add --transport http memoryvault \
  https://YOUR_WORKER.YOUR_SUBDOMAIN.workers.dev/mcp
```

Local worker:

```bash
claude mcp add --transport http memoryvault-local \
  http://127.0.0.1:8787/mcp
```

Bearer fallback:

```bash
claude mcp add --transport http memoryvault \
  https://YOUR_WORKER.YOUR_SUBDOMAIN.workers.dev/mcp \
  --header "Authorization: Bearer YOUR_AUTH_SECRET"
```

## ChatGPT and other HTTP MCP clients

Set the server URL to `https://YOUR_WORKER.YOUR_SUBDOMAIN.workers.dev/mcp` and leave the API key empty for OAuth. Discovery documents:

- `https://YOUR_WORKER.YOUR_SUBDOMAIN.workers.dev/.well-known/oauth-authorization-server`
- `https://YOUR_WORKER.YOUR_SUBDOMAIN.workers.dev/.well-known/oauth-protected-resource`

Browser navigation to `/mcp` shows a human guide; programmatic MCP requests still receive the OAuth challenge unless authorized.
