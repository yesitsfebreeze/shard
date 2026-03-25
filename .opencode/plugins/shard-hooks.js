export const ShardHooks = async ({ $, client, directory }) => {
  const createdHook = `${directory}/.opencode/hooks/session-created.sh`
  const idleHook = `${directory}/.opencode/hooks/session-idle.sh`
  const readCacheHook = `${directory}/.opencode/hooks/context-cache-read.py`

  const readCachedContext = async () => {
    const out = await $`python3 ${readCacheHook}`.text()
    return out.trim()
  }

  return {
    event: async ({ event }) => {
      try {
        if (event.type === "session.created") {
          await $`bash ${createdHook}`
          await client.app.log({
            body: {
              service: "shard-hooks",
              level: "info",
              message: "session.created shard hooks executed",
            },
          })
        }

        if (event.type === "session.idle") {
          await $`bash ${idleHook}`
          await client.app.log({
            body: {
              service: "shard-hooks",
              level: "info",
              message: "session.idle shard compact executed",
            },
          })
        }
      } catch (error) {
        await client.app.log({
          body: {
            service: "shard-hooks",
            level: "warn",
            message: "shard hook execution failed",
            extra: { error: String(error) },
          },
        })
      }
    },

    "experimental.session.compacting": async (_input, output) => {
      try {
        const cached = await readCachedContext()
        if (!cached) return

        output.context.push(
          [
            "## CACHED SHARD CONTEXT (PINNED)",
            "When compacting, exclude any prior block with this same heading from the summary.",
            "Preserve the section below verbatim in the continuation context.",
            "",
            cached,
          ].join("\n"),
        )
      } catch (error) {
        await client.app.log({
          body: {
            service: "shard-hooks",
            level: "warn",
            message: "failed to append cached shard context during compaction",
            extra: { error: String(error) },
          },
        })
      }
    },
  }
}
