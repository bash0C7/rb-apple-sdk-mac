# frozen_string_literal: true
# T52 — Apple Foundation framework (NSOperationQueue + NSBlockOperation) 経由
# の真の並列実行 example。Ruby Thread fake / runtime fixture (T51) 退路は
# 完全廃止 — README L3 "any public Apple framework API" を直接満たす形。
#
# 並列化 primitive は Apple framework 公開 API のみ:
#   - NSOperationQueue.init() / addOperations:waitUntilFinished:
#   - NSBlockOperation +blockOperationWithBlock:
#   - NSThread +sleepForTimeInterval:
#
# Apple.discover 経由のみで discovery (事前宣言ファイル禁止)。
#
# 実行モデル: addOperations:waitUntilFinished:false で Apple OperationQueue
# 内部の concurrent worker pool が 3 個の BlockOperation を並列実行する。
# 各 block 内で NSThread.sleepForTimeInterval した後 Ruby callback を
# ThreadingBridge 経由で main thread queue に enqueue。Ruby main は
# threading_poll で drain して results を埋める。
#
# 並列性証跡: addOperations の return 後 (= block 投入完了) を t0 とし、
# 全 callback が drain されるまでの elapsed を計測。 longest sleep + buffer
# 以下なら parallel 実行されている。 first-call の Apple.discover 起因の
# swiftc compile cost は warmup phase で先払いし、 timing path に乗らない。
#
# Usage:
#   RUBY_BOX=1 bundle exec ruby examples/async_taskgroup.rb
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

# Warmup — Apple.discover は dispatcher 初回 invoke 時に dlopen + symbol
# resolve を実行する。第一発の overhead を timing path から除外するため
# 全 4 method を no-op で 1 度ずつ呼んでおく (block も 1 個 enqueue して
# OperationQueue の thread pool warmup も兼ねる)。
warmup_queue = Apple::Foundation::NSOperationQueue.init
warmup_op = Apple::Foundation::NSBlockOperation.blockOperationWithBlock(lambda { |_| })
Apple::Foundation::NSThread.sleepForTimeInterval(0.001)
warmup_queue.addOperations_waitUntilFinished([warmup_op], false)
# warmup の callback drain は気にしない (timing path 外)

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
