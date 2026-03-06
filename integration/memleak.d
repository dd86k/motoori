module integration.memleak;

import std.stdio;
import std.process;
import std.conv : to, text;
import std.net.curl;
import std.string : strip;
import core.thread : Thread;
import core.time : Duration, dur;

/// Read RSS (resident set size) in KiB from /proc for a given pid
private long readRSSKiB(int pid)
{
    try
    {
        // /proc/[pid]/statm fields: size resident shared text lib data dt (all in pages)
        auto f = File(text("/proc/", pid, "/statm"), "r");
        auto line = f.readln().strip();
        f.close();
        // Second field is resident pages
        import std.algorithm.iteration : splitter;
        import std.range : dropOne;
        auto resident = line.splitter(' ').dropOne.front;
        // Page size is typically 4 KiB
        return resident.to!long * 4;
    }
    catch (Exception)
    {
        return -1;
    }
}

/// Perform a single HTTP GET and return the status code
private int httpGet(string url)
{
    try
    {
        auto http = HTTP(url);
        http.operationTimeout = dur!"seconds"(10);
        http.onReceive = (ubyte[] data) { return data.length; };
        http.perform();
        return http.statusLine.code;
    }
    catch (Exception e)
    {
        stderr.writeln("  request failed: ", e.msg);
        return -1;
    }
}

/// Per-route test result
struct RouteResult
{
    string route;
    long rssGrowth;
    int failures;
}

int main()
{
    enum ushort PORT = 8999 + 10; // Use offset port to avoid clashing with a running instance
    enum string BASE = "http://127.0.0.1:" ~ PORT.text;
    enum int WARMUP_REQUESTS = 50;
    enum int REQUESTS_PER_ROUTE = 2000;
    enum long MAX_RSS_GROWTH_KIB = 512;

    // Routes to exercise — each tested individually
    static immutable string[] routes = [
        "/",
        "/about",
        "/crt/",
        "/windows/",
        "/windows/modules",
        "/windows/headers",
        "/windows/error-types",
        "/windows/code/0xc0000005",
        "/windows/error/event_sssearch_started",
        "/search?q=access",
        "/search?q=0x5",
        "/search?q=not+found",
    ];

    writeln("=== Memory Leak Integration Test ===");
    writeln("Starting server on port ", PORT, "...");

    // Start the server as a child process, suppress its output
    auto devnull = File("/dev/null", "w");
    auto server = spawnProcess(
        ["./motoori", "--port", PORT.text],
        std.stdio.stdin,
        devnull,
        devnull,
    );
    scope(exit)
    {
        writeln("Stopping server...");
        kill(server, 9);
        wait(server);
    }

    int pid = server.osHandle;
    writeln("Server PID: ", pid);

    Thread.sleep(dur!"msecs"(2500));

    // Wait for server to be ready
    bool ready = false;
    foreach (_; 0 .. 30)
    {
        Thread.sleep(dur!"msecs"(500));
        if (httpGet(BASE ~ "/") == 200)
        {
            ready = true;
            break;
        }
    }
    if (!ready)
    {
        stderr.writeln("FAIL: Server did not become ready in time");
        return 1;
    }
    writeln("Server is ready.");

    // Global warm-up: hit every route to settle the GC
    writeln("Warming up (", WARMUP_REQUESTS, " requests across all routes)...");
    foreach (i; 0 .. WARMUP_REQUESTS)
        httpGet(BASE ~ routes[i % routes.length]);
    Thread.sleep(dur!"seconds"(2));

    // Test each route individually
    RouteResult[] results;
    bool anyFail = false;
    writeln("Testing all routes ", REQUESTS_PER_ROUTE, " times...");
    foreach (route; routes)
    {
        string url = BASE ~ route;

        // Per-route warm-up
        foreach (_; 0 .. 10)
            httpGet(url);
        Thread.sleep(dur!"seconds"(1));

        long rssBefore = readRSSKiB(pid);

        int failures = 0;
        foreach (_; 0 .. REQUESTS_PER_ROUTE)
        {
            if (httpGet(url) != 200)
                failures++;
        }

        Thread.sleep(dur!"seconds"(2));
        long rssAfter = readRSSKiB(pid);
        long growth = rssAfter - rssBefore;

        results ~= RouteResult(route, growth, failures);

        if (growth > MAX_RSS_GROWTH_KIB || failures > 0)
            anyFail = true;
    }

    // Report
    writeln();
    writeln("=== Results (", REQUESTS_PER_ROUTE, " requests per route) ===");
    writefln("%-45s %10s %10s  %s", "Route", "RSS +KiB", "Failures", "Status");
    foreach (ref r; results)
    {
        bool fail = r.rssGrowth > MAX_RSS_GROWTH_KIB || r.failures > 0;
        writefln("%-45s %+10d %10d  %s",
            r.route, r.rssGrowth, r.failures,
            fail ? "FAIL" : "ok");
    }
    writeln("Threshold: ", MAX_RSS_GROWTH_KIB, " KiB per route");

    if (anyFail)
    {
        stderr.writeln("\nFAIL: One or more routes exceeded limits.");
        return 1;
    }

    writeln("\nPASS: No significant memory growth detected on any route.");
    return 0;
}
