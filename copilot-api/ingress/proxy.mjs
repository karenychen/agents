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

const server = http.createServer((clientRequest, clientResponse) => {
  const upstreamRequest = http.request(
    {
      protocol: upstreamOrigin.protocol,
      hostname: upstreamOrigin.hostname,
      port: upstreamOrigin.port,
      method: clientRequest.method,
      path: clientRequest.url,
      headers: forwardHeaders(clientRequest.headers),
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
  })

  pipeline(clientRequest, upstreamRequest, () => {})
})

server.listen(listenPort, listenHost, () => {
  console.error(`copilot-api ingress listening on ${listenHost}:${listenPort}`)
})
