// opencode plugin: llama.cpp slot cache manager
//
// Bridges OpenCode session lifecycle to llama.cpp server slot management.
// - On session start (session.idle): restores cached slot KV, or saves a new one if none exists
// - Saves slot KV cache on session.compacted / session.deleted events
// - Periodically saves slot KV cache on idle intervals (configurable)
// - Injects id_slot parameter into chat requests (when cache exists)
//
// Requires: python3 installed in the container
// llama.cpp server must be configured with: --slot-save-path <dir>

const PLUGIN_DIR = new URL(import.meta.url).pathname.substring(
  0, new URL(import.meta.url).pathname.lastIndexOf('/')
)
const PYTHON_SCRIPT = PLUGIN_DIR + '/slot_cache.py'

const LOG_FILE = `${PLUGIN_DIR}/slot_cache.log`

let logFd = null

async function openLogFile() {
  if (logFd) return logFd
  try {
    const fs = await import('fs/promises')
    const path = await import('path')
    const logDir = path.dirname(LOG_FILE)
    await fs.mkdir(logDir, { recursive: true })
    logFd = await fs.open(LOG_FILE, 'a')
    return logFd
  } catch (e) {
    return null
  }
}

async function logToFile(level, message) {
  const timestamp = new Date().toISOString()
  const entry = `[${timestamp}] [slot-cache] [${level}] ${message}\n`
  try {
    const fd = await openLogFile()
    if (fd) {
      await fd.write(entry)
    }
  } catch (e) {
    // silently ignore logging failures
  }
}

async function closeLogFile() {
  if (logFd) {
    try {
      await logFd.close()
    } catch (e) {
      // ignore
    }
    logFd = null
  }
}

async function runPython(args) {
  try {
    const child = Bun.spawn(
      ['python3', PYTHON_SCRIPT, ...args],
      {
        stdio: ['pipe', 'pipe', 'pipe'],
        env: { ...process.env, PYTHONUNBUFFERED: '1' },
      }
    )
    const { exitCode } = await child.exited
    return { exitCode }
  } catch (e) {
    logToFile('ERROR', `spawn error: ${e.message || e}`)
    return { exitCode: -1 }
  }
}

export const SlotCachePlugin = async ({ directory, $, dispose }) => {
  const RAW_URL = process.env.LLAMA_SERVER_URL || 'http://[::1]:8000'
  const LLAMA_SERVER_URL = RAW_URL.replace(/\/v1(\/.*)?$/, '')
  const USER = process.env.UID || process.env.USER || process.env.LOGNAME || 'node'
  const SLOT_ID = parseInt(process.env.SLOT_ID || '0', 10)
  const SAVE_INTERVAL_MS = parseInt(process.env.SLOT_SAVE_INTERVAL_MS || '300000', 10)
  const CACHE_BASE_DIR = process.env.HOME || '/home/node'
  const SLOT_CACHE_DIR = `${CACHE_BASE_DIR}/.cache/llama-slots`
  const MODEL_NAME = process.env.LLAMA_MODEL || ''

  function makeCacheName(sessionId) {
    const modelId = MODEL_NAME || 'default'
    const modelShort = modelId.split('/').pop().split(':').shift().replace(/[^a-zA-Z0-9]/g, '_').slice(0, 30)
    if (!directory) return `${USER}_${modelShort}_root_${sessionId?.slice(0,8) || 'none'}`
    const parts = directory.split('/').filter(Boolean)
    const base = parts[parts.length - 1].replace(/[^a-zA-Z0-9]/g, '_').slice(0, 30)
    return `${USER}_${modelShort}_${base}_${sessionId?.slice(0,8) || 'none'}`
  }

  let slotApiAvailable = true
  let currentSessionId = null
  let cacheName = null
  let _checkedCache = false

  function slotApiUnav() {
    if (slotApiAvailable) {
      slotApiAvailable = false
      logToFile('ERROR', `slots API unavailable on ${LLAMA_SERVER_URL} — KV cache persistence disabled`)
      if (idleTimerId) {
        clearInterval(idleTimerId)
        idleTimerId = null
      }
    }
  }

  function updateCacheName(sessionId) {
    if (sessionId && sessionId !== currentSessionId) {
      currentSessionId = sessionId
      cacheName = makeCacheName(sessionId)
      logToFile('INFO', `cache name updated to "${cacheName}" for session ${sessionId.slice(0,8)}`)
    }
  }

  async function pythonRun(args, logPrefix) {
    const cmdStr = `python3 ${PYTHON_SCRIPT} ${args.join(' ')}`
    logToFile('INFO', `${logPrefix}: ${cmdStr}`)
    return await runPython(args)
  }

  // Periodic idle save timer
  let idleTimerId = null
  async function periodicSave() {
    if (!slotApiAvailable || !cacheName) return
    try {
      const { exitCode } = await pythonRun(
        ['save', LLAMA_SERVER_URL, String(SLOT_ID), cacheName, SLOT_CACHE_DIR, '--model', MODEL_NAME],
        'periodic save'
      )
      if (exitCode === 0) {
        logToFile('INFO', `saved slot ${SLOT_ID} (interval save), exitCode=${exitCode}`)
      } else {
        logToFile('WARN', `periodic save failed for slot ${SLOT_ID}, exitCode=${exitCode}`)
      }
    } catch (e) {
      logToFile('ERROR', `periodic save error: ${e.message || e}`)
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
      if (slotApiAvailable && cacheName) {
        try {
          const { exitCode } = await pythonRun(
            ['save', LLAMA_SERVER_URL, String(SLOT_ID), cacheName, SLOT_CACHE_DIR, '--model', MODEL_NAME],
            'save on exit'
          )
          if (exitCode === 0) {
            logToFile('INFO', `saved slot ${SLOT_ID} on exit, exitCode=${exitCode}`)
          } else {
            logToFile('WARN', `save on exit failed for slot ${SLOT_ID}, exitCode=${exitCode}`)
          }
        } catch (e) {
          logToFile('ERROR', `save on exit error: ${e.message || e}`)
        }
      }
      await closeLogFile()
    })
  }

  return {
    // Subscribe to session lifecycle events
    event: async ({ event }) => {
      if (!slotApiAvailable) return
      try {
        // Capture session ID at session start (session.idle)
        if (event.type === 'session.idle') {
          logToFile('INFO', `got {event.type}`)
          const sid = event.properties?.sessionID
          if (sid) {
            updateCacheName(sid)
          }
          logToFile('INFO', `event: ${event.type}, sessionID=${sid?.slice(0,8)}`)
          // Try to restore cached slot; if no cache exists, immediately save to create one
          if (cacheName) {
            // Step 1: try restore
            const { exitCode: restoreExit } = await pythonRun(
              ['restore', LLAMA_SERVER_URL, String(SLOT_ID), cacheName, SLOT_CACHE_DIR, '--model', MODEL_NAME],
              'startup restore'
            )
            if (restoreExit === 0) {
              logToFile('INFO', `restored slot ${SLOT_ID} from cache`)
            } else {
              // No cache yet — immediately save to create one
              logToFile('INFO', `no cache to restore for slot ${SLOT_ID} (exit ${restoreExit}), saving now`)
              const { exitCode: saveExit } = await pythonRun(
                ['save', LLAMA_SERVER_URL, String(SLOT_ID), cacheName, SLOT_CACHE_DIR, '--model', MODEL_NAME],
                'startup save'
              )
              if (saveExit === 0) {
                logToFile('INFO', `saved slot ${SLOT_ID} (initial save)`)
              } else {
                logToFile('WARN', `initial save failed for slot ${SLOT_ID}, exitCode=${saveExit}`)
              }
            }
          }
          return
        }
        // Save on compact/delete
        if (event.type === 'session.compacted' || event.type === 'session.deleted') {
          logToFile('INFO', `got {event.type}`)
          if (!cacheName) {
            const sid = event.properties?.sessionID || event.properties?.info?.sessionID
            if (sid) updateCacheName(sid)
          }
          if (cacheName) {
            const { exitCode } = await pythonRun(
              ['save', LLAMA_SERVER_URL, String(SLOT_ID), cacheName, SLOT_CACHE_DIR, '--model', MODEL_NAME],
              `save on ${event.type}`
            )
            if (exitCode === 0) {
              logToFile('INFO', `saved slot ${SLOT_ID} on ${event.type}, exitCode=${exitCode}`)
            } else {
              logToFile('WARN', `save on ${event.type} failed for slot ${SLOT_ID}, exitCode=${exitCode}`)
            }
          }
        }
      } catch (e) {
        logToFile('ERROR', `event handler error for ${event.type}: ${e.message || e}`)
      }
    },

    // Inject id_slot into chat requests to use the cached slot
    'chat.params': async (input, output) => {
      logToFile('INFO', `got chat.params {input}`)
      if (!slotApiAvailable) return
      try {
        // Extract sessionID from hook input
        const sid = input?.sessionID
        if (sid) updateCacheName(sid)
        if (!cacheName) {
          logToFile('INFO', 'chat.params: no cache name yet, skipping check (session may not be initialized)')
          return
        }
        const { exitCode } = await pythonRun(
          ['check', LLAMA_SERVER_URL, String(SLOT_ID), cacheName, SLOT_CACHE_DIR, '--model', MODEL_NAME],
          'check cache'
        )
        _checkedCache = true
        if (exitCode === 0 && input && input.model) {
          if (!input.model.extraBody) input.model.extraBody = {}
          input.model.extraBody.id_slot = SLOT_ID
          logToFile('INFO', `cache found for slot ${SLOT_ID}, injected id_slot=${SLOT_ID}`)
        } else if (exitCode === 1) {
          // No cache yet — this is normal for a new session. Do NOT disable the plugin.
          // A save operation will create the cache, and then it can be loaded.
          logToFile('INFO', `no cache yet for slot ${SLOT_ID} (exit 1), normal for new session`)
        } else if (exitCode === 2) {
          // Server API is known incompatible
          logToFile('WARN', `slots API unavailable for slot ${SLOT_ID} (exit 2)`)
          slotApiUnav()
        } else {
          logToFile('WARN', `unexpected exit code ${exitCode} from check command`)
        }
      } catch (e) {
        logToFile('ERROR', `chat.params check error: ${e.message || e}`)
        // Only disable if we've already confirmed the cache exists and now fails
        if (_checkedCache) {
          slotApiUnav()
        }
      }
    }
  }
}
