#!/usr/bin/env node
// Minimal wrangler.toml binding reader/writer. No extra dependencies.
// Usage:
//   node scripts/lib/wrangler-toml.mjs get <file> <env|""> <d1|kv|vectorize> <key>
//   node scripts/lib/wrangler-toml.mjs set <file> <env|""> <d1|kv|vectorize> <key> <value>

import { readFileSync, writeFileSync } from 'node:fs';

const SECTION_TABLES = {
  d1: 'd1_databases',
  kv: 'kv_namespaces',
  vectorize: 'vectorize',
};

function sectionHeader(envName, section) {
  const table = SECTION_TABLES[section];
  if (!table) {
    throw new Error(`Unknown section: ${section}`);
  }
  return envName ? `[[env.${envName}.${table}]]` : `[[${table}]]`;
}

function extractSection(text, header) {
  const start = text.indexOf(header);
  if (start < 0) return null;
  const afterHeader = start + header.length;
  const rest = text.slice(afterHeader);
  const next = rest.search(/\n\[/);
  const body = next === -1 ? rest : rest.slice(0, next);
  return { start, header, body, end: afterHeader + body.length };
}

function readKey(body, key) {
  const re = new RegExp(`^[ \\t]*${key}[ \\t]*=[ \\t]*"([^"]*)"`, 'm');
  return body.match(re)?.[1] ?? null;
}

function writeKey(body, key, value) {
  const re = new RegExp(`^([ \\t]*${key}[ \\t]*=[ \\t]*")([^"]*)(")`, 'm');
  if (!re.test(body)) return null;
  return body.replace(re, `$1${value}$3`);
}

const [command, file, envName, section, key, nextValue] = process.argv.slice(2);
if (!command || !file || !section || !key) {
  console.error('Usage: wrangler-toml.mjs get|set <file> <env> <section> <key> [value]');
  process.exit(1);
}

const text = readFileSync(file, 'utf8');
const header = sectionHeader(envName && envName !== 'production' ? envName : '', section);
const found = extractSection(text, header);
if (!found) {
  console.error(`Section ${header} not found in ${file}`);
  process.exit(2);
}

if (command === 'get') {
  const value = readKey(found.body, key);
  if (value == null) {
    console.error(`Key ${key} not found in ${header}`);
    process.exit(3);
  }
  process.stdout.write(value);
  process.exit(0);
}

if (command === 'set') {
  if (nextValue == null) {
    console.error('set requires a value');
    process.exit(1);
  }
  const updatedBody = writeKey(found.body, key, nextValue);
  if (updatedBody == null) {
    console.error(`Key ${key} not found in ${header}`);
    process.exit(3);
  }
  writeFileSync(file, text.slice(0, found.start + found.header.length) + updatedBody + text.slice(found.end));
  process.exit(0);
}

console.error(`Unknown command: ${command}`);
process.exit(1);
