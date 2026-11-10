# Launcher behind "IESA-Opt UI.cmd". Uses only Base/stdlib until the packages are known to be installed.
using Sockets

const ROOT = normpath(joinpath(@__DIR__, "..", ".."))
const HOST = "127.0.0.1"
const PORTS = 8123:8142

say(msg) = (println(msg); flush(stdout))

# Must match IESAOpt._ui_instance_id in src/ui_server.jl.
function instance_id(root::AbstractString)
    path = try realpath(root) catch; normpath(root) end
    h = 0xcbf29ce484222325
    for byte in codeunits(lowercase(rstrip(path, ['\\', '/'])))
        h = (h ⊻ byte) * 0x00000100000001b3
    end
    return string(h; base = 16, pad = 16)
end

# On Windows a test bind can succeed on a port another process listens on, so ask netstat too.
function listening_ports()
    Sys.iswindows() || return Set{Int}()
    try
        out = read(`netstat -ano -p TCP`, String)
        return Set(parse(Int, m[1]) for m in eachmatch(r"TCP\s+\S+:(\d+)\s+(?:0\.0\.0\.0|\[::\]):0\s", out))
    catch
        return Set{Int}()
    end
end

function port_is_free(port, listening)
    port in listening && return false
    try
        close(listen(IPv4(HOST), port))
        return true
    catch
        return false
    end
end

function status_body(port; timeout = 3.0)
    sock = try connect(IPv4(HOST), port) catch; return "" end
    timer = Timer(_ -> close(sock), timeout)
    try
        write(sock, "GET /api/status HTTP/1.1\r\nHost: $HOST:$port\r\nConnection: close\r\n\r\n")
        return read(sock, String)
    catch
        return ""
    finally
        close(timer)
        close(sock)
    end
end

function open_target(target::AbstractString)
    try
        if Sys.iswindows()
            run(Cmd(Cmd(["cmd", "/d", "/c", "start", "\"\"", "\"$target\""]); windows_verbatim = true))
        elseif Sys.isapple()
            run(`open $target`)
        else
            run(`xdg-open $target`)
        end
        return true
    catch
        return false
    end
end

function file_url(path::AbstractString)
    io = IOBuffer()
    for b in codeunits(replace(abspath(path), '\\' => '/'))
        c = Char(b)
        if isascii(c) && (isletter(c) || isdigit(c) || c in "-._~/:")
            print(io, c)
        else
            print(io, '%', uppercase(string(b; base = 16, pad = 2)))
        end
    end
    url = rstrip(String(take!(io)), '/')
    return startswith(url, "//") ? "file:" * url : "file:///" * url
end

# :ok, :install (packages missing) or :resolve (Manifest made by another Julia version).
function package_state()
    manifest = joinpath(ROOT, "Manifest.toml")
    isfile(manifest) || return :install
    toml = try Base.parsed_toml(manifest) catch; return :install end
    v = tryparse(VersionNumber, string(get(toml, "julia_version", "")))
    v !== nothing && (v.major, v.minor) != (VERSION.major, VERSION.minor) && return :resolve
    for (name, entries) in get(toml, "deps", Dict{String,Any}()), entry in entries
        if haskey(entry, "path")
            isdir(joinpath(ROOT, entry["path"])) || return :install
        elseif haskey(entry, "git-tree-sha1")
            slug = Base.version_slug(Base.UUID(entry["uuid"]), Base.SHA1(entry["git-tree-sha1"]))
            any(d -> isdir(joinpath(d, "packages", name, slug)), DEPOT_PATH) || return :install
        end
    end
    return :ok
end

function install_packages(resolve::Bool)
    say("Installing Julia packages for this computer (one time; can take 10-20 minutes)...")
    @eval Main import Pkg
    Pkg = Main.Pkg
    resolve && Base.invokelatest(Pkg.resolve)
    try
        Base.invokelatest(Pkg.instantiate)
    catch err
        resolve && rethrow()
        say("Retrying after re-resolving packages: $(sprint(showerror, err))")
        Base.invokelatest(Pkg.resolve)
        Base.invokelatest(Pkg.instantiate)
    end
end

function load_iesaopt()
    try
        @eval Main using IESAOpt
    catch err
        say("Loading failed, repairing packages and retrying: $(sprint(showerror, err))")
        install_packages(false)
        @eval Main using IESAOpt
    end
end

function open_loading_page(port::Integer)
    template = joinpath(ROOT, "ui", "loading.html")
    isfile(template) || return false
    html = replace(read(template, String), "127.0.0.1:8123" => "$HOST:$port")
    html = replace(html, "<head>" => "<head>\n  <base href=\"$(file_url(joinpath(ROOT, "ui")))/\">"; count = 1)
    page = joinpath(tempdir(), "iesa-opt-ui-loading-$port.html")
    write(page, html)
    return open_target(page)
end

function main()
    Sys.iswindows() && ccall((:SetConsoleTitleW, "kernel32"), stdcall, Cint, (Cwstring,), "IESA-Opt.jl")
    if VERSION < v"1.10"
        say("IESA-Opt.jl needs Julia 1.10 or newer (found $VERSION).")
        return 1
    end
    say("IESA-Opt.jl UI | folder: $ROOT | Julia $VERSION")
    instance = instance_id(ROOT)
    free = Int[]
    listening = listening_ports()
    for port in PORTS
        if port_is_free(port, listening)
            push!(free, port)
        elseif occursin("\"instance\":\"$instance\"", status_body(port))
            url = "http://$HOST:$port/"
            say("The UI for this folder is already running at $url - opening it.")
            open_target(url)
            sleep(3)
            return 0
        end
    end
    isempty(free) && error("No free port in $(first(PORTS))-$(last(PORTS)). Close other IESA-Opt windows and try again.")
    port = first(free)
    port == first(PORTS) || say("Port $(first(PORTS)) is used by another program or IESA-Opt window; using port $port.")

    state = package_state()
    state === :ok || install_packages(state === :resolve)
    opened = open_loading_page(port)
    say("Loading the model code (usually 30 s - 3 min; longer after moving the folder or updating). Keep this window open.")
    t = @elapsed load_iesaopt()
    say("Loaded in $(round(Int, t)) s. UI: http://$HOST:$port/ (close this window to stop it).")
    Base.invokelatest(() -> Main.IESAOpt.serve_ui!(port = port, open_browser = !opened))
    return 0
end

if abspath(PROGRAM_FILE) == @__FILE__
    code = try
        main()
    catch err
        say("\nERROR: " * sprint(showerror, err))
        1
    end
    exit(code)
end
