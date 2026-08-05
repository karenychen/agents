import http from "node:http"
import { pipeline } from "node:stream"

const listenHost = process.env.LISTEN_HOST ?? "0.0.0.0"
const listenPort = Number.parseInt(process.env.LISTEN_PORT ?? "4000", 10)
const upstreamOrigin = new URL(
  process.env.UPSTREAM_ORIGIN ?? "http://copilot-api:4141",
)

const hopByHopHeaders = new Set([
  "connection",
  "keep-alive",
  "proxy-authenticate",
  "proxy-authorization",
  "te",
  "trailer",
  "transfer-encoding",
  "upgrade",
])

const responsePaths = new Set(["/responses", "/v1/responses"])
const maxBufferedRequestBytes = 128 * 1024 * 1024
const dropValue = Symbol("dropValue")

function forwardHeaders(headers) {
  const forwarded = {}
  for (const [name, value] of Object.entries(headers)) {
    if (!hopByHopHeaders.has(name.toLowerCase()) && value !== undefined) {
      forwarded[name] = value
    }
  }
  forwarded.host = upstreamOrigin.host
  return forwarded
}

function shouldSanitizeRequest(clientRequest) {
  const path = new URL(clientRequest.url ?? "/", "http://localhost").pathname
  const contentType = clientRequest.headers["content-type"] ?? ""

  return (
    clientRequest.method === "POST"
    && responsePaths.has(path)
    && String(contentType).toLowerCase().includes("application/json")
  )
}

function readRequestBody(clientRequest) {
  return new Promise((resolve, reject) => {
    const chunks = []
    let length = 0

    clientRequest.on("data", (chunk) => {
      length += chunk.length
      if (length > maxBufferedRequestBytes) {
        reject(new Error("request body is too large to sanitize"))
        clientRequest.destroy()
        return
      }
      chunks.push(chunk)
    })

    clientRequest.on("end", () => resolve(Buffer.concat(chunks)))
    clientRequest.on("error", reject)
  })
}

function sanitizeResponsesValue(value) {
  if (Array.isArray(value)) {
    return value
      .map(sanitizeResponsesValue)
      .filter((item) => item !== dropValue)
  }

  if (value === null || typeof value !== "object") {
    return value
  }

  const isCustomToolCall = value.type === "custom_tool_call"
  if (
    "encrypted_content" in value
    && (value.type === "reasoning" || value.type === "compaction")
  ) {
    return dropValue
  }

  const sanitized = {}
  for (const [key, childValue] of Object.entries(value)) {
    if (key === "internal_chat_message_metadata_passthrough") {
      continue
    }
    if (key === "encrypted_content") {
      continue
    }
    if (isCustomToolCall && (key === "id" || key === "status")) {
      continue
    }
    sanitized[key] = sanitizeResponsesValue(childValue)
  }
  return sanitized
}

function sanitizeRequestBody(body) {
  try {
    return Buffer.from(
      JSON.stringify(sanitizeResponsesValue(JSON.parse(body.toString("utf8")))),
    )
  } catch {
    return body
  }
}

function writeBadGateway(clientResponse) {
  if (!clientResponse.headersSent) {
    clientResponse.writeHead(502, { "content-type": "application/json" })
  }
  clientResponse.end(
    JSON.stringify({
      error: {
        message: "copilot-api upstream is unavailable",
        type: "bad_gateway",
      },
    }),
  )
}

function writePayloadTooLarge(clientResponse) {
  if (!clientResponse.headersSent) {
    clientResponse.writeHead(413, { "content-type": "application/json" })
  }
  clientResponse.end(
    JSON.stringify({
      error: {
        message: "request body is too large to sanitize",
        type: "payload_too_large",
      },
    }),
  )
}

function createUpstreamRequest(clientRequest, clientResponse, body) {
  const headers = forwardHeaders(clientRequest.headers)
  if (body) {
    headers["content-length"] = String(body.length)
  }

  const upstreamRequest = http.request(
    {
      protocol: upstreamOrigin.protocol,
      hostname: upstreamOrigin.hostname,
      port: upstreamOrigin.port,
      method: clientRequest.method,
      path: clientRequest.url,
      headers,
    },
    (upstreamResponse) => {
      clientResponse.writeHead(
        upstreamResponse.statusCode ?? 502,
        upstreamResponse.statusMessage,
        forwardHeaders(upstreamResponse.headers),
      )
      pipeline(upstreamResponse, clientResponse, () => {})
    },
  )

  upstreamRequest.on("error", () => {
    writeBadGateway(clientResponse)
  })

  if (body) {
    upstreamRequest.end(body)
    return
  }

  pipeline(clientRequest, upstreamRequest, () => {})
}

const server = http.createServer(async (clientRequest, clientResponse) => {
  if (!shouldSanitizeRequest(clientRequest)) {
    createUpstreamRequest(clientRequest, clientResponse)
    return
  }

  try {
    const body = await readRequestBody(clientRequest)
    createUpstreamRequest(
      clientRequest,
      clientResponse,
      sanitizeRequestBody(body),
    )
  } catch {
    writePayloadTooLarge(clientResponse)
  }
})

server.listen(listenPort, listenHost, () => {
  console.error(`copilot-api ingress listening on ${listenHost}:${listenPort}`)
})
