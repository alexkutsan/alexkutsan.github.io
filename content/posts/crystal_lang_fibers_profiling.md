+++
title = "Crystal Lang Fibers Profiling"
description = "Find what fiber consumes the most CPU time"
date = 2025-06-01
colocated_path = "./"

[extra]
toc = true

[taxonomies]
tags = ["crystal", "concurrency", "profiling"]
categories = ["Technical"] 

+++



Crystal's fiber-based concurrency model enables elegant single-threaded development, but performance bottlenecks can be difficult to debug—especially when a misbehaving fiber monopolizes CPU time and freezes the entire application.

Crystal’s runtime tracing can help identify which fibers consume the most resources. However, the traditional approach requires enabling tracing at startup, which is impractical for long-running services since it generates gigabytes of logs.

Fortunately, Crystal’s monkey-patching capabilities allow us to dynamically enable scheduler tracing using Unix signals, offering a lightweight and practical way to diagnose fiber-related performance issues in production applications.
<!-- more -->

# Liryc intro

Crystal is a relatively young language. It isn’t backed by a tech giant like Go is with Google. It's not a low-level systems language, and developers aren’t typically optimizing for microseconds. Crystal mostly competes in the same space as Go, Node.js, Python, and even Java—for server-side applications.

Of course, you can build desktop apps, CLI tools, and daemons with Crystal. But when you start using it, it’s clear it was built with HTTP services in mind.

## Concurrency in Crystal

Crystal is still under active development and doesn’t yet offer official multithreading support. Instead, it provides Fibers—a concept similar to Go's goroutines.

There’s a preview of multithreading support, but it’s experimental and should be used with caution.

For small HTTP services or apps that do many I/O-bound operations, multithreading is often unnecessary. The lack of it doesn’t significantly impact performance—unless you're building high-load services with strict response time requirements.

Crystal’s concurrency model is straightforward — and that’s something I really like about it. Everything happens in a single thread. When you create a fiber using the spawn keyword, it doesn’t start executing immediately. It waits until the scheduler gives it a turn.

Context switching happens during I/O operations, sleeps, channels interactions, or when Fiber.yield is explicitly called.

Because of this, you can write your code as if it's single-threaded, which greatly reduces cognitive overhead. You can be confident your data won’t be modified mid-instruction by another fiber.

If you do enable multithreading, things get complex fast. That said, recent improvements have introduced the concept of [execution contexts](https://crystal-lang.org/api/1.16.3/Fiber/ExecutionContext.html), allowing you to spawn fibers within a shared thread context. I haven’t explored this deeply yet, but I’m very excited about it.

## The Problem: Identifying Misbehaving Fibers

So, finally to the problem. When you are working in one thread, many fibers are competing for CPU time on it.
Even a single fiber that is doing heavy calculations, or stuck in an infinite or just a very long loop can freeze the whole application, because other fibers will suffer from lack of execution time.

Because Fibers are not OS-level abstractions - there is no easy way to find a fiber to blame.

One more pretty recent feature in Crystal is Runtime tracing. It allows having additional prints for different events related to the garbage collector or scheduler.
That is, analyzing scheduler events can give insight into what fiber takes most of the CPU time.
The "resume" and "reschedule" events fit well for this.

But in the design of how tracing is proposed to be used - there is a significant obstacle.
You can enable tracing by setting env variables. And tracing obviously impacts performance and produces tons of data for analysis.
For long-running applications like microservices, you probably don't want to keep tracing enabled for days and deal with hundreds of gigabytes (or even more) of tracing logs.
You could turn on ENV variables with gdb at runtime, but it doesn't work, because Crystal obviously is not reading them on every tracing event - reading happens once at the beginning of the program.
I would love to enable tracing on a running application at a specific point in time when I observe high CPU consumption, and then disable it. And Crystal allows me to do that.
One of Crystal's other cool features is the ability to monkey-patch stdlib.
You can redefine any function or class from Crystal internals in your application. Crystal source code is available and pretty easy to read and understand.

## Dynamic Tracing Solution

With a short look at the tracing implementation https://github.com/crystal-lang/crystal/blob/master/src/crystal/tracing.cr, tracing is happening for events if Tracing.sections enum contains the proper flag.
And Tracing.sections can be changed at runtime.


```crystal
module Crystal::Tracing
    def self.enable_scheduler_tracing
      @@sections = Section::Sched
      System.print_error "[dynamic_tracing] Scheduler tracing ENABLED\n"
    end

    def self.disable_scheduler_tracing
      @@sections = Section::None
      System.print_error "[dynamic_tracing] Scheduler tracing DISABLED\n"
    end
end
```

So the only thing you need to do is turn on tracing based on some IPC user input, and turn it off with another.
The simplest and most robust way - turn on scheduler tracing with SIGUSR1, and turn it off with SIGUSR2.
And this is a couple of lines of code:

```crystal
Signal::USR1.trap { Crystal::Tracing.enable_scheduler_tracing }
Signal::USR2.trap { Crystal::Tracing.disable_scheduler_tracing }
```

## Using Dynamic Tracing in Practice

Now you can use it.
I'll give an example of an application like:


```crystal
# try_runtime_tracing.cr
require "socket"

module Crystal::Tracing
    def self.enable_scheduler_tracing
      @@sections = Section::Sched
      System.print_error "[dynamic_tracing] Scheduler tracing ENABLED\n"
    end
    def self.disable_scheduler_tracing
      @@sections = Section::None
      System.print_error "[dynamic_tracing] Scheduler tracing DISABLED\n"
    end
end
Signal::USR1.trap { Crystal::Tracing.enable_scheduler_tracing }
Signal::USR2.trap { Crystal::Tracing.disable_scheduler_tracing }

spawn(name: "Fiber_cpu_blocker1") { loop { 100_000.times {  }; Fiber.yield} }
spawn(name: "Fiber_cpu_blocker2") { loop { 200_000.times {  }; Fiber.yield} }
spawn(name: "Fiber_IO") do
  loop do
      socket = TCPSocket.new("example.com", 80)
      socket.puts "GET / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n"
      socket.gets_to_end
    rescue
    ensure
      socket.try &.close
  end
end
spawn(name: "Fiber_sleeper") { loop { sleep 10.milliseconds; } }
sleep # forever
```

First of all, you should compile the application with the -Dtracing flag:

```bash
crystal build try_runtime_tracing.cr -Dtracing
```

For convenience, let's run the application with env `CRYSTAL_TRACE_FILE=trace.log`, so that we don't mix tracing output with what we see in the terminal.

```bash
CRYSTAL_TRACE_FILE=trace.log ./try_runtime_tracing
```
 
For now, the application is running without any tracing, so you will not see any tracing output and performance is not affected significantly.

Now let's try to turn on tracing:

```bash
kill -USR1 `pgrep try_runtime` 
```

And trace.log rapidly grows with tracing output.
After some time, for example 1 minute, you can turn tracing off to keep the application working without additional performance impact:


```bash
kill -USR2 `pgrep try_runtime`
```

## Analyzing Trace Results

And analyze the results of the tracing.
In tracing logs, when a fiber gets CPU time - it is a "resume" event.
When a fiber is switched because of sleep or IO operation - it is a "reschedule" event.
Usually I love to write such scripts in Python. But today is Crystal time, so let's do it:

```crystal
# fiber_cpu_time_distribution.cr
trace_file = ARGV[0]? || abort("Usage: #{PROGRAM_NAME} <logfile>")
abort("File not found: #{trace_file}") unless File.exists?(trace_file)

resume_pattern = /sched\.resume (?<timestamp>\d+) .*fiber=(?<prev_id>0x[\da-f]+):(?<prev_name>\S+) fiber=(?<next_id>0x[\da-f]+):(?<next_name>\S+)/
reschedule_pattern = /sched\.reschedule (?<timestamp>\d+) .*fiber=(?<fiber_id>0x[\da-f]+):(?<fiber_name>\S+)/

# Store fiber data: {resume_time, total_active_time}
fiber_data = Hash(String, Tuple(Int64?, Int64)).new { |hash, key| hash[key] = {nil, 0_i64} }

File.each_line(trace_file) do |line|
  if match = line.match(resume_pattern)
    timestamp = match["timestamp"].to_i64
    next_fiber = match["next_name"] != "?" ? match["next_name"] : match["next_id"]
    fiber_data[next_fiber] = {timestamp, fiber_data[next_fiber][1]}
  elsif match = line.match(reschedule_pattern)
    timestamp = match["timestamp"].to_i64
    fiber_name = match["fiber_name"] != "?" ? match["fiber_name"] : match["fiber_id"]
    if resume_time = fiber_data[fiber_name][0]
      active_time = timestamp - resume_time
      current_active_time = fiber_data[fiber_name][1]
      fiber_data[fiber_name] = {nil, current_active_time + active_time}
    end
  end
end

total_active_time = fiber_data.values.sum { |data| data[1] }

printf "%-25s %15s %10s\n", "Fiber Name", "Active Time (ms)", "Percent"
puts "-" * 52

# Sort fibers by total active time (descending) and print minimal output
fiber_data.to_a.sort_by { |_, data| -data[1] }.each do |fiber_name, data|
  active_time = data[1]
  active_ms = active_time / 1_000_000.0
  active_percentage = total_active_time > 0 ? active_time.to_f / total_active_time * 100 : 0.0
  printf "%-25s %15.2f %9.2f%%\n", fiber_name, active_ms, active_percentage
end
```


As output, we can see the distribution of CPU time between fibers.
For this method to work well, it is good practice to give a name to fibers when you spawn them as in the example above.

```bash
[dynamic_tracing] Scheduler tracing ENABLED
[dynamic_tracing] Scheduler tracing DISABLED
Fiber Name                Active Time (ms)    Percent
----------------------------------------------------
Fiber_cpu_blocker2                 658.32     65.22%
Fiber_cpu_blocker1                 347.27     34.40%
Fiber_IO                             1.91      0.19%
Fiber_sleeper                        1.87      0.19%
signal-loop                          0.06      0.01%
0x714a10450a50                       0.00      0.00%
0x714a104509a0                       0.00      0.00%
```

As expected, `Fiber_cpu_blocker2` takes most of the CPU time, while `Fiber_cpu_blocker1` takes half as much.
The next one - `Fiber_IO` - takes a small amount of CPU time.
Others - `Fiber_sleeper` and system fibers - take even less.

## Conclusion

Of course, this is not a very advanced and comprehensive performance analysis method.
But it can give you a basic understanding of what is going on in your application.
For deeper performance analysis in Crystal - there are traditional ways of performance analysis like `perf` that work perfectly for Crystal as well.
