import http from "node:http"
import net from "node:net"
import { pipeline } from "node:stream"

const listenHost = process.env.LISTEN_HOST ?? "0.0.0.0"
const listenPort = Number.parseInt(process.env.LISTEN_PORT ?? "3128", 10)
const allowedHosts = new Set(
  (process.env.ALLOWED_HOSTS ?? "")
    .split(",")
    .map((host) => host.trim().toLowerCase())
    .filter(Boolean),
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

function normalizeHost(host) {
  return host.trim().replace(/\.$/, "").toLowerCase()
}

function parseAuthority(authority) {
  const [host, port = "443"] = authority.split(":")
  return {
    host: normalizeHost(host),
    port: Number.parseInt(port, 10),
  }
}

function isAllowed(host, port) {
  return port === 443 && allowedHosts.has(normalizeHost(host))
}

function filteredHeaders(headers) {
  const forwarded = {}
  for (const [name, value] of Object.entries(headers)) {
    if (!hopByHopHeaders.has(name.toLowerCase()) && value !== undefined) {
      forwarded[name] = value
    }
  }
  return forwarded
}

const server = http.createServer((clientRequest, clientResponse) => {
  let target
  try {
    target = new URL(clientRequest.url)
  } catch {
    clientResponse.writeHead(400, { "content-type": "text/plain" })
    clientResponse.end("absolute proxy URL required\n")
    return
  }

  const port =
    target.port ? Number.parseInt(target.port, 10)
    : target.protocol === "https:" ? 443
    : 80

  if (!isAllowed(target.hostname, port)) {
    clientResponse.writeHead(403, { "content-type": "text/plain" })
    clientResponse.end("target host is not allowlisted\n")
    return
  }

  const upstreamRequest = http.request(
    {
      protocol: target.protocol,
      hostname: target.hostname,
      port,
      method: clientRequest.method,
      path: `${target.pathname}${target.search}`,
      headers: filteredHeaders(clientRequest.headers),
    },
    (upstreamResponse) => {
      clientResponse.writeHead(
        upstreamResponse.statusCode ?? 502,
        upstreamResponse.statusMessage,
        filteredHeaders(upstreamResponse.headers),
      )
      pipeline(upstreamResponse, clientResponse, () => {})
    },
  )

  upstreamRequest.on("error", () => {
    if (!clientResponse.headersSent) {
      clientResponse.writeHead(502, { "content-type": "text/plain" })
    }
    clientResponse.end("egress proxy upstream request failed\n")
  })

  pipeline(clientRequest, upstreamRequest, () => {})
})

server.on("connect", (request, clientSocket, head) => {
  const { host, port } = parseAuthority(request.url)
  if (!isAllowed(host, port)) {
    clientSocket.write("HTTP/1.1 403 Forbidden\r\n\r\n")
    clientSocket.destroy()
    return
  }

  const upstreamSocket = net.connect(port, host, () => {
    clientSocket.write("HTTP/1.1 200 Connection Established\r\n\r\n")
    if (head.length > 0) {
      upstreamSocket.write(head)
    }
    pipeline(clientSocket, upstreamSocket, () => {})
    pipeline(upstreamSocket, clientSocket, () => {})
  })

  upstreamSocket.on("error", () => {
    clientSocket.write("HTTP/1.1 502 Bad Gateway\r\n\r\n")
    clientSocket.destroy()
  })
})

server.listen(listenPort, listenHost, () => {
  console.error(`copilot-api egress listening on ${listenHost}:${listenPort}`)
})
