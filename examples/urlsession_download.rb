# frozen_string_literal: true
require "apple_sdk_mac"
require "digest"
require "fiddle"

url_str = ENV["T53_FIXTURE_URL"] ||
          "https://www.apple.com/library/test/success.html"
unless url_str.start_with?("http://", "https://")
  raise "T53: HTTP/HTTPS スキーム必須 (got: #{url_str})"
end

Apple.discover(framework: :Foundation, klass: :NSURL,
  class_method: "URLWithString:", params: [:string], return_kind: :opaque_ref)
Apple.discover(framework: :Foundation, klass: :NSURLSession,
  swift_property: :shared, return_kind: :opaque_ref)
Apple.discover(framework: :Foundation, klass: :NSURLSession,
  selector: "dataTaskWithURL:completionHandler:",
  params: [{kind: :opaque_ref, type: "URL"},
           {kind: :block_persistent, arity: 3,
            types: ["Data?", "URLResponse?", "Error?"]}],
  return_kind: :opaque_ref, return_klass: :NSURLSessionDataTask)
Apple.discover(framework: :Foundation, klass: :NSURLSessionDataTask,
  selector: "resume", params: [], return_kind: :void)
Apple.discover(framework: :Foundation, klass: :NSData,
  selector: "length", params: [], return_kind: :int)
Apple.discover(framework: :Foundation, klass: :NSData,
  selector: "bytes", params: [], return_kind: :raw_ptr)

mutex = Mutex.new
done = false
result = { bytes: nil, sha: nil, error: nil }

completion = lambda do |data_ref, _response_ref, error_ref|
  if error_ref && error_ref.is_a?(Integer) && error_ref != 0
    mutex.synchronize { result[:error] = "transport error (NSError ptr=#{error_ref})"; done = true }
    next
  end
  if data_ref.nil? || data_ref == 0
    mutex.synchronize { result[:error] = "nil/zero NSData"; done = true }
    next
  end
  data = Apple::Foundation::NSData.from_ref(data_ref)
  n = data.length
  ptr_int = data.bytes
  if n <= 0 || ptr_int.nil? || ptr_int == 0
    mutex.synchronize { result[:error] = "empty data (n=#{n} ptr=#{ptr_int})"; done = true }
    next
  end
  body = Fiddle::Pointer.new(ptr_int, n).to_str(n)
  mutex.synchronize do
    result[:bytes] = n
    result[:sha] = Digest::SHA256.hexdigest(body)
    done = true
  end
end

url = Apple::Foundation::NSURL.URLWithString(url_str)
session = Apple::Foundation::NSURLSession.shared
task = session.dataTaskWithURL_completionHandler(url, completion)
task.resume

deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30.0
until mutex.synchronize { done }
  AppleSDKMacRuntime.threading_poll(0.01)
  if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    raise "T53: completion timeout 30s"
  end
end

raise "T53: #{result[:error]}" if result[:error]

scheme = url_str.start_with?("https") ? "https" : "http"
puts "scheme=#{scheme}"
puts "bytes=#{result[:bytes]}"
puts "sha256=#{result[:sha]}"
puts "urlsession download OK"
