# Allocation profile with stack attribution for read_request(typical GET).
using HTTP
using HTTP: read_request
using Profile
using Printf

const REQ_TYPICAL = "GET /api/v1/users?page=2&limit=50 HTTP/1.1\r\nHost: api.example.test:8080\r\nUser-Agent: Mozilla/5.0 (X11; Linux x86_64)\r\nAccept: application/json\r\nAccept-Encoding: gzip, deflate, br\r\nAccept-Language: en-US,en;q=0.9\r\nConnection: keep-alive\r\nIf-None-Match: \"a1b2c3d4\"\r\nX-Request-Id: 12345678-1234-1234-1234-123456789abc\r\nX-Forwarded-For: 10.0.0.1\r\n\r\n"

io = IOBuffer(codeunits(REQ_TYPICAL))
for _ in 1:100; seekstart(io); read_request(io); end

Profile.Allocs.clear()
Profile.Allocs.@profile sample_rate=1.0 begin
    for _ in 1:200
        seekstart(io)
        read_request(io)
    end
end
results = Profile.Allocs.fetch()

# Group by the innermost HTTP.jl/Base frame in the stack
attrib = Dict{String,Tuple{Int,Int}}()
for r in results.allocs
    stack = r.stacktrace
    tag = isempty(stack) ? "?" : string(last(stack).func)
    for fr in reverse(stack)  # innermost first
        s = string(fr.func)
        if occursin(r"_readline|_parse_http_version|_parse_request_line|_parse_status_line|_normalize_header|_trim_http_ows|canonical_header|_upcoming|_fold|_request_nocopy|_read_headers|headers|_validate_request", s)
            tag = s
            break
        end
    end
    c, b = get(attrib, tag, (0, 0))
    attrib[tag] = (c + 1, b + Int(r.size))
end
n = 200
println("== per-request allocations by innermost HTTP frame (n=$n) ==")
for (k, (c, b)) in sort(collect(attrib); by=x->-x[2][2])
    @printf "%-55s %5.1f allocs/req %7.1f B/req\n" k c/n b/n
end
tot_c = sum(x[1] for x in values(attrib)); tot_b = sum(x[2] for x in values(attrib))
@printf "%-55s %5.1f allocs/req %7.1f B/req\n" "TOTAL" tot_c/n tot_b/n
