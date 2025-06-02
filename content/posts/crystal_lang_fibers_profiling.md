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


Crystal's fiber-based concurrency model offers elegant single-threaded development, but debugging performance bottlenecks becomes challenging when a misbehaving fiber monopolizes CPU time and freezes the entire application.
Crystal's runtime tracing can identify which fibers consume the most resources, the traditional approach requires enabling tracing at startup—impractical for long-running services that would generate gigabytes of logs.
However, Crystal's monkey-patching capabilities allow us to dynamically enable scheduler tracing on demand using Unix signals, providing a lightweight solution for diagnosing fiber performance issues in production applications.

<!-- more -->

# Liryc intro

Crystal is a pretty yong language, it is not boosted but a huge corporation like Google for Go.
It is not a very low level one, and we are note beating for every microseconds in Crystal lang applications ususally. 
Mostely for sure it shares the same field as Go, NodeJS, Python end even Java - server side applications. 
As any other modern language for sure it allows developing desktop, cli, deamons applicaitons as well. 
But when you use it - you always feel that it was developed for HTTP applications. 

## Concurrency in Crystal

As soon as it is young language powered by comunity and still in active development thee are still no oficial multithreading support. 
It provides an Fiber abstractions - that is some kind like a gorutine in Go. 
There is a preview multithreading support, but you can use it for your own risk.

For small HTTP services, or apps that are actively doing many HTTP requests - multithreaing is redundant in most cases. So it does not affect performance a lot. 
Sure we are not talking about really hight load services with a response time requirenmetns etc. 

Concurency model in Crystal is pretty straitforward and I like it. 
All is happening in the thread. 
When you create a Fiber with `spawn` keyword - you create a fiber, but it is not starting to execute immediately - it is waiting for scheduler to switch context to it.
Context switching is happening when you do a IO operaiton of explicitely call `Fiber.yield`.

Because of it you can write most of the code as a one threaded code, that reduce a mental pressure a lot. 
You know that you code can't be interupted in the missle of instruction and data can be modified. 

Of course if you turn on multityhreadin it becomes a hell :-) before pretty latest significant changes - Adding an execution context, so that you can spawn Fiber in scope of execution context and it will share a thread with fibers in similar execution context.  Unfortunately I did no had a chance to try this functionality widely, but verry exited about it. 

## The Problem: Identifying Misbehaving Fibers

So, finaly to the problem. when you are working in one thread, many fibers are berating for a CPU time on it. 
And eve single fiber that is doing a heavy calculation, or stucked in infinite or just a verry long loop can freeze whole application, because other fibers will struggle from lack of execution time. 

Because Fibers are not OS level abstractions - there are no an easy way to find a fiber to blame. 
One more pretty latest feature in Crystal -  Runtime tracing. It allows to have additional prints for different events related to garbage collector or scheduler.
That is, analysing scheduler events can give an insignt what fiber takes most of the CPU time. 
"resume" event fits good for it. 
But in a design hiw tracing is proposed to use - thre is a significant obstable. 
You can enable tracing by setting env variables. And tracing obviously impact performance and produces tones of data for analisys. 
For a long running applicaitons like a microserivces you probalby don;t want to ekpp tracing enables for days and the dialing with hundreds of gigabytes (or even more) of tracing logs. 

You could turn on ENV variables with gdb in a runtime, but it does not work, because crystal obviously is not reading them on every tracing events - reading happening once at the begining of the program.

I would love to enable tracing on a running application at specific point of time when I observe a hight CPU consumption, and then disable it. And Crystals allows me to do that. 
One of another cool crystal feature is a ability to monkeypatch stdlib. 
You can derefine any function or class from crystal inturnals in your applicaiton. Crystal source code is available and pretty easy to read and understand. 

## Dynamic Tracing Solution

Withn a short look at the tracing implementaiton  https://github.com/crystal-lang/crystal/blob/master/src/crystal/tracing.cr tracing is happening for event if `Tracing.sections` enum contains proper flag. 
And `Tracing.sections` can be changed in runtime. 

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

So the only thing I need to do is to turn on tracing based on some IPC user input, and turn it off with another. 

Simplest and most robust way - turn on sheduler tracing by SIGUSR1, and turn it off by SIGUSR2.

And this is couple of lines of code:

```crystal
Signal::USR1.trap { Crystal::Tracing.enable_scheduler_tracing }
Signal::USR2.trap { Crystal::Tracing.disable_scheduler_tracing }
```

## Using Dynamic Tracing in Practice

Now you can use it.
I'll give an example on application like: 

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

First of all you should compilie application with -Dtracing flag:

```bash
crystal build try_runtime_tracing.cr -Dtracing
```

For convinient lets run applicaiton with env  `CRYSTAL_TRACE_FILE=trace.log`, so that we would not mix tracing output and what we see in a terminal/ 

```bash
CRYSTAL_TRACE_FILE=trace.log ./try_runtime_tracing
```
 
For now applicatin is running without any tracing, so you will not see any tracing output and performance is not affected significantely. 

Now lets try to turn on tracing:

```bash
kill -USR1 `pgrep try_runtime` 
```

And trace.log rapidly growing with tracing output.
After some time, for example 1 min you can tun tracing off to keep applicaiton work without additional performance impact:

```bash
kill -USR2 `pgrep try_runtime`
```

## Analyzing Trace Results

And analyze results of the tracing. 
In tracing logs when fiber  gets a CPU time - it is a "resume" event. 
When fiber is switched because of sleep of IO operation - it is a "reschedule" event. 
Usually I love to write such scripts in python. But today is a crystal time so lets do it:

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


As an output we can see the distribution of CPU time between fibers.
For this method to work well is is a good practice to give a name to fibers when you spawn them as in example above. 

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

As expected `Fiber_cpu_blocker2` takes most of the CPU time, while `Fiber_cpu_blocker1` takes twice less.
Next one - `Fiber_IO` - takes small amount of CPU time. 
Others - `Fiber_sleeper` and system fibers - take even less.

## Conclusion

For sure this is not verry verry advanced and comprehensive performance analisys method. 
But it can give you a basic undestanding what is going on in your application. 

For deeper performance analisys in crystal - there are traditional ways of performance analisys like `perf` that works perfectly for crytal as well. 