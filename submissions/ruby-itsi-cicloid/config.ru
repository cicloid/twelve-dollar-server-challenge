# frozen_string_literal: true

# The app from ruby-btreereads-cicloid as a Rack app, served by Itsi (Rust: tokio + hyper). Itsi owns
# the sockets and HTTP; one Ruby thread runs every request, one at a time.
require_relative "app"

store = Store.new(ENV.fetch("SQLITE_PATH"))
app = App.new(store, ENV.fetch("JWT_SECRET"))

# Warm YJIT before listening: reads, a JWT verification and a body parse, 50 times each (the call
# threshold is 5). Nothing is written: the post body fails validation after it is parsed, and the
# like has an invalid id. The token is signed with libsodium, which is loaded anyway.
key = ENV.fetch("JWT_SECRET").b.ljust(32, "\0")
claims = [{ sub: "1", username: "warmup", exp: Time.now.to_i + 3600 }.to_json].pack("m0").tr("+/", "-_").delete("=")
signing_input = "#{App::HS256_HEADER}.#{claims}".b
mac = String.new("\0" * 32, encoding: Encoding::BINARY)
Sodium.hmac_sha256(mac, signing_input, signing_input.bytesize, key)
auth = "Bearer #{signing_input}.#{[mac].pack("m0").tr("+/", "-_").delete("=")}"
50.times do
  app.call("GET", "/feed", nil, nil)
  app.call("GET", "/posts/1", nil, nil)
  app.call("POST", "/posts", auth, +'{"body":""}')
  app.call("POST", "/posts/0/like", auth, nil)
end

GC.compact
Process.warmup if Process.respond_to?(:warmup)
# No automatic full GCs while serving (see ruby-uring-cicloid): a full GC still runs if old objects
# grow past three times what the warm-up left.
GC.config(rgengc_allow_full_mark: false)

# Checkpoints and the full-GC check run between requests on the request thread: a timer thread
# would touch the SQLite connection in the middle of a request.
class Ticks
  def initialize(store)
    @store = store
    @next_checkpoint = now + 1
    @next_gc = now + 10
    @old_objects_cap = GC.stat(:old_objects) * 3
  end

  def call
    at = now
    return if at < @next_checkpoint

    @next_checkpoint = at + 1
    @store.checkpoint
    return if at < @next_gc

    @next_gc = at + 10
    return if GC.stat(:old_objects) < @old_objects_cap

    GC.start
    @old_objects_cap = GC.stat(:old_objects) * 3
  end

  private

  def now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end

ticks = Ticks.new(store)
headers = { "content-type" => "application/json" }.freeze
post = "POST"

run(lambda do |env|
  method = env["REQUEST_METHOD"]
  body = env["rack.input"]&.read if method == post
  status, document = app.call(method, env["PATH_INFO"], env["HTTP_AUTHORIZATION"], body)
  ticks.call
  [status, headers.dup, [document]]
end)
