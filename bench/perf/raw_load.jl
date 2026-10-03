# Raw TCP load generator: minimal allocs per request (prebuilt bytes, fixed buffers).
# Usage: julia --project=../.. -t 16 raw_load.jl PORT NTASK NREQ ENDPOINT
using Reseau.TCP
using Reseau.HostResolvers
using Printf

port = parse(Int, ARGS[1])
ntask = parse(Int, ARGS[2])
nreq = parse(Int, ARGS[3])
endpoint = length(ARGS) >= 4 ? ARGS[4] : "/json"
addr = "127.0.0.1:$port"

const REQ_BYTES = Vector{UInt8}("GET $endpoint HTTP/1.1\r\nHost: benchmark\r\nUser-Agent: rawload\r\nAccept: */*\r\n\r\n")
# expected response: 200, with Content-Length header; we parse just enough to know when to stop reading
const RECV_BUF_BYTES = 64 * 1024

function request_once!(conn, buf)
    n = write(conn, REQ_BYTES)
    n == sizeof(REQ_BYTES) || error("short write")
    # read response head byte-by-byte until \r\n\r\n would be too slow; read in chunks
    total = 0
    head_end = 0
    cl = -1
    scanned = 5  # next index to check for CRLFCRLF (needs 4-byte lookback)
    while head_end == 0
        got = readbytes!(conn, view(buf, total+1:length(buf)), length(buf) - total; all=false)
        got == 0 && error("eof")
        total += got
        total >= length(buf) - 1 && error("head too big")
        for j in scanned:total
            if buf[j-3] == 0x0d && buf[j-2] == 0x0a && buf[j-1] == 0x0d && buf[j] == 0x0a
                head_end = j
                break
            end
        end
        scanned = total + 1
        if head_end != 0
            hdr = String(view(buf, 1:head_end))
            for line in split(hdr, "\r\n")
                if startswith(line, "content-length") || startswith(line, "Content-Length")
                    cl = parse(Int, strip(last(split(line, ':'))))
                end
            end
        end
    end
    cl < 0 && error("no content-length")
    body_have = total - head_end
    while body_have < cl
        got = readbytes!(conn, view(buf, body_have + head_end + 1:length(buf)), cl - body_have; all=false)
        got == 0 && error("eof in body")
        body_have += got
    end
    return head_end + cl
end

resolver = HostResolvers.HostResolver()

# warmup one connection
let conn = TCP.connect(resolver, "tcp", addr)
    buf = Vector{UInt8}(undef, RECV_BUF_BYTES)
    for _ in 1:20
        request_once!(conn, buf)
    end
    close(conn)
end
GC.gc()

lats = [Vector{Float64}(undef, nreq) for _ in 1:ntask]
errors = Threads.Atomic{Int}(0)
t0 = time_ns()
tasks = map(enumerate(lats)) do (ti, buf)
    Threads.@spawn begin
        conn = TCP.connect(resolver, "tcp", addr)
        rbuf = Vector{UInt8}(undef, RECV_BUF_BYTES)
        try
            for i in 1:nreq
                s = time_ns()
                request_once!(conn, rbuf)
                e = time_ns()
                buf[i] = (e - s) / 1000
            end
        catch err
            Threads.atomic_add!(errors, 1)
            @warn "task failed" err
        finally
            close(conn)
        end
    end
end
foreach(wait, tasks)
t1 = time_ns()
elapsed = (t1 - t0) / 1e9
total = ntask * nreq - errors[]
all_lat = sort(reduce(vcat, lats))
p(q) = all_lat[min(end, max(1, round(Int, q * length(all_lat))))]
@printf("RAW_STATS total=%d elapsed=%.2f rps=%.0f p50=%.1fµs p99=%.1fµs errors=%d client_gc_s=%.2f\n",
    total, elapsed, total / elapsed, p(0.5), p(0.99), errors[], Base.gc_time_ns() / 1e9)
flush(stdout)
exit(0)
