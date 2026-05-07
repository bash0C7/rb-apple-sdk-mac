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
# T52i — addOperations:waitUntilFinished:false + ThreadingBridge.poll
# pattern。NSOperationQueue は別 Apple thread で block を並列実行し、
# block 内の `runtime_threading_enqueue` は Ruby callback を main thread の
# queue に積む。Ruby main thread が threading_poll 経由で drain して
# results を mutate する。waitUntilFinished:true で main thread が wait
# 中は drain できないため false にする。
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
# T52 — addOperations:waitUntilFinished: より単純で安定な addOperation: を 3 回。
# Foundation NSOperationQueue は default で NSOperationQueueDefaultMaxConcurrentOperationCount
# = system 決定 (通常 core 数ベース) で並列実行する。
Apple.discover(framework: :Foundation, klass: :NSOperationQueue,
  selector: "addOperation:",
  params: [{kind: :opaque_ref, type: "Operation"}], return_kind: :void)
Apple.discover(framework: :Foundation, klass: :NSThread,
  class_method: "sleepForTimeInterval:", params: [:float], return_kind: :void)

queue = Apple::Foundation::NSOperationQueue.init
results = Array.new(inputs.size)
mutex = Mutex.new
done_count = 0

ops = inputs.each_with_index.map do |ms, i|
  Apple::Foundation::NSBlockOperation.blockOperationWithBlock(lambda { |_unused|
    # ThreadingBridge dispatcher が Ruby Proc に Int64 (=0) を 1 つ渡す
    # convention のため、 () -> Void ブロックでも引数を受ける形にする。
    Apple::Foundation::NSThread.sleepForTimeInterval(ms / 1000.0)
    mutex.synchronize do
      results[i] = ms * 2
      done_count += 1
    end
  })
end

t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
ops.each { |op| queue.addOperation(op) }

# T52i — Ruby callbacks are enqueued on the main-thread queue from the Apple
# background threads via ThreadingBridge. Tight-polling drain (timeout=0.002s
# per poll, 1ms sleep when empty) until all expected callbacks fire or budget
# expires. parallel=true budget は elapsed_ms < max(inputs)+80 なので余裕は
# 約 80ms。 drain overhead を小さく保つために poll timeout を非常に短く。
poll_budget = (inputs.max + 200) / 1000.0  # 200ms 余裕 (timeout 用)
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
