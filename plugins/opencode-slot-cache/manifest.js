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
 const RAW_URL = process.env.LLAMA_SERVER_URL || 'http://[::1]:8000'
  const LLAMA_SERVER_URL = RAW_URL.replace(/\/v1(\/.*)?$/, '')
  const USER = process.env.UID || process.env.USER || process.env.LOGNAME || 'node'
  const SLOT_ID = parseInt(process.env.SLOT_ID || '0', 10)
  const SAVE_INTERVAL_MS = parseInt(process.env.SLOT_SAVE_INTERVAL_MS || '300000', 10)
  const CACHE_BASE_DIR = project ? directory : process.env.HOME || '/home/node'
  const SLOT_CACHE_DIR = `${CACHE_BASE_DIR}/.cache/llama-slots`
  const MODEL_NAME = process.env.LLAMA_MODEL || ''

  function makeCacheName() {
    const modelId = MODEL_NAME || 'default'
    const modelShort = modelId.split('/').pop().split(':').shift().replace(/[^a-zA-Z0-9]/g, '_').slice(0, 30)
    if (!directory) return `${USER}_${modelShort}_root`
    const parts = directory.split('/').filter(Boolean)
    const base = parts[parts.length - 1].replace(/[^a-zA-Z0-9]/g, '_').slice(0, 30)
    return `${USER}_${modelShort}_${base}`
  }

  const cacheName = makeCacheName()
  let slotApiAvailable = true

  function slotApiUnav() {
    if (slotApiAvailable) {
      slotApiAvailable = false
      console.log(`[slot-cache] slots API unavailable on ${LLAMA_SERVER_URL} — KV cache persistence disabled`)
      if (idleTimerId) {
        clearInterval(idleTimerId)
        idleTimerId = null
      }
    }
  }

  // Restore slot cache on plugin init (session start)
  if (slotApiAvailable) {
    try {
      const { exitCode } = await $`python3 ${PYTHON_SCRIPT} check ${LLAMA_SERVER_URL} ${SLOT_ID} ${cacheName} ${SLOT_CACHE_DIR} --model ${MODEL_NAME}`
      if (exitCode === 0) {
        await $`python3 ${PYTHON_SCRIPT} restore ${LLAMA_SERVER_URL} ${SLOT_ID} ${cacheName} ${SLOT_CACHE_DIR} --model ${MODEL_NAME}`
        console.log(`[slot-cache] restored slot ${SLOT_ID} from cache "${cacheName}"`)
      } else {
        slotApiUnav()
      }
    } catch (e) {
      slotApiUnav()
    }
  }

  // Periodic idle save timer
  let idleTimerId = null
  async function periodicSave() {
    if (!slotApiAvailable) return
    try {
      await $`python3 ${PYTHON_SCRIPT} save ${LLAMA_SERVER_URL} ${SLOT_ID} ${cacheName} ${SLOT_CACHE_DIR} --model ${MODEL_NAME}`
      console.log(`[slot-cache] saved slot ${SLOT_ID} (interval save)`)
    } catch (e) {
      slotApiUnav()
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
      if (slotApiAvailable) {
        try {
          await $`python3 ${PYTHON_SCRIPT} save ${LLAMA_SERVER_URL} ${SLOT_ID} ${cacheName} ${SLOT_CACHE_DIR} --model ${MODEL_NAME}`
          console.log(`[slot-cache] saved slot ${SLOT_ID} on exit`)
        } catch (e) {
          slotApiUnav()
        }
      }
    })
  }

  return {
    // Subscribe to compaction event - save slot on compaction
    event: async ({ event }) => {
      if (event === 'session.compacted') {
        if (!slotApiAvailable) return
        try {
          await $`python3 ${PYTHON_SCRIPT} save ${LLAMA_SERVER_URL} ${SLOT_ID} ${cacheName} ${SLOT_CACHE_DIR} --model ${MODEL_NAME}`
          console.log(`[slot-cache] saved slot ${SLOT_ID} on compaction`)
        } catch (e) {
          slotApiUnav()
        }
      }
    },

    // Inject id_slot into chat requests to use the cached slot
    'chat.params': async (input, output) => {
      if (!slotApiAvailable) return
      try {
        const { exitCode } = await $`python3 ${PYTHON_SCRIPT} check ${LLAMA_SERVER_URL} ${SLOT_ID} ${cacheName} ${SLOT_CACHE_DIR} --model ${MODEL_NAME}`
        if (exitCode === 0 && input && input.model) {
          if (!input.model.extraBody) input.model.extraBody = {}
          input.model.extraBody.id_slot = SLOT_ID
        } else {
          slotApiUnav()
        }
      } catch {
        slotApiUnav()
      }
    }
  }
}
