# E2E server: tiny + json endpoints. Prints READY, then stats on shutdown.
# Usage: julia --project=../.. -t 16 e2e_server.jl PORT DURATION_S
using Printf
using HTTP

const JSON_BODY = "{\"id\":1,\"name\":\"alice\",\"email\":\"alice@example.com\",\"tags\":[\"admin\",\"reviewer\"],\"created_at\":\"2024-01-01T12:00:00Z\",\"status\":\"active\",\"login_count\":42}"
const JSON_HEADERS = ["Content-Type" => "application/json", "Content-Length" => string(sizeof(JSON_BODY))]

count = Threads.Atomic{Int}(0)

function handler(req::HTTP.Request)
    Threads.atomic_add!(count, 1)
    t = req.target
    if t == "/json"
        return HTTP.Response(200, JSON_HEADERS; body=JSON_BODY)
    else
        return HTTP.Response(200, ["Content-Length" => "0"])
    end
end

port = parse(Int, ARGS[1])
dur = parse(Float64, ARGS[2])
server = HTTP.serve!(handler, "127.0.0.1", port)
println("READY ", HTTP.port(server)); flush(stdout)
t0 = time_ns()
while (time_ns() - t0) / 1e9 < dur
    sleep(0.5)
end
elapsed = (time_ns() - t0) / 1e9
total = count[]
gc_t = Base.gc_time_ns() / 1e9  # cumulative
# GC fraction of process CPU (approx: gc_time vs wall×threads is rough; report both)
@printf "SERVER_STATS total=%d elapsed=%.2f rps=%.0f gc_time_s=%.2f\n" total elapsed total / elapsed gc_t
flush(stdout)
sleep(0.2)
exit(0)
