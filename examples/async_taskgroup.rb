# frozen_string_literal: true
require "apple_sdk_mac"

inputs = (ENV["TASKGROUP_INPUTS"] || "10,20,30").split(",").map(&:to_i)
raise "exactly 3 inputs required" unless inputs.size == 3

Apple.discover(framework: :Foundation, klass: :NSOperationQueue,
  swift_initializer: "init()", params: [], return_kind: :opaque_ref)
Apple.discover(framework: :Foundation, klass: :NSBlockOperation,
  class_method: "blockOperationWithBlock:",
  params: [:block_persistent_void], return_kind: :opaque_ref)
Apple.discover(framework: :Foundation, klass: :NSOperationQueue,
  selector: "addOperations:waitUntilFinished:",
  params: [{kind: :array_of_opaque_ref, type: "Operation"}, :bool],
  return_kind: :void)
Apple.discover(framework: :Foundation, klass: :NSThread,
  class_method: "sleepForTimeInterval:", params: [:float], return_kind: :void)

warmup_queue = Apple::Foundation::NSOperationQueue.init
warmup_op = Apple::Foundation::NSBlockOperation.blockOperationWithBlock(lambda { |_| })
Apple::Foundation::NSThread.sleepForTimeInterval(0.001)
warmup_queue.addOperations_waitUntilFinished([warmup_op], false)

queue = Apple::Foundation::NSOperationQueue.init
results = Array.new(inputs.size)
mutex = Mutex.new
done_count = 0

ops = inputs.each_with_index.map do |ms, i|
  Apple::Foundation::NSBlockOperation.blockOperationWithBlock(lambda { |_unused|
    Apple::Foundation::NSThread.sleepForTimeInterval(ms / 1000.0)
    mutex.synchronize do
      results[i] = ms * 2
      done_count += 1
    end
  })
end

t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
queue.addOperations_waitUntilFinished(ops, false)

poll_budget = (inputs.max + 200) / 1000.0
deadline = t0 + poll_budget
while mutex.synchronize { done_count } < inputs.size
  AppleSDKMacRuntime.threading_poll(0.002)
  if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    raise "T52: ThreadingBridge poll timeout (got #{done_count}/#{inputs.size}, " \
          "results=#{results.inspect})"
  end
end
elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round

expected = inputs.map { |x| x * 2 }
raise "expected #{expected.inspect}, got #{results.inspect}" unless results == expected

longest = inputs.max
parallel = elapsed_ms < (longest + 80)
puts "inputs=#{inputs.inspect}"
puts "results=#{results.inspect}"
puts "elapsed_ms=#{elapsed_ms}"
puts "parallel=#{parallel}"
raise "T52: elapsed_ms=#{elapsed_ms} not parallel (expected ≤ #{longest}+80)" unless parallel
puts "OperationQueue OK"
