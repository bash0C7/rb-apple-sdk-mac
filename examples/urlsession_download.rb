# frozen_string_literal: true
# T53 — URLSession real HTTP download。release 水準 README L3
# "Call any public Apple framework API from Ruby with no pre-declarations" を
# 直接満たす example の 1 つ。 file:// 退路 / DEFERRED 退路完全廃止、 実 HTTP
# (T53_FIXTURE_URL もしくは public Apple endpoint) に対して NSURLSession で
# data task を発行、 completionHandler 経由で受信 NSData の length と
# sha256 を Ruby 側で計算して出力する。
#
# 並列性 + Apple→Ruby callback bridge:
# - dataTask.resume() で URLSession のバックグラウンド thread が HTTP リクエストを実行
# - 完了時 completionHandler block (T53a の :block_persistent Hash 形 arity 3
#   typed dispatch) が Apple thread で fire、 Ruby callback を main thread queue に enqueue
# - Ruby main は threading_poll で drain、 lambda を実行して NSData を Ruby Integer (raw pointer) で受け取る
# - Apple::Foundation::NSData.from_ref(raw) で proxy 化、 .length / .bytes 経由でバイト読み取り
# - sha256 を Digest::SHA256 で計算して fixture と完全一致を確認
#
# Usage:
#   T53_FIXTURE_URL=http://127.0.0.1:8080/blob bundle exec ruby examples/urlsession_download.rb
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
