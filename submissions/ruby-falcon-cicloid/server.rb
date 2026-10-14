# frozen_string_literal: true

require "async"
require "async/http/endpoint"
require "falcon/server"
require_relative "app"

# Last-resort guard for serving keep-alive clients directly: only when open descriptors get close to
# the process limit do responses carry `Connection: close`, so clients reconnect instead of the
# server failing to accept. Forced reconnects are expensive, so the budget sits just under the limit.
class Pressure
  attr_reader :strained

  def initialize(connections)
    soft = Process.getrlimit(:NOFILE).first
    @budget = [soft - 256, soft * 9 / 10].max
    @connections = connections # Falcon's live count of open client connections
    @strained = false
  end

  def sample
    @strained = @connections.value > @budget
  end
end

# Accepts connections like IO::Endpoint's default wrapper, but without keeping each peer's Addrinfo
# alive for the connection's lifetime (Falcon only uses it for debug logging).
class Acceptor < IO::Endpoint::Wrapper
  def accept(server, **)
    loop do
      socket = accept_socket(server)
      Fiber.schedule { yield socket, nil }
    end
  end

  private

  def accept_socket(server)
    server.accept.first
  end
end

# Falcon's server, minus its per-request metrics (two counters and a body wrapper per request).
# Connection metrics stay: the pressure guard reads the open-connection count.
class FeedServer < Falcon::Server
  def call(request)
    @delegate.call(request)
  end
end

host = ENV.fetch("HOST", "127.0.0.1")
port = Integer(ENV.fetch("PORT", "3000"))
store = Store.new(ENV.fetch("SQLITE_PATH"))
utilization = Async::Utilization::Registry.new
pressure = Pressure.new(utilization.metric(:connections_active))
app = App.new(store, ENV.fetch("JWT_SECRET"), pressure)

# No socket timeout: idle keep-alive connections stay open until the client closes them (at least the
# 65 s Nginx needs), and no timer is armed per read on each of tens of thousands of connections.
endpoint = Async::HTTP::Endpoint.parse("http://#{host}:#{port}", reuse_address: true, wrapper: Acceptor.new)

GC.compact
Process.warmup if Process.respond_to?(:warmup)

Async do |task|
  store.start

  task.async do
    loop do
      sleep 1
      store.checkpoint
      pressure.sample
    end
  end

  FeedServer.new(app, endpoint, utilization_registry: utilization).run
  $stderr.puts "listening on #{host}:#{port}"
end
