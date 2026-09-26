# How `dsh plugin add` bricked my profile — twice — and the install method that can't

If your [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) tools suddenly fail with

```
TypeError: Cannot read properties of undefined (reading 'prepare')
```

— and `web_search` doesn't error, it just returns **"no results"** — your profile has a **split
`Symbol`**. Both symptoms are the same broken thing.

This is what causes it, how to confirm it in ten seconds, and how to install plugins so it cannot
happen. Verified against **DSH 0.1.1-rc.2**.

```bash
bash diagnose.sh          # or: curl the file and read it first, it is 60 lines
```

## The short version

- DSH tool dispatch looks up its scheduler through a **module-level `Symbol`**.
- Two physical copies of `@deepseek-ai/dsh-tools` → two `Symbol` instances → the lookup returns
  `undefined` → **every** tool call throws.
- `dsh plugin --profile web add <pkg>` **runs pnpm inside your profile directory**. That is what
  creates the second copy.
- So "use the official CLI, and never run pnpm inside a profile" is self-contradictory advice — and
  it is repeated in a lot of places, including notes I wrote myself.

## Why a Symbol, and why two copies break everything

`@deepseek-ai/dsh-tools` defines the scheduler key once, at module scope:

```js
// @deepseek-ai/dsh-tools/lib/index.js:2416
const TOOL_RUNTIME_SCHEDULER = Symbol("@deepseek-ai/dsh-tools.scheduler");

// @deepseek-ai/dsh-tools/lib/index.js:2564
ToolRuntime[TOOL_RUNTIME_SCHEDULER] = { prepare, dispatch, finalize, finish };
```

and the agent loop reads it back:

```js
// @deepseek-ai/dsh-agent-loop/lib/index.js:193
const prepared = await ctx.tools[TOOL_RUNTIME_SCHEDULER].prepare(call.exec);
```

A `Symbol` is **identity, not a string**. `Symbol("x") === Symbol("x")` is `false`. So if the loop
loads `dsh-tools` from copy A and the runtime registered itself from copy B, the key in
`ctx.tools` is not the key being looked up — the lookup is `undefined`, and `.prepare()` throws.

The nastiest part is the blast radius: **nothing about the tool you called matters**. Every tool dies,
including ones from packages you never touched, which is why it reads like a total harness failure
rather than a bad install.

## Why pnpm inside a profile creates the second copy

Profiles use a hoisted linker, and plugins declare `@deepseek-ai/*` as **peer dependencies**. When
pnpm runs with the profile as its working directory, it satisfies those peers by writing **real
directories** where the profile previously had **symlinks** into the single global copy:

```
~/.dsh/profiles/node_modules/@deepseek-ai/dsh-tools      -> symlink, one global copy   (healthy)
~/.dsh/profiles/web/node_modules/@deepseek-ai/dsh-tools  -> real directory, second copy (split)
```

Two physical trees. Two `Symbol`s. The next tool call crashes.

And the official CLI is exactly that:

```js
// @deepseek-ai/dsh/lib/bin.js:96
program.command("plugin")
  .description("manage a profile's plugins by forwarding the remaining arguments to pnpm in the profile directory")

// @deepseek-ai/dsh/lib/plugin-9h8shc4d.js:108
const result = spawnSync("pnpm", args.map((a) => anchorPathSpec(a, process.cwd())), { cwd: dir, ... })
```

The CLI is a deliberate, documented pnpm forwarder. It is not a bug — it is the design — but it means
**the command you are told to use is the command that breaks the profile.**

A local, hand-written plugin makes it worse, because peer dependencies on `@deepseek-ai/*` are the
normal way to write one: our own plugin declares `cordis`, `dsh-host-webserver`, `dsh-storage-domain`
and `dsh-tools` as peers. Installing *that* through the CLI is the recipe exactly.

## Confirm it in ten seconds

The tell is a **real directory** where there should be a symlink:

```bash
find ~/.dsh/profiles -type d -path '*/node_modules/@deepseek-ai/*'
```

- **No output** — healthy. The profile's `@deepseek-ai/*` entries are symlinks into one global copy.
- **Any output** — a materialized duplicate. The next tool call will split the Symbol.

### The check that cries wolf

The usual advice is "count the physical copies, there must be exactly one":

```bash
find ~/.dsh ~/.nvm/versions/node/*/lib/node_modules -type d -name dsh-tools | xargs realpath | sort -u
```

**This over-reports.** If you have two Node versions installed, that command finds a `dsh-tools` under
each — and that is *not* a split. A process running Node v24 cannot load the copy under
`versions/node/v22`, no matter what is on disk. Only copies **reachable from the node that is actually
running dsh** can collide.

`diagnose.sh` in this repo does it properly: it finds the node from the running process, then reports
which copies that node could load.

## Install plugins without creating a second copy

### A. Copy the files — what I do now

No package manager is ever involved, so the failure mode does not exist:

```bash
DEST="$HOME/.dsh/profiles/web/node_modules/<pkg-name>"
mkdir -p "$DEST"
cp -r <src>/lib <src>/package.json "$DEST"/
```

Then register it in the profile's patch layer (`~/.dsh/profiles/web/cordis.patch.yml`):

```yaml
- insert:
    - id: <id>
      name: '<pkg-name>'
```

Bare `@deepseek-ai/*` imports resolve through `~/.dsh/profiles/node_modules/` — the shared tree of
symlinks into the global copy — so **no dependency needs installing at all**. That is the point: the
plugin's peers are already satisfied by the one copy that exists.

This is not a workaround I invented; it is how a plugin I wrote by hand has been installed since
2026-09-02. It has survived server restarts and a full harness reinstall, precisely because there is
no dependency edge to re-resolve.

### B. If you must use a package manager

Do it **anywhere except a profile**, then copy the result in:

```bash
mkdir -p /tmp/pkg && cd /tmp/pkg && pnpm add <pkg>@<version>
cp -r /tmp/pkg/node_modules/<pkg> "$HOME/.dsh/profiles/web/node_modules/"
```

Never `pnpm install`, `npm install` or `dsh plugin add` with a profile as the working directory.

## If it already crashed

1. Remove the materialized copy so resolution falls back to the single global tree:
   ```bash
   rm -rf ~/.dsh/profiles/web/node_modules/@deepseek-ai
   ```
2. Restart the server.
3. Re-run the `find` above until it prints nothing.
4. **Re-install your plugins by copying files**, not through the CLI, or you will be back here.

What did *not* work for me either time: restarting alone, clearing caches, or reinstalling the plugin
that "caused" it. The duplicate is on disk; it has to be removed.

## The subtler variant, in case you hit it with no duplicate on disk

`dsh-tools` ships a **dual build**: the main `lib/index.js` and the subpath `lib/types/*.js` each
define their own `Symbol`. A plugin that imports `@deepseek-ai/dsh-tools/types` (or `./presentation`)
directly, while the core uses the main entry, splits the Symbol **even with exactly one copy on disk**.
If the `find` is clean and you still crash, check what your plugins import.

## Credit where it is due

None of this is a criticism of DSH's design — pnpm-in-profile is a reasonable default, and the CRASH
is a consequence of using Symbols for identity, which is also reasonable. It is a sharp edge that is
easy to walk into and hard to diagnose from the error message, so this page exists.

Tested on: DSH `0.1.1-rc.2`, Node `v24.20.0`, Linux.

## Licence

MIT — see `LICENSE`.
