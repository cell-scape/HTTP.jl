# HTTP.jl hot-path micro-benchmark: parse + serialize + sub-components.
# Run: julia --project=../.. -t 4 micro_parse_serialize.jl
using HTTP
using HTTP: _ConnReader, _fill_conn_reader!, Headers, read_request, write_response!,
            canonical_header_key, headercontains, hasheader, mkheaders
using Reseau.TCP
using Reseau.HostResolvers
using Printf

# ---------- harness ----------
function best_ns(f; seconds=0.5, reps=5)
    f(); f(); f()  # warmup
    t0 = time_ns(); f(); t1 = time_ns()
    per = max(1.0, (t1 - t0))
    n = clamp(round(Int, seconds * 1e9 / per), 1, 2_000_000)
    best = Inf
    for _ in 1:reps
        t0 = time_ns()
        for _ in 1:n
            f()
        end
        t1 = time_ns()
        best = min(best, (t1 - t0) / n)
    end
    return best
end

function allocs(f)
    f()
    a = typemax(Int)
    for _ in 1:20
        GC.gc()
        b = @allocated f()
        a = min(a, b)
    end
    return a
end

function report(name, ns, b)
    @printf "%-46s %10.2f µs  %10d B  %8.1f MB/s@1k rps equiv\n" name ns / 1000 b b / 1024 / 1024
end

# ---------- payloads ----------
const REQ_SMALL = "GET /json HTTP/1.1\r\nHost: 127.0.0.1:8080\r\nUser-Agent: curl/8.7.1\r\nAccept: */*\r\n\r\n"
const REQ_TYPICAL = "GET /api/v1/users?page=2&limit=50 HTTP/1.1\r\nHost: api.example.test:8080\r\nUser-Agent: Mozilla/5.0 (X11; Linux x86_64)\r\nAccept: application/json\r\nAccept-Encoding: gzip, deflate, br\r\nAccept-Language: en-US,en;q=0.9\r\nConnection: keep-alive\r\nIf-None-Match: \"a1b2c3d4\"\r\nX-Request-Id: 12345678-1234-1234-1234-123456789abc\r\nX-Forwarded-For: 10.0.0.1\r\n\r\n"
const RESP_BODY = repeat("{\"id\":1,\"name\":\"alice\",\"tags\":[\"admin\"]},", 3)[1:end-1]  # ~150 B

println("== payload sizes: REQ_SMALL=$(sizeof(REQ_SMALL))B REQ_TYPICAL=$(sizeof(REQ_TYPICAL))B resp body=$(sizeof(RESP_BODY))B ==")

# ---------- 1. parse: generic IOBuffer path (proxy/tests) ----------
for (label, raw) in (("small GET (3 hdrs)", REQ_SMALL), ("typical GET (9 hdrs)", REQ_TYPICAL))
    io = IOBuffer(codeunits(raw))
    f = () -> (seekstart(io); read_request(io))
    report("read_request IOBuffer: $label", best_ns(f), allocs(f))
end

# ---------- 2. parse: _ConnReader fast path over real loopback TCP ----------
function bench_connreader(raw; n=20_000)
    port = 19_287
    listener = TCP.listen("tcp", "127.0.0.1:$port"; backlog=64, reuseaddr=true)
    try
        resolver = HostResolvers.HostResolver()
        client = TCP.connect(resolver, "tcp", "127.0.0.1:$port")
        server_conn = TCP.accept(listener)
        writer = Threads.@spawn begin
            try
                for _ in 1:n
                    write(client, raw)  # one write per request, like a real client
                end
            catch e
                @warn "writer" e
            end
        end
        err = nothing
        reader = _ConnReader(server_conn)
        t0 = time_ns()
        try
            for _ in 1:n
                read_request(reader)
            end
        catch e
            err = e
        end
        t1 = time_ns()
        wait(writer)
        close(server_conn); close(client)
        return (t1 - t0) / n, err
    finally
        close(listener)
    end
end

for (label, raw) in (("small GET (3 hdrs)", REQ_SMALL), ("typical GET (9 hdrs)", REQ_TYPICAL))
    ns, err = bench_connreader(raw)
    if err !== nothing
        println("connreader $label FAILED: ", err)
        continue
    end
    # allocation per request measured separately (parse path identical)
    io = IOBuffer(codeunits(raw))
    b = allocs(() -> (seekstart(io); read_request(io)))
    @printf "%-46s %10.2f µs  %10d B (incl. socket refill)\n" ("read_request ConnReader: $label") ns / 1000 b
end

# ---------- 3. serialize: write_response! ----------
resp = HTTP.Response(200, ["Content-Type" => "application/json", "Content-Length" => string(sizeof(RESP_BODY))]; body=RESP_BODY)
buf = IOBuffer()
f = () -> (seekstart(buf); write_response!(buf, resp); buf.ptr = 1)
report("write_response! 150B json", best_ns(f), allocs(f))
resp204 = HTTP.Response(204)
f204 = () -> (seekstart(buf); write_response!(buf, resp204); buf.ptr = 1)
report("write_response! 204 no body", best_ns(f204), allocs(f204))

# ---------- 4. sub-components ----------
f = () -> canonical_header_key("Content-Type")
report("canonical_header_key: already-canonical", best_ns(f), allocs(f))
f = () -> canonical_header_key("content-type")
report("canonical_header_key: lowercase input", best_ns(f), allocs(f))
f = () -> canonical_header_key("x-b3-traceid")
report("canonical_header_key: uncommon lower", best_ns(f), allocs(f))

hdrs10 = mkheaders(["Host" => "a", "User-Agent" => "b", "Accept" => "c", "Accept-Encoding" => "d",
    "Accept-Language" => "e", "Connection" => "keep-alive", "If-None-Match" => "f",
    "X-Request-Id" => "g", "X-Forwarded-For" => "h", "Cookie" => "i"])
f = () -> hasheader(hdrs10, "Connection")
report("hasheader 10-entry (present)", best_ns(f), allocs(f))
f = () -> hasheader(hdrs10, "X-Missing")
report("hasheader 10-entry (absent)", best_ns(f), allocs(f))
f = () -> headercontains(hdrs10, "Connection", "close")
report("headercontains 10-entry", best_ns(f), allocs(f))

line = "X-Request-Id: 12345678-1234-1234-1234-123456789abc\r\n"
io = IOBuffer(codeunits(repeat(line, 1)))
# _readline_crlf generic: measure via a type-stable wrapper
f = () -> (seekstart(io); HTTP._readline_crlf(io, 65536))
report("_readline_crlf generic IO (36B line)", best_ns(f), allocs(f))

f = () -> mkheaders(["Content-Type" => "application/json", "Content-Length" => "150"])
report("mkheaders 2-entry Vector{Pair}", best_ns(f), allocs(f))

println("\n== done ==")
