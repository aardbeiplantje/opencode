// opencode plugin: llama.cpp slot cache manager
//
// Bridges OpenCode session lifecycle to llama.cpp server slot management.
// - Restores slot KV cache on session start
// - Saves slot KV cache on session.compacted event
// - Periodically saves slot KV cache on idle intervals (configurable)
// - Injects id_slot parameter into chat requests
//
// Requires: python3 installed in the container
// llama.cpp server must be configured with: --slot-save-path <dir>

const PLUGIN_DIR = new URL(import.meta.url).pathname.substring(
  0, new URL(import.meta.url).pathname.lastIndexOf('/')
)
const PYTHON_SCRIPT = PLUGIN_DIR + '/slot_cache.py'

export const SlotCachePlugin = async ({ project, directory, $, dispose, client }) => {
  const LLAMA_SERVER_URL = process.env.LLAMA_SERVER_URL || 'http://[::1]:4000'
  const USER = process.env.USER || process.env.LOGNAME || 'node'
  const SLOT_ID = parseInt(process.env.SLOT_ID || '0', 10)
  const SAVE_INTERVAL_MS = parseInt(process.env.SLOT_SAVE_INTERVAL_MS || '300000', 10)
  const CACHE_BASE_DIR = project ? directory : process.env.HOME || '/home/node'
  const SLOT_CACHE_DIR = `${CACHE_BASE_DIR}/.cache/llama-slots`
  const MODEL_NAME = process.env.LLAMA_MODEL || ''

  function makeCacheName() {
    if (!directory) return `${USER}@root`
    const parts = directory.split('/').filter(Boolean)
    const lastTwo = parts.slice(-2)
    const short = lastTwo.map(p => p.replace(/[^a-zA-Z0-9]/g, '_').slice(0, 20)).join('_')
    return `${USER}@${short}`
  }

  const cacheName = makeCacheName()

  // Restore slot cache on plugin init (session start)
  try {
    const { exitCode } =      await $`python3 ${PYTHON_SCRIPT} check ${LLAMA_SERVER_URL} ${SLOT_ID} ${cacheName} ${SLOT_CACHE_DIR} --model ${MODEL_NAME}`
    if (exitCode === 0) {
      await $`python3 ${PYTHON_SCRIPT} restore ${LLAMA_SERVER_URL} ${SLOT_ID} ${cacheName} ${SLOT_CACHE_DIR} --model ${MODEL_NAME}`
      console.log(`[slot-cache] restored slot ${SLOT_ID} from cache "${cacheName}"`)
    }
  } catch (e) {
    console.log(`[slot-cache] restore check failed (continuing without cache): ${e.message}`)
  }

  // Periodic idle save timer
  let idleTimerId = null
  async function periodicSave() {
    try {
      await $`python3 ${PYTHON_SCRIPT} save ${LLAMA_SERVER_URL} ${SLOT_ID} ${cacheName} ${SLOT_CACHE_DIR} --model ${MODEL_NAME}`
      console.log(`[slot-cache] saved slot ${SLOT_ID} (interval save)`)
    } catch (e) {
      console.log(`[slot-cache] periodic save failed: ${e.message}`)
    }
  }
  idleTimerId = setInterval(periodicSave, SAVE_INTERVAL_MS)

  // Dispose cleanup
  if (dispose) {
    dispose(async () => {
      if (idleTimerId) {
        clearInterval(idleTimerId)
        idleTimerId = null
      }
      try {
        await $`python3 ${PYTHON_SCRIPT} save ${LLAMA_SERVER_URL} ${SLOT_ID} ${cacheName} ${SLOT_CACHE_DIR} --model ${MODEL_NAME}`
        console.log(`[slot-cache] saved slot ${SLOT_ID} on exit`)
      } catch (e) {
        console.log(`[slot-cache] exit save failed: ${e.message}`)
      }
    })
  }

  return {
    // Subscribe to compaction event - save slot on compaction
    event: async ({ event }) => {
      if (event === 'session.compacted') {
        try {
          await $`python3 ${PYTHON_SCRIPT} save ${LLAMA_SERVER_URL} ${SLOT_ID} ${cacheName} ${SLOT_CACHE_DIR} --model ${MODEL_NAME}`
          console.log(`[slot-cache] saved slot ${SLOT_ID} on compaction`)
        } catch (e) {
          console.log(`[slot-cache] compaction save failed: ${e.message}`)
        }
      }
    },

    // Inject id_slot into chat requests to use the cached slot
    'chat.params': async (input, output) => {
      try {
        const { exitCode } = await $`python3 ${PYTHON_SCRIPT} check ${LLAMA_SERVER_URL} ${SLOT_ID} ${cacheName} ${SLOT_CACHE_DIR} --model ${MODEL_NAME}`
        if (exitCode === 0 && input && input.model) {
          if (!input.model.extraBody) input.model.extraBody = {}
          input.model.extraBody.id_slot = SLOT_ID
        }
      } catch {
        // Best effort - don't fail if check fails
      }
    }
  }
}
